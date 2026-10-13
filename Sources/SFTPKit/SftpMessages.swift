import Foundation

/// Errores tipados de SFTP (specs/sftp/design.md "Errores tipados").
public enum SftpError: Error, Sendable, Equatable {
    /// La `SshSession` ya está perdida o cerrada: no se intenta red.
    case sessionLost
    /// `SSH_FXP_STATUS` distinto de OK/EOF sin traducción más concreta.
    case protocolError(code: UInt32, message: String)
    /// El servidor no habla SFTP v3.
    case unsupportedVersion(negotiated: UInt32)
    case fileNotFound
    case permissionDenied
    case nameConflict
    case transferCancelled
    /// Paquete mal formado, tipo desconocido o `length` fuera de rango.
    case malformedPacket
    /// Respuesta de un tipo que no corresponde a la petición.
    case unexpectedResponse(SftpPacketType)
    /// El canal SFTP se cerró con peticiones pendientes.
    case channelClosed
    /// El servidor no respondió a tiempo.
    case timeout
}

/// Códigos `SSH_FX_*` de `SSH_FXP_STATUS`.
public struct SftpStatus: Sendable, Equatable {
    public static let ok: UInt32 = 0
    public static let eof: UInt32 = 1
    public static let noSuchFile: UInt32 = 2
    public static let permissionDenied: UInt32 = 3
    public static let failure: UInt32 = 4
    public static let badMessage: UInt32 = 5
    public static let noConnection: UInt32 = 6
    public static let connectionLost: UInt32 = 7
    public static let operationUnsupported: UInt32 = 8

    public let code: UInt32
    public let message: String

    public init(code: UInt32, message: String) {
        self.code = code
        self.message = message
    }

    /// Error para un STATUS que no es OK (EOF lo trata cada operación).
    public var error: SftpError? {
        switch code {
        case Self.ok: return nil
        case Self.noSuchFile: return .fileNotFound
        case Self.permissionDenied: return .permissionDenied
        case Self.noConnection, Self.connectionLost: return .sessionLost
        default: return .protocolError(code: code, message: message)
        }
    }
}

/// Entrada de `SSH_FXP_NAME`.
public struct SftpName: Sendable, Equatable {
    public let filename: String
    /// `ls -l` del servidor; solo informativo (no se parsea).
    public let longname: String
    public let attributes: SftpAttributes
}

/// Respuesta de servidor ya decodificada (todas salvo VERSION llevan id).
enum SftpResponse: Sendable, Equatable {
    case status(SftpStatus)
    case handle(Data)
    case data(Data)
    case name([SftpName])
    case attrs(SftpAttributes)
    case extendedReply(Data)

    /// `(request-id, respuesta)`; VERSION se trata aparte.
    static func parse(_ packet: SftpPacket) throws(SftpError) -> (id: UInt32, response: SftpResponse) {
        var reader = SftpReader(packet.payload)
        let id = try reader.uint32()
        let response: SftpResponse
        switch packet.type {
        case .status:
            let code = try reader.uint32()
            // OpenSSH siempre envía mensaje + idioma; servidores v3 antiguos, a veces no.
            let message = reader.isAtEnd ? "" : try reader.text()
            response = .status(SftpStatus(code: code, message: message))
        case .handle:
            response = .handle(try reader.string())
        case .data:
            response = .data(try reader.string())
        case .name:
            let count = try reader.uint32()
            var names: [SftpName] = []
            for _ in 0..<count {
                names.append(SftpName(
                    filename: try reader.text(), longname: try reader.text(),
                    attributes: try SftpAttributes.decode(from: &reader)))
            }
            response = .name(names)
        case .attrs:
            response = .attrs(try SftpAttributes.decode(from: &reader))
        case .extendedReply:
            response = .extendedReply(reader.rest())
        case .initialize, .version, .open, .close, .read, .write, .lstat, .fstat, .setstat, .fsetstat,
             .opendir, .readdir, .remove, .mkdir, .rmdir, .realpath, .stat, .rename, .readlink, .symlink, .extended:
            // Peticiones o VERSION: nunca son respuestas con id.
            throw .unexpectedResponse(packet.type)
        }
        return (id, response)
    }
}

/// `SSH_FXP_VERSION`: versión + extensiones (`nombre` → `datos`).
struct SftpVersion: Sendable, Equatable {
    let version: UInt32
    let extensions: [String: String]

    static func parse(_ packet: SftpPacket) throws(SftpError) -> SftpVersion {
        guard packet.type == .version else { throw .unexpectedResponse(packet.type) }
        var reader = SftpReader(packet.payload)
        let version = try reader.uint32()
        var extensions: [String: String] = [:]
        while !reader.isAtEnd {
            extensions[try reader.text()] = try reader.text()
        }
        return SftpVersion(version: version, extensions: extensions)
    }
}
