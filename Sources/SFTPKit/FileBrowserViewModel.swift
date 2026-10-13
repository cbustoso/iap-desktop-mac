// GH-60 (T-SFTP-5): modelo del explorador de ficheros remoto. Sin AppKit: la
// vista (ExplorerUI.SftpBrowserView) lo consume vía un adaptador en la App.
// Columnas Nombre/Tamaño/Modificado/Permisos; breadcrumb; subida/descarga con
// progreso. Nunca registra rutas ni contenido (T-SFTP-8).
import Foundation

@MainActor
public final class FileBrowserViewModel {
    /// Fila del listado (ruta remota completa + columnas ya formateadas).
    public struct Entry: Sendable, Equatable, Identifiable {
        public let info: SftpFileInfo
        public let path: String
        public var id: String { path }
        public var name: String { info.name }
        public var isDirectory: Bool { info.isDirectory }
        /// Descargable: ficheros normales y enlaces (el servidor los sigue al abrir).
        public var isDownloadable: Bool { info.isRegular || info.isSymbolicLink }
    }

    public struct Crumb: Sendable, Equatable {
        public let title: String
        public let path: String
    }

    public enum Direction: Sendable, Equatable { case upload, download }

    public enum TransferState: Sendable, Equatable {
        case transferring
        case completed
        case failed(String)
        case cancelled
    }

    public struct Transfer: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let direction: Direction
        public internal(set) var bytesDone: UInt64
        public let bytesTotal: UInt64?
        public internal(set) var state: TransferState

        /// 0…1, o `nil` si el tamaño total no se conoce.
        public var fraction: Double? {
            guard let bytesTotal else { return nil }
            return bytesTotal == 0 ? 1 : min(1, Double(bytesDone) / Double(bytesTotal))
        }
    }

    /// Bloque de copia local ↔ remoto (8 bloques SFTP de 32 KiB en vuelo).
    public static let copyChunk = 256 * 1024

    public private(set) var path = "/"
    public private(set) var entries: [Entry] = []
    public private(set) var transfers: [Transfer] = []
    public private(set) var isLoading = false
    /// Último error visible (texto sin rutas completas).
    public private(set) var lastError: String?
    /// Avisa a la vista de cualquier cambio de estado.
    public var onChange: (@MainActor () -> Void)?

    private let channel: SftpChannel
    private let timeZone: TimeZone
    private var generation = 0
    private var cancelled: Set<UUID> = []

    public init(channel: SftpChannel, timeZone: TimeZone = .current) {
        self.channel = channel
        self.timeZone = timeZone
    }

    // MARK: - Navegación

    /// Arranca en el directorio de inicio del usuario (`REALPATH "."`).
    public func start() async {
        do {
            await navigate(to: try await channel.realPath("."))
        } catch {
            await navigate(to: "/")
        }
    }

    public func navigate(to newPath: String) async {
        let target = Self.normalized(newPath)
        generation += 1
        let current = generation
        isLoading = true
        notify()
        do {
            let files = try await channel.listFiles(atPath: target)
            // Una navegación posterior ya ganó: se descarta este resultado.
            guard current == generation else { return }
            path = target
            entries = Self.sorted(files.filter { Self.isSafeName($0.name) }.map {
                Entry(info: $0, path: Self.join(target, $0.name))
            })
            lastError = nil
        } catch {
            guard current == generation else { return }
            lastError = Self.message(for: error, name: Self.baseName(target))
        }
        isLoading = false
        notify()
    }

    public func open(_ entry: Entry) async {
        if entry.isDirectory { await navigate(to: entry.path) }
    }

    public func goUp() async {
        await navigate(to: Self.parent(of: path))
    }

    public func refresh() async {
        await navigate(to: path)
    }

    public var breadcrumb: [Crumb] { Self.breadcrumb(for: path) }

    // MARK: - Transferencias

    /// Nombres que ya existen en el directorio actual (para confirmar antes de
    /// sobrescribir: subir trunca).
    public func conflictingNames(for localURLs: [URL]) -> [String] {
        let existing = Set(entries.map(\.name))
        return localURLs.map(\.lastPathComponent).filter { existing.contains($0) }
    }

    /// Sube `localURL` al directorio actual (sobrescribe) y refresca el listado.
    @discardableResult
    public func upload(_ localURL: URL) async -> Transfer {
        let name = localURL.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.uint64Value
        let id = begin(name: name, direction: .upload, total: size)
        let destination = Self.join(path, name)
        do {
            guard Self.isSafeName(name) else { throw SftpError.permissionDenied }
            let source = try FileHandle(forReadingFrom: localURL)
            defer { try? source.close() }
            let remote = try await channel.openFile(atPath: destination, mode: .writeCreateTruncate)
            do {
                while true {
                    try checkCancelled(id)
                    guard let chunk = try source.read(upToCount: Self.copyChunk), !chunk.isEmpty else { break }
                    try await remote.write(chunk)
                    progress(id, by: UInt64(chunk.count))
                }
                await remote.close()
            } catch {
                await remote.close()
                throw error
            }
            finish(id, .completed)
        } catch {
            finish(id, state(for: error, id: id, name: name))
        }
        await refresh()
        return transfer(id)
    }

    /// Descarga `entry` a `localURL` (fichero). Si falla, borra el parcial.
    @discardableResult
    public func download(_ entry: Entry, to localURL: URL) async -> Transfer {
        let id = begin(name: entry.name, direction: .download, total: entry.info.size)
        do {
            guard entry.isDownloadable else { throw SftpError.unexpectedResponse(.read) }
            guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let sink = try FileHandle(forWritingTo: localURL)
            let remote = try await channel.openFile(atPath: entry.path, mode: .readOnly)
            do {
                while true {
                    try checkCancelled(id)
                    let chunk = try await remote.read(upTo: Self.copyChunk)
                    if chunk.isEmpty { break }
                    try sink.write(contentsOf: chunk)
                    progress(id, by: UInt64(chunk.count))
                }
                await remote.close()
                try sink.close()
            } catch {
                await remote.close()
                try? sink.close()
                throw error
            }
            finish(id, .completed)
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            finish(id, state(for: error, id: id, name: entry.name))
        }
        return transfer(id)
    }

    /// Cancela entre bloques (el bloque en curso termina).
    public func cancel(_ transferID: UUID) {
        cancelled.insert(transferID)
    }

    public func transfer(_ id: UUID) -> Transfer {
        transfers.first { $0.id == id }!
    }

    private func begin(name: String, direction: Direction, total: UInt64?) -> UUID {
        let id = UUID()
        transfers.append(Transfer(id: id, name: name, direction: direction, bytesDone: 0, bytesTotal: total, state: .transferring))
        notify()
        return id
    }

    private func progress(_ id: UUID, by count: UInt64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].bytesDone += count
        notify()
    }

    private func finish(_ id: UUID, _ state: TransferState) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].state = state
        cancelled.remove(id)
        notify()
    }

    private struct Cancelled: Error {}

    private func checkCancelled(_ id: UUID) throws {
        if cancelled.contains(id) { throw Cancelled() }
    }

    private func state(for error: any Error, id: UUID, name: String) -> TransferState {
        error is Cancelled ? .cancelled : .failed(Self.message(for: error, name: name))
    }

    private func notify() { onChange?() }

    // MARK: - Formato de columnas

    /// `1.5 KB` (binario, 1 decimal; independiente del locale).
    public static func sizeText(_ entry: Entry) -> String {
        guard !entry.isDirectory, let size = entry.info.size else { return "—" }
        return byteCount(size)
    }

    public static func byteCount(_ size: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(size)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(size) B" : String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }

    public func modifiedText(_ entry: Entry) -> String {
        guard let date = entry.info.lastModifiedDate else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// `drwxr-xr-x` como `ls -l` (tipo + permisos).
    public static func permissionsText(_ entry: Entry) -> String {
        typeCharacter(entry.info.permissions.fileType) + entry.info.permissions.symbolic
    }

    static func typeCharacter(_ type: PosixFileMode.FileType) -> String {
        switch type {
        case .directory: return "d"
        case .symbolicLink: return "l"
        case .regular: return "-"
        case .fifo: return "p"
        case .characterDevice: return "c"
        case .blockSpecial: return "b"
        case .socket: return "s"
        case .unknown: return "?"
        }
    }

    // MARK: - Rutas

    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." && !part.isEmpty {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func parent(of path: String) -> String {
        normalized(path + "/..")
    }

    static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    static func breadcrumb(for path: String) -> [Crumb] {
        var crumbs = [Crumb(title: "/", path: "/")]
        var current = ""
        for part in normalized(path).split(separator: "/") {
            current += "/" + part
            crumbs.append(Crumb(title: String(part), path: current))
        }
        return crumbs
    }

    /// Un servidor hostil podría devolver nombres con `/` o `..` para escapar
    /// del directorio (en rutas remotas o al guardar descargas): se descartan.
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Mensaje para el usuario: solo el nombre base, nunca la ruta completa.
    static func message(for error: any Error, name: String) -> String {
        switch error {
        case SftpError.fileNotFound: return "\(name): no existe."
        case SftpError.permissionDenied: return "\(name): permiso denegado."
        case SftpError.sessionLost, SftpError.channelClosed: return "Conexión SFTP perdida."
        case SftpError.protocolError(_, let message): return "\(name): \(message.isEmpty ? "error del servidor" : message)."
        default: return "\(name): no se pudo completar la operación."
        }
    }
}
