import AppKit
import ExplorerUI
import GCPClient
import OSLog
import RDPBridge
import TunnelKit

// CBU-52: RDP de extremo a extremo por la vía fallback (ADR-0003 §2):
// túnel IAP → .rdp → "Windows App". Solo cableado; la lógica vive en
// RDPBridge (conector) y GCPClient (reset de credenciales).

/// Túnel `IapListener` hacia `remotePort` de la VM.
final class IapRdpTunnel: RdpTunnel {
    private let listener: IapListener
    init(listener: IapListener) { self.listener = listener }
    var localPort: UInt16 { listener.port }
    func close() async { await listener.stop() }
}

struct IapRdpTunnels: RdpTunnelOpening {
    let accessToken: @Sendable () async throws -> String
    var opener: any RelayChannelOpening = NIOWebSocketTransport()

    func openTunnel(to target: RdpTarget, remotePort: UInt16) async throws -> any RdpTunnel {
        let endpoint = RelayEndpoint(IapEndpoint(
            project: target.project, zone: target.zone, instance: target.instance, port: remotePort))
        let opener = self.opener
        let accessToken = self.accessToken
        // Falla pronto (IAP/firewall) antes de lanzar "Windows App" (paridad probe).
        try await RelayStream.probe(endpoint: endpoint, opener: opener, accessToken: accessToken)
        let listener = try await IapListener.start {
            try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: accessToken)
        }
        return IapRdpTunnel(listener: listener)
    }
}

/// Flujo de conexión RDP: credenciales (opcional) + túnel + "Windows App".
@MainActor
final class RdpConnectFlow {
    nonisolated static let log = Logger(subsystem: "com.iapdesktop.mac", category: "rdp")

    private let client: GCPClient
    private let connector: RdpFallbackConnector
    private let email: () async -> String?
    private let window: () -> NSWindow?
    private let note: (String) -> Void
    /// Credenciales generadas en esta ejecución (solo memoria; nunca disco).
    private var credentials: [RdpTarget: WindowsCredential] = [:]
    private var busy: Set<RdpTarget> = []

    init(
        client: GCPClient, tunnels: any RdpTunnelOpening,
        email: @escaping () async -> String?, window: @escaping () -> NSWindow?, note: @escaping (String) -> Void
    ) {
        self.client = client
        self.connector = RdpFallbackConnector(tunnels: tunnels)
        self.email = email
        self.window = window
        self.note = note
        RdpFallbackConnector.removeGeneratedFiles()
    }

    func shutdown() async {
        credentials.removeAll()
        await connector.shutdown()
    }

    func connect(_ instance: InstanceInfo) {
        let target = RdpTarget(project: instance.project, zone: instance.zone, instance: instance.name)
        guard !busy.contains(target) else { return }
        guard WindowsAppLauncher().applicationURL != nil else {
            present(RdpError.windowsAppNotInstalled(help: RdpError.windowsAppHelp), instance: instance)
            return
        }
        busy.insert(target)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy.remove(target) }
            do {
                guard let username = try await self.resolveCredential(for: target, instance: instance) else { return }
                self.note("RDP: abriendo túnel IAP a \(instance.name):3389…")
                let launch = try await self.connector.connect(
                    to: target, parameters: RdpParameters(),
                    credential: username.map { RdpCredentialReference(username: $0) })
                Self.log.notice("""
                    rdp launched target=\(target.description, privacy: .public) \
                    localPort=\(launch.localPort, privacy: .public) reused=\(launch.reusedTunnel, privacy: .public)
                    """)
                self.note("RDP: Windows App → 127.0.0.1:\(launch.localPort) (túnel IAP a \(instance.name))")
            } catch {
                Self.log.error("rdp failed target=\(target.description, privacy: .public) \(Self.cause(error), privacy: .public)")
                self.note("")
                self.present(error, instance: instance)
            }
        }
    }

    /// `nil` = cancelado; `.some(nil)` = sin usuario (Windows App lo pedirá).
    private func resolveCredential(for target: RdpTarget, instance: InstanceInfo) async throws -> String?? {
        if let cached = credentials[target] {
            copyToPasteboard(cached.password)
            return .some(cached.username)
        }
        let suggested = WindowsUsername.suggest(email: await email())
        switch askForCredentials(instance: instance, suggested: suggested) {
        case .cancel:
            return nil
        case .skip:
            return .some(nil)
        case .generate(let username):
            note("RDP: generando credenciales Windows para \(username) en \(instance.name)…")
            let credential = try await client.resetWindowsCredentials(
                project: target.project, zone: target.zone, instance: target.instance, username: username)
            Self.log.notice("rdp credentials generated target=\(target.description, privacy: .public)")
            credentials[target] = credential
            copyToPasteboard(credential.password)
            showGenerated(credential, instance: instance)
            return .some(credential.username)
        }
    }

    private enum CredentialChoice { case generate(String), skip, cancel }

    private func askForCredentials(instance: InstanceInfo, suggested: String) -> CredentialChoice {
        let alert = NSAlert()
        alert.messageText = "Conectar a \(instance.name) por RDP"
        alert.informativeText = "¿Generar (o resetear) un usuario Windows local? La contraseña nueva "
            + "se copiará al portapapeles para pegarla en Windows App; no se guarda en disco."
        let field = NSTextField(string: suggested)
        field.placeholderString = "Usuario Windows"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Generar y conectar")
        alert.addButton(withTitle: "Conectar sin credenciales")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let username = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard WindowsUsername.isValidLocal(username) else {
                    alert.informativeText = "Usuario no válido: 1–20 caracteres, sin espacios ni \" / \\ [ ] : ; | = , + * ? < >."
                    continue
                }
                return .generate(username)
            case .alertSecondButtonReturn:
                return .skip
            default:
                return .cancel
            }
        }
    }

    private func showGenerated(_ credential: WindowsCredential, instance: InstanceInfo) {
        let alert = NSAlert()
        alert.messageText = "Credenciales Windows listas"
        alert.informativeText = "Usuario: \(credential.username)\nLa contraseña está en el portapapeles "
            + "(se borra en 90 s). Pégala cuando Windows App la pida para \(instance.name)."
        alert.addButton(withTitle: "Abrir Windows App")
        alert.runModal()
    }

    /// Portapapeles marcado como oculto/transitorio (los gestores de
    /// portapapeles no lo guardan) y vaciado a los 90 s si nadie lo cambió.
    private func copyToPasteboard(_ secret: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
    }

    /// Causa para el log: tipo y caso, sin mensajes con datos de la sesión.
    nonisolated static func cause(_ error: any Error) -> String {
        switch error {
        case let error as WindowsCredentialError: return "cause=credentials \(error)"
        case let error as RdpError: return "cause=launch \(error)"
        case let error as TunnelError: return "cause=tunnel \(error)"
        default: return "cause=other type=\(type(of: error))"
        }
    }

    private func present(_ error: any Error, instance: InstanceInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo conectar a \(instance.name) por RDP"
        var help: URL?
        switch error {
        case RdpError.windowsAppNotInstalled(let url):
            alert.informativeText = "Para RDP hace falta \"Windows App\" de Microsoft (gratis en la App Store)."
            help = url
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Abrir App Store")
        case let error as WindowsCredentialError:
            alert.informativeText = error.message
            alert.addButton(withTitle: "OK")
        case let error as TunnelError:
            alert.informativeText = error.userMessage
            help = error.helpTopic?.url
            alert.addButton(withTitle: "OK")
            if let title = error.helpTopic?.title { alert.addButton(withTitle: title) }
        default:
            alert.informativeText = "No se pudo abrir la sesión RDP."
            alert.addButton(withTitle: "OK")
        }
        let open: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn, let help { NSWorkspace.shared.open(help) }
        }
        if let window = window(), window.isVisible {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { open(response) } }
        } else {
            open(alert.runModal())
        }
    }
}

/// Encamina doble clic y menú contextual de VMs Windows a RDP sin tocar
/// ExplorerUI (que hoy solo cablea Linux): envuelve la acción de doble clic
/// del outline y su delegado de menú, y delega el resto al original.
@MainActor
final class WindowsConnectInterposer: NSObject, NSMenuDelegate {
    private weak var outline: NSOutlineView?
    private weak var originalTarget: AnyObject?
    private let originalAction: Selector?
    private weak var originalMenuDelegate: (any NSMenuDelegate)?
    private let onWindowsConnect: (InstanceInfo) -> Void

    init?(window: NSWindow?, onWindowsConnect: @escaping (InstanceInfo) -> Void) {
        guard let outline = Self.findOutline(in: window?.contentView) else { return nil }
        self.outline = outline
        self.originalTarget = outline.target
        self.originalAction = outline.doubleAction
        self.originalMenuDelegate = outline.menu?.delegate
        self.onWindowsConnect = onWindowsConnect
        super.init()
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.menu?.delegate = self
    }

    /// Instancia Windows de la fila `row`, si lo es.
    private func windowsInstance(atRow row: Int) -> InstanceInfo? {
        guard row >= 0, let item = outline?.item(atRow: row),
              let node = Mirror(reflecting: item).children.first(where: { $0.label == "node" })?.value as? ExplorerNode,
              case .instance(let instance) = node, instance.os == .windows
        else { return nil }
        return instance
    }

    @objc private func doubleClicked(_ sender: Any?) {
        if let instance = windowsInstance(atRow: outline?.clickedRow ?? -1) {
            onWindowsConnect(instance)
        } else if let originalAction {
            NSApp.sendAction(originalAction, to: originalTarget, from: sender)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        originalMenuDelegate?.menuNeedsUpdate?(menu)
        guard let instance = windowsInstance(atRow: outline?.clickedRow ?? -1),
              let connect = menu.items.first(where: { $0.title == ExplorerCommand.connect.title })
        else { return }
        connect.target = self
        connect.action = #selector(connectFromMenu(_:))
        connect.representedObject = RdpMenuPayload(instance: instance)
        connect.isEnabled = true
        connect.badge = nil
        connect.toolTip = "Abrir RDP con Windows App vía IAP"
    }

    @objc private func connectFromMenu(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? RdpMenuPayload { onWindowsConnect(payload.instance) }
    }

    private final class RdpMenuPayload: NSObject {
        let instance: InstanceInfo
        init(instance: InstanceInfo) { self.instance = instance }
    }

    private static func findOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = findOutline(in: subview) { return found }
        }
        return nil
    }
}
