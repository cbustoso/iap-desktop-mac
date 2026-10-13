import AppKit
import ExplorerUI
import SFTPKit
import SSHKit

// GH-60: pestaña "Files" (SFTP) por instancia Linux. Solo cableado: la lógica
// vive en SFTPKit.FileBrowserViewModel y la vista en ExplorerUI.SftpBrowserView.

/// Adapta `FileBrowserViewModel` (SFTPKit) a `SftpBrowserModel` (ExplorerUI).
@MainActor
final class SftpBrowserController: SftpBrowserModel {
    let viewModel: FileBrowserViewModel
    var onChange: (@MainActor () -> Void)?
    private let onClose: @MainActor () -> Void

    init(viewModel: FileBrowserViewModel, onClose: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        self.onClose = onClose
        viewModel.onChange = { [weak self] in self?.onChange?() }
    }

    var rows: [SftpBrowserRow] {
        viewModel.entries.map { entry in
            SftpBrowserRow(
                name: entry.name,
                size: FileBrowserViewModel.sizeText(entry),
                modified: viewModel.modifiedText(entry),
                permissions: FileBrowserViewModel.permissionsText(entry),
                isDirectory: entry.isDirectory,
                isDownloadable: entry.isDownloadable)
        }
    }

    var crumbs: [SftpBrowserCrumb] {
        viewModel.breadcrumb.map { SftpBrowserCrumb(title: $0.title, path: $0.path) }
    }

    var transfers: [SftpBrowserTransferRow] {
        viewModel.transfers.suffix(5).map(Self.row)
    }

    static func row(_ transfer: FileBrowserViewModel.Transfer) -> SftpBrowserTransferRow {
        let arrow = transfer.direction == .upload ? "↑" : "↓"
        let status: String
        switch transfer.state {
        case .transferring:
            status = transfer.fraction.map { "\(Int(($0 * 100).rounded(.down))) %" } ?? SftpBrowserView.inProgress
        case .completed:
            status = "completado (\(FileBrowserViewModel.byteCount(transfer.bytesDone)))"
        case .failed(let message):
            status = message
        case .cancelled:
            status = "cancelado"
        }
        return SftpBrowserTransferRow(name: "\(arrow) \(transfer.name)", fraction: transfer.fraction, status: status)
    }

    var isLoading: Bool { viewModel.isLoading }
    var errorText: String? { viewModel.lastError }

    func openRow(_ index: Int) {
        guard viewModel.entries.indices.contains(index) else { return }
        let entry = viewModel.entries[index]
        Task { await viewModel.open(entry) }
    }

    func navigate(to path: String) { Task { await viewModel.navigate(to: path) } }
    func goUp() { Task { await viewModel.goUp() } }
    func refresh() { Task { await viewModel.refresh() } }

    func conflictingNames(for localURLs: [URL]) -> [String] {
        viewModel.conflictingNames(for: localURLs)
    }

    func upload(_ localURLs: [URL]) {
        Task {
            for url in localURLs { await viewModel.upload(url) }
        }
    }

    func download(row: Int, to fileURL: URL, completion: @escaping @MainActor ((any Error)?) -> Void) {
        guard viewModel.entries.indices.contains(row) else {
            completion(SftpError.fileNotFound)
            return
        }
        let entry = viewModel.entries[row]
        Task {
            let transfer = await viewModel.download(entry, to: fileURL)
            completion(transfer.state == .completed ? nil : SftpError.transferCancelled)
        }
    }

    func close() { onClose() }
}

/// Pestañas "Files" abiertas. Reutiliza la `SshSession` del terminal de la
/// instancia si existe (REQ-SFTP-1: sin conexión SSH duplicada); si no, abre
/// una propia. Cada lado cierra la sesión solo cuando el otro ya no la usa.
@MainActor
final class SftpBrowsers {
    private struct Open {
        let controller: SftpBrowserController
        let channel: SftpChannel
        let session: SshSession
    }

    private let host: any SessionTabHosting
    /// Sesión del terminal de la instancia, si hay una viva.
    private let terminalSession: @MainActor (InstanceInfo) -> SshSession?
    /// Abre una sesión nueva (login + túnel IAP + SSH).
    private let connect: @MainActor (InstanceInfo) async throws -> SshSession
    private let onFailure: @MainActor (any Error, InstanceInfo) -> Void
    private var open: [String: Open] = [:]
    private var opening: Set<String> = []

    init(
        host: any SessionTabHosting,
        terminalSession: @escaping @MainActor (InstanceInfo) -> SshSession?,
        connect: @escaping @MainActor (InstanceInfo) async throws -> SshSession,
        onFailure: @escaping @MainActor (any Error, InstanceInfo) -> Void
    ) {
        self.host = host
        self.terminalSession = terminalSession
        self.connect = connect
        self.onFailure = onFailure
    }

    static func tabIdentifier(_ instance: InstanceInfo) -> String { "\(instance.id)#files" }

    /// ¿Alguna pestaña Files usa esta sesión? (el terminal no debe cerrarla).
    func isUsing(_ session: SshSession) -> Bool {
        open.values.contains { $0.session === session }
    }

    func browse(_ instance: InstanceInfo) {
        let tab = Self.tabIdentifier(instance)
        if open[tab] != nil {
            // Ya abierta: con un identificador existente solo se activa (el contenido se ignora).
            host.openSession(identifier: tab, title: "\(instance.name) — Files", content: NSView())
            return
        }
        guard !opening.contains(tab) else { return }
        opening.insert(tab)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.opening.remove(tab) }
            var session: SshSession?
            do {
                let resolved: SshSession
                if let shared = terminalSession(instance), await shared.isConnected {
                    resolved = shared
                } else {
                    resolved = try await connect(instance)
                }
                session = resolved
                let channel = try await SftpChannel.open(over: resolved)
                let viewModel = FileBrowserViewModel(channel: channel)
                let controller = SftpBrowserController(viewModel: viewModel) { [weak self] in
                    self?.close(tab)
                }
                open[tab] = Open(controller: controller, channel: channel, session: resolved)
                host.openSession(identifier: tab, title: "\(instance.name) — Files", content: SftpBrowserView(model: controller))
                await viewModel.start()
            } catch {
                if let session, terminalSession(instance) !== session { await session.close() }
                onFailure(error, instance)
            }
        }
    }

    /// Lo fija la App: ¿es `session` la de una pestaña de terminal viva?
    var isTerminalSession: (@MainActor (SshSession) -> Bool)?

    func close(_ tab: String) {
        guard let entry = open.removeValue(forKey: tab) else { return }
        host.closeSession(identifier: tab)
        // La SSH se cierra solo si nadie más (otra pestaña Files o el terminal) la usa.
        let usedElsewhere = isUsing(entry.session) || (isTerminalSession?(entry.session) ?? false)
        Task {
            await entry.channel.close()
            if !usedElsewhere { await entry.session.close() }
        }
    }

    func closeAll() {
        for tab in Array(open.keys) { close(tab) }
    }
}
