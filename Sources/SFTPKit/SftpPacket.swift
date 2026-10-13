// GH-55 (T-SFTP-2): framing SFTP v3 (draft-ietf-secsh-filexfer-02) propio sobre
// `SshDataChannel` (decisión en specs/sftp/transport-decision.md).
// Paquete: `uint32 length | byte type | payload`; las respuestas (salvo VERSION)
// empiezan por `uint32 request-id`.
import Foundation

/// Tipos de paquete SFTP v3 (valores del protocolo, no reasignables).
public enum SftpPacketType: UInt8, Sendable, CaseIterable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

/// Un paquete completo (sin el campo `length`).
public struct SftpPacket: Sendable, Equatable {
    /// Límite de OpenSSH (`SFTP_MAX_MSG_LENGTH`): un `length` mayor es un
    /// servidor roto u hostil; se rechaza antes de reservar memoria.
    public static let maxLength = 256 * 1024

    public let type: SftpPacketType
    public let payload: Data

    public init(type: SftpPacketType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// `uint32 length | byte type | payload`.
    public func encoded() -> Data {
        var writer = SftpWriter()
        writer.uint32(UInt32(payload.count + 1))
        writer.byte(type.rawValue)
        writer.raw(payload)
        return writer.data
    }

    /// Petición con `request-id` delante del cuerpo.
    static func request(_ type: SftpPacketType, id: UInt32, _ body: (inout SftpWriter) -> Void = { _ in }) -> SftpPacket {
        var writer = SftpWriter()
        writer.uint32(id)
        body(&writer)
        return SftpPacket(type: type, payload: writer.data)
    }

    /// `SSH_FXP_INIT(version)` (sin request-id).
    static func initialize(version: UInt32) -> SftpPacket {
        var writer = SftpWriter()
        writer.uint32(version)
        return SftpPacket(type: .initialize, payload: writer.data)
    }
}

/// Reensamblado: un paquete SFTP puede llegar partido en varios mensajes del
/// canal SSH, o varios paquetes en uno.
struct SftpFramer: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Siguiente paquete completo, `nil` si faltan bytes.
    mutating func next() throws(SftpError) -> SftpPacket? {
        guard buffer.count >= 4 else { return nil }
        let start = buffer.startIndex
        let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
        guard length >= 1, length <= SftpPacket.maxLength else { throw .malformedPacket }
        guard buffer.count >= 4 + length else { return nil }
        let rawType = buffer[start + 4]
        let payload = Data(buffer[(start + 5)..<(start + 4 + length)])
        buffer = Data(buffer[(start + 4 + length)...])
        guard let type = SftpPacketType(rawValue: rawType) else { throw .malformedPacket }
        return SftpPacket(type: type, payload: payload)
    }
}

// MARK: - Codificación de tipos SSH (RFC 4251 §5)

struct SftpWriter: Sendable {
    private(set) var data = Data()

    mutating func byte(_ value: UInt8) { data.append(value) }

    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    mutating func uint64(_ value: UInt64) {
        uint32(UInt32(value >> 32))
        uint32(UInt32(value & 0xffff_ffff))
    }

    mutating func string(_ bytes: Data) {
        uint32(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func string(_ text: String) { string(Data(text.utf8)) }

    mutating func raw(_ bytes: Data) { data.append(bytes) }
}

struct SftpReader: Sendable {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func byte() throws(SftpError) -> UInt8 {
        guard offset < data.endIndex else { throw .malformedPacket }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint32() throws(SftpError) -> UInt32 {
        guard data.endIndex - offset >= 4 else { throw .malformedPacket }
        defer { offset += 4 }
        return data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func uint64() throws(SftpError) -> UInt64 {
        let high = UInt64(try uint32())
        return high << 32 | UInt64(try uint32())
    }

    mutating func string() throws(SftpError) -> Data {
        let length = Int(try uint32())
        guard length <= data.endIndex - offset else { throw .malformedPacket }
        defer { offset += length }
        return Data(data[offset..<offset + length])
    }

    /// Texto UTF-8 (mensajes, extensiones). Bytes inválidos → U+FFFD.
    mutating func text() throws(SftpError) -> String {
        String(decoding: try string(), as: UTF8.self)
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return Data(data[offset...])
    }
}
