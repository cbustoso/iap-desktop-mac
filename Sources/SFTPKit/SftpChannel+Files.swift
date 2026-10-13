// GH-57 (T-SFTP-3/4): operaciones de ficheros y directorios sobre el canal.
// Mapeo 1:1 con SFTP v3: OPENDIR+READDIR*+CLOSE, LSTAT, MKDIR, RMDIR,
// REMOVE, RENAME, OPEN.
import Foundation

/// Modo de apertura → flags `SSH_FXF_*` de `SSH_FXP_OPEN`.
public enum SftpOpenMode: Sendable, Equatable, CaseIterable {
    case readOnly
    /// Subida desde cero: crea o trunca.
    case writeCreateTruncate
    /// Subida reanudable: crea si no existe y **no** trunca; cada WRITE lleva su
    /// offset, así que se continúa con `seek(to: bytesYaEnviados)`. No usa
    /// `APPEND` (con él algunos servidores ignoran el offset de cada WRITE).
    case writeCreateOrAppend

    public static let read: UInt32 = 0x01
    public static let write: UInt32 = 0x02
    public static let append: UInt32 = 0x04
    public static let create: UInt32 = 0x08
    public static let truncate: UInt32 = 0x10
    public static let exclusive: UInt32 = 0x20

    public var flags: UInt32 {
        switch self {
        case .readOnly: return Self.read
        case .writeCreateTruncate: return Self.write | Self.create | Self.truncate
        case .writeCreateOrAppend: return Self.write | Self.create
        }
    }
}

extension SftpChannel {
    /// Contenido del directorio (sin `.` ni `..`), en el orden del servidor.
    /// Pagina READDIR hasta `EOF` y cierra siempre el handle.
    public nonisolated func listFiles(atPath remotePath: String) async throws -> [SftpFileInfo] {
        let handle = try await openHandle(.opendir) { $0.string(remotePath) }
        do {
            var files: [SftpFileInfo] = []
            while true {
                switch try await request(.readdir, { $0.string(handle) }) {
                case .name(let names):
                    files += names
                        .filter { $0.filename != "." && $0.filename != ".." }
                        .map { SftpFileInfo(name: $0.filename, attributes: $0.attributes) }
                case .status(let status) where status.code == SftpStatus.eof:
                    await closeHandle(handle)
                    return files
                case .status(let status):
                    throw status.error ?? SftpError.malformedPacket
                default:
                    throw SftpError.unexpectedResponse(.readdir)
                }
            }
        } catch {
            await closeHandle(handle)
            throw error
        }
    }

    /// `LSTAT`: atributos del propio enlace simbólico, no de su destino.
    public nonisolated func attributes(atPath remotePath: String) async throws -> SftpFileInfo {
        switch try await request(.lstat, { $0.string(remotePath) }) {
        case .attrs(let attributes):
            return SftpFileInfo(name: Self.baseName(remotePath), attributes: attributes)
        case .status(let status):
            throw status.error ?? SftpError.malformedPacket
        default:
            throw SftpError.unexpectedResponse(.lstat)
        }
    }

    public nonisolated func makeDirectory(atPath remotePath: String, permissions: PosixFileMode = [
        .ownerRead, .ownerWrite, .ownerExecute, .groupRead, .groupExecute, .otherRead, .otherExecute,
    ]) async throws {
        try await expectOK(.mkdir) {
            $0.string(remotePath)
            SftpAttributes(permissions: permissions.permissionBits.rawValue).encode(into: &$0)
        }
    }

    public nonisolated func removeDirectory(atPath remotePath: String) async throws {
        try await expectOK(.rmdir) { $0.string(remotePath) }
    }

    public nonisolated func remove(atPath remotePath: String) async throws {
        try await expectOK(.remove) { $0.string(remotePath) }
    }

    /// SFTP v3 no sobrescribe: si `toPath` existe el servidor responde FAILURE.
    public nonisolated func rename(fromPath: String, toPath: String) async throws {
        try await expectOK(.rename) {
            $0.string(fromPath)
            $0.string(toPath)
        }
    }

    public nonisolated func openFile(
        atPath remotePath: String, mode: SftpOpenMode,
        permissions: PosixFileMode = [.ownerRead, .ownerWrite, .groupRead, .otherRead]
    ) async throws -> SftpFileHandle {
        let handle = try await openHandle(.open) {
            $0.string(remotePath)
            $0.uint32(mode.flags)
            // Permisos solo al crear; en lectura, ATTRS vacío.
            let attributes = mode == .readOnly
                ? SftpAttributes() : SftpAttributes(permissions: permissions.permissionBits.rawValue)
            attributes.encode(into: &$0)
        }
        return SftpFileHandle(channel: self, handle: handle, remotePath: remotePath)
    }

    // MARK: - Ayudas

    nonisolated func openHandle(_ type: SftpPacketType, _ body: (inout SftpWriter) -> Void) async throws -> Data {
        switch try await request(type, body) {
        case .handle(let handle): return handle
        case .status(let status): throw status.error ?? SftpError.malformedPacket
        default: throw SftpError.unexpectedResponse(type)
        }
    }

    nonisolated func expectOK(_ type: SftpPacketType, _ body: (inout SftpWriter) -> Void) async throws {
        switch try await request(type, body) {
        case .status(let status):
            if let error = status.error { throw error }
        default:
            throw SftpError.unexpectedResponse(type)
        }
    }

    /// CLOSE sin propagar errores (el handle ya no sirve de todos modos).
    nonisolated func closeHandle(_ handle: Data) async {
        _ = try? await request(.close) { $0.string(handle) }
    }

    static func baseName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
