// SSH Relay v4: encode/decode wire (port fiel de SshRelayFormat.cs, iap-desktop).
//
// Todos los enteros son big-endian. Layouts:
//   Tag                  00-01 tag
//   CONNECT_SUCCESS_SID  00-01 tag | 02-05 len | 06-* SID (ASCII)
//   RECONNECT_SUCCESS_ACK 00-01 tag | 02-09 ack (UInt64)
//   ACK                  00-01 tag | 02-09 ack (UInt64)
//   DATA                 00-01 tag | 02-05 len | 06-* payload (1...16K)
//   LONG_CLOSE           00-01 tag | 02-05 code | 06-09 len | 0A-* reason (UTF-8)
//
// Igual que en C#, `encode(into:)` escribe al inicio de un buffer que puede ser
// mayor que el mensaje, y `decode` lee de un buffer que puede traer bytes de
// sobra; ambos devuelven los bytes consumidos.
//
// Divergencias deliberadas respecto al C# (los `Debug.Assert` pasan a errores):
// - decode valida el tag esperado (`unexpectedTag`).
// - decode rechaza longitudes de array > 16K en SID/DATA y DATA de longitud 0.
// - RECONNECT_SUCCESS_ACK codifica los 64 bits (el C# trunca a UInt32 por un cast).
// - SID con caracteres no ASCII se rechaza en vez de sustituirse por '?'.

/// Errores de codificación/decodificación del relay.
public enum SshRelayFormatError: Error, Sendable, Equatable {
    /// Buffer de salida demasiado pequeño o mensaje de entrada truncado
    /// (C#: `ArgumentException("Message is truncated")`).
    case truncated(required: Int, available: Int)
    /// El tag del mensaje no es el que espera el decoder.
    case unexpectedTag(expected: UInt16, actual: UInt16)
    /// Longitud de array fuera de rango (> 16K, o 0 en DATA).
    case invalidArrayLength(UInt32)
    case emptySid
    case nonASCIISid
    /// DATA vacío (C#: "At least 1 byte must be sent at once").
    case emptyPayload
    /// DATA > 16K (C#: "At most 16384 bytes can be sent at once").
    case payloadTooLarge(Int)
    /// Rango `offset/length` fuera de los límites del array origen.
    case invalidRange
    /// Reason de LONG_CLOSE > 16K bytes UTF-8.
    case reasonTooLarge(Int)
    /// Buffer destino de DATA demasiado pequeño (C#: `IndexOutOfRangeException`).
    case targetBufferTooSmall
}

public enum SshRelayFormat {
    /// Tamaño máximo de array: 16K según la especificación del protocolo.
    public static let maxArrayLength = 16 * 1024

    /// DATA es el mensaje más grande.
    public static let maxMessageSize = 6 + maxArrayLength
    public static let minMessageSize = 7

    // MARK: - Tag

    public enum Tag {
        public static let length = 2

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            _ tag: SshRelayMessageTag
        ) throws(SshRelayFormatError) -> Int {
            try requireSize(buffer, length)
            writeUInt16(tag.rawValue, to: &buffer, at: 0)
            return length
        }

        /// Devuelve el tag crudo: los tags desconocidos se ignoran, no son error.
        public static func decode(
            _ message: [UInt8]
        ) throws(SshRelayFormatError) -> (rawTag: UInt16, bytesRead: Int) {
            try requireSize(message, length)
            return (readUInt16(message, at: 0), length)
        }
    }

    // MARK: - CONNECT_SUCCESS_SID

    public enum ConnectSuccessSid {
        public static let headerLength = 6

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            sid: String
        ) throws(SshRelayFormatError) -> Int {
            guard !sid.isEmpty else { throw .emptySid }
            let sidBytes = Array(sid.utf8)
            guard sidBytes.allSatisfy({ $0 < 0x80 }) else { throw .nonASCIISid }

            let required = headerLength + sidBytes.count
            try requireSize(buffer, required)

            writeUInt16(SshRelayMessageTag.connectSuccessSid.rawValue, to: &buffer, at: 0)
            writeUInt32(UInt32(sidBytes.count), to: &buffer, at: 2)
            buffer.replaceSubrange(6..<required, with: sidBytes)
            return required
        }

        public static func encode(sid: String) throws(SshRelayFormatError) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: headerLength + sid.utf8.count)
            try encode(into: &buffer, sid: sid)
            return buffer
        }

        public static func decode(
            _ message: [UInt8]
        ) throws(SshRelayFormatError) -> (sid: String, bytesRead: Int) {
            try requireSize(message, headerLength)
            try requireTag(message, .connectSuccessSid)

            let arrayLength = readUInt32(message, at: 2)
            guard arrayLength <= SshRelayFormat.maxArrayLength else {
                throw .invalidArrayLength(arrayLength)
            }
            let total = headerLength + Int(arrayLength)
            try requireSize(message, total)

            // Como Encoding.ASCII.GetString: bytes > 0x7F se convierten en '?'.
            let ascii = message[headerLength..<total].map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }
            return (String(decoding: ascii, as: UTF8.self), total)
        }
    }

    // MARK: - RECONNECT_SUCCESS_ACK

    public enum ReconnectAck {
        public static let messageLength = 10

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            ack: UInt64
        ) throws(SshRelayFormatError) -> Int {
            try encodeAck(into: &buffer, tag: .reconnectSuccessAck, ack: ack)
        }

        public static func encode(ack: UInt64) -> [UInt8] {
            makeAck(tag: .reconnectSuccessAck, ack: ack)
        }

        public static func decode(
            _ message: [UInt8]
        ) throws(SshRelayFormatError) -> (ack: UInt64, bytesRead: Int) {
            try decodeAck(message, tag: .reconnectSuccessAck)
        }
    }

    // MARK: - ACK

    public enum Ack {
        public static let messageLength = 10

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            ack: UInt64
        ) throws(SshRelayFormatError) -> Int {
            try encodeAck(into: &buffer, tag: .ack, ack: ack)
        }

        public static func encode(ack: UInt64) -> [UInt8] {
            makeAck(tag: .ack, ack: ack)
        }

        public static func decode(
            _ message: [UInt8]
        ) throws(SshRelayFormatError) -> (ack: UInt64, bytesRead: Int) {
            try decodeAck(message, tag: .ack)
        }
    }

    // MARK: - DATA

    public enum Data {
        public static let headerLength = 6
        public static let maxPayloadLength = SshRelayFormat.maxArrayLength
        public static let maxMessageLength = maxPayloadLength + headerLength

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            data: [UInt8],
            offset: Int = 0,
            length: Int
        ) throws(SshRelayFormatError) -> Int {
            if length > maxPayloadLength {
                throw .payloadTooLarge(length)
            } else if length <= 0 {
                throw .emptyPayload
            }
            guard offset >= 0, offset <= data.count - length else { throw .invalidRange }

            let required = headerLength + length
            try requireSize(buffer, required)

            writeUInt16(SshRelayMessageTag.data.rawValue, to: &buffer, at: 0)
            writeUInt32(UInt32(length), to: &buffer, at: 2)
            buffer.replaceSubrange(headerLength..<required, with: data[offset..<(offset + length)])
            return required
        }

        public static func encode(_ payload: [UInt8]) throws(SshRelayFormatError) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: headerLength + payload.count)
            try encode(into: &buffer, data: payload, length: payload.count)
            return buffer
        }

        /// Copia el payload en `target[targetOffset...]`; `targetLength` es el
        /// espacio disponible, como en el C#.
        public static func decode(
            _ message: [UInt8],
            into target: inout [UInt8],
            targetOffset: Int = 0,
            targetLength: Int
        ) throws(SshRelayFormatError) -> (dataLength: Int, bytesRead: Int) {
            let (payload, bytesRead) = try decode(message)
            guard targetOffset >= 0, targetLength >= 0,
                  payload.count <= targetLength,
                  targetOffset <= target.count - targetLength
            else { throw .targetBufferTooSmall }

            target.replaceSubrange(targetOffset..<(targetOffset + payload.count), with: payload)
            return (payload.count, bytesRead)
        }

        public static func decode(
            _ message: [UInt8]
        ) throws(SshRelayFormatError) -> (payload: ArraySlice<UInt8>, bytesRead: Int) {
            try requireSize(message, headerLength + 1)
            try requireTag(message, .data)

            let dataLength = readUInt32(message, at: 2)
            guard dataLength > 0, dataLength <= maxPayloadLength else {
                throw .invalidArrayLength(dataLength)
            }
            let total = headerLength + Int(dataLength)
            try requireSize(message, total)
            return (message[headerLength..<total], total)
        }
    }

    // MARK: - LONG_CLOSE

    public enum LongClose {
        public static let minMessageLength = 10

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            code: UInt32,
            reason: String?
        ) throws(SshRelayFormatError) -> Int {
            let reasonBytes = Array((reason ?? "").utf8)
            let required = minMessageLength + reasonBytes.count

            // Mismo orden de validación que el C#: primero buffer, luego límite.
            try requireSize(buffer, required)
            guard reasonBytes.count <= SshRelayFormat.maxArrayLength else {
                throw .reasonTooLarge(reasonBytes.count)
            }

            writeUInt16(SshRelayMessageTag.longClose.rawValue, to: &buffer, at: 0)
            writeUInt32(code, to: &buffer, at: 2)
            writeUInt32(UInt32(reasonBytes.count), to: &buffer, at: 6)
            buffer.replaceSubrange(minMessageLength..<required, with: reasonBytes)
            return required
        }

        @discardableResult
        public static func encode(
            into buffer: inout [UInt8],
            code: SshRelayCloseCode,
            reason: String?
        ) throws(SshRelayFormatError) -> Int {
            try encode(into: &buffer, code: code.rawValue, reason: reason)
        }

        public static func encode(
            code: SshRelayCloseCode,
            reason: String?
        ) throws(SshRelayFormatError) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: minMessageLength + (reason?.utf8.count ?? 0))
            try encode(into: &buffer, code: code.rawValue, reason: reason)
            return buffer
        }

        /// `code` es crudo: el servidor puede mandar códigos no listados en
        /// `SshRelayCloseCode`. El reason se decodifica UTF-8 con sustitución (U+FFFD).
        public static func decode(
            _ message: [UInt8]
        ) throws(SshRelayFormatError) -> (code: UInt32, reason: String, bytesRead: Int) {
            try requireSize(message, minMessageLength)
            try requireTag(message, .longClose)

            let code = readUInt32(message, at: 2)
            let reasonLength = readUInt32(message, at: 6)
            let total = minMessageLength + Int(reasonLength)
            try requireSize(message, total)

            let reason = String(decoding: message[minMessageLength..<total], as: UTF8.self)
            return (code, reason, total)
        }
    }

    // MARK: - Decode genérico

    /// Decodifica un mensaje completo según su tag. Tags no manejados
    /// (desconocidos, DEPRECATED, UNUSED_*) dan `.unknown` sin error.
    public static func decode(
        _ message: [UInt8]
    ) throws(SshRelayFormatError) -> (message: SshRelayMessage, bytesRead: Int) {
        let (rawTag, tagLength) = try Tag.decode(message)
        switch SshRelayMessageTag(rawValue: rawTag) {
        case .connectSuccessSid:
            let (sid, n) = try ConnectSuccessSid.decode(message)
            return (.connectSuccessSid(sid), n)
        case .reconnectSuccessAck:
            let (ack, n) = try ReconnectAck.decode(message)
            return (.reconnectSuccessAck(ack), n)
        case .data:
            let (payload, n) = try Data.decode(message)
            return (.data(Array(payload)), n)
        case .ack:
            let (ack, n) = try Ack.decode(message)
            return (.ack(ack), n)
        case .longClose:
            let (code, reason, n) = try LongClose.decode(message)
            return (.longClose(code: code, reason: reason), n)
        case .unused0, .deprecated, .unused5, .unused6, .unused8, nil:
            return (.unknown(tag: rawTag), tagLength)
        }
    }

    // MARK: - Helpers

    private static func requireSize(_ buffer: [UInt8], _ size: Int) throws(SshRelayFormatError) {
        if buffer.count < size {
            throw .truncated(required: size, available: buffer.count)
        }
    }

    private static func requireTag(
        _ message: [UInt8],
        _ expected: SshRelayMessageTag
    ) throws(SshRelayFormatError) {
        let actual = readUInt16(message, at: 0)
        if actual != expected.rawValue {
            throw .unexpectedTag(expected: expected.rawValue, actual: actual)
        }
    }

    private static func encodeAck(
        into buffer: inout [UInt8],
        tag: SshRelayMessageTag,
        ack: UInt64
    ) throws(SshRelayFormatError) -> Int {
        try requireSize(buffer, Ack.messageLength)
        writeUInt16(tag.rawValue, to: &buffer, at: 0)
        writeUInt64(ack, to: &buffer, at: 2)
        return Ack.messageLength
    }

    private static func makeAck(tag: SshRelayMessageTag, ack: UInt64) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Ack.messageLength)
        writeUInt16(tag.rawValue, to: &buffer, at: 0)
        writeUInt64(ack, to: &buffer, at: 2)
        return buffer
    }

    private static func decodeAck(
        _ message: [UInt8],
        tag: SshRelayMessageTag
    ) throws(SshRelayFormatError) -> (ack: UInt64, bytesRead: Int) {
        try requireSize(message, Ack.messageLength)
        try requireTag(message, tag)
        return (readUInt64(message, at: 2), Ack.messageLength)
    }

    private static func writeUInt16(_ value: UInt16, to buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeUInt32(_ value: UInt32, to buffer: inout [UInt8], at offset: Int) {
        for i in 0..<4 {
            buffer[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (3 - i)))
        }
    }

    private static func writeUInt64(_ value: UInt64, to buffer: inout [UInt8], at offset: Int) {
        for i in 0..<8 {
            buffer[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * (7 - i)))
        }
    }

    private static func readUInt16(_ buffer: [UInt8], at offset: Int) -> UInt16 {
        UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
    }

    private static func readUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(buffer[offset + $1]) }
    }

    private static func readUInt64(_ buffer: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(buffer[offset + $1]) }
    }
}
