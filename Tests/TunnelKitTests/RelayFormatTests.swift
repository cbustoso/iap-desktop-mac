// TunnelKit T-TUN-2 tests: SshRelayFormat (vectores de TestSshRelayFormat.cs + roundtrip + fuzz).
import Testing
@testable import TunnelKit

private typealias Format = SshRelayFormat

// MARK: - Constantes

@Suite("SshRelay constantes")
struct RelayConstantsTests {
    @Test func tagRawValues() {
        #expect(SshRelayMessageTag.connectSuccessSid.rawValue == 1)
        #expect(SshRelayMessageTag.reconnectSuccessAck.rawValue == 2)
        #expect(SshRelayMessageTag.deprecated.rawValue == 3)
        #expect(SshRelayMessageTag.data.rawValue == 4)
        #expect(SshRelayMessageTag.ack.rawValue == 7)
        #expect(SshRelayMessageTag.longClose.rawValue == 10)
        #expect(SshRelayMessageTag(rawValue: 9) == nil)
    }

    @Test func closeCodeRawValues() {
        let expected: [SshRelayCloseCode: UInt32] = [
            .normal: 1000, .abnormalClosure: 1006,
            .errorUnknown: 4000, .sidUnknown: 4001, .sidInUse: 4002,
            .failedToConnectToBackend: 4003, .reauthenticationRequired: 4004,
            .badAck: 4005, .invalidAck: 4006, .invalidWebsocketOpcode: 4007,
            .invalidTag: 4008, .destinationWriteFailed: 4009, .destinationReadFailed: 4010,
            .invalidData: 4013, .notAuthorized: 4033, .lookupFailed: 4047,
            .lookupFailedReconnect: 4051, .failedToRewind: 4074,
        ]
        #expect(expected.count == SshRelayCloseCode.allCases.count)
        for (code, raw) in expected { #expect(code.rawValue == raw) }
    }

    @Test func sizes() {
        #expect(Format.maxArrayLength == 16384)
        #expect(Format.maxMessageSize == 16390)
        #expect(Format.minMessageSize == 7)
        #expect(Format.Data.maxMessageLength == Format.maxMessageSize)
        #expect(Format.Ack.messageLength == 10)
        #expect(Format.ReconnectAck.messageLength == 10)
        #expect(Format.LongClose.minMessageLength == 10)
    }
}

// MARK: - Tag

@Suite("SshRelayFormat.Tag")
struct RelayTagTests {
    @Test func encodeWhenBufferSufficient() throws {
        var message = [UInt8](repeating: 0, count: 2)
        let written = try Format.Tag.encode(into: &message, .ack)
        #expect(written == 2)
        #expect(message == [0, 7])
    }

    @Test func encodeWhenBufferTooSmall() {
        var message = [UInt8](repeating: 0, count: 1)
        #expect(throws: SshRelayFormatError.truncated(required: 2, available: 1)) {
            try Format.Tag.encode(into: &message, .ack)
        }
    }

    @Test func decodeWhenMessageComplete() throws {
        let (tag, read) = try Format.Tag.decode([0, 4, 99, 99, 99, 99, 99])
        #expect(read == 2)
        #expect(SshRelayMessageTag(rawValue: tag) == .data)
    }

    @Test func decodeWhenMessageTruncated() {
        #expect(throws: SshRelayFormatError.self) { try Format.Tag.decode([0]) }
    }
}

// MARK: - CONNECT_SUCCESS_SID

@Suite("SshRelayFormat.ConnectSuccessSid")
struct RelayConnectSuccessSidTests {
    static let vector: [UInt8] = [0, 1, 0, 0, 0, 3, 0x53, 0x69, 0x64]  // "Sid"

    @Test func encodeWhenBufferSufficient() throws {
        var message = [UInt8](repeating: 0, count: 9)
        let written = try Format.ConnectSuccessSid.encode(into: &message, sid: "Sid")
        #expect(written == 9)
        #expect(message == Self.vector)
        #expect(try Format.ConnectSuccessSid.decode(message).sid == "Sid")
    }

    @Test func encodeWhenBufferTooSmall() {
        var message = [UInt8](repeating: 0, count: 8)
        #expect(throws: SshRelayFormatError.truncated(required: 9, available: 8)) {
            try Format.ConnectSuccessSid.encode(into: &message, sid: "Sid")
        }
    }

    @Test func encodeRejectsEmptyAndNonASCII() {
        #expect(throws: SshRelayFormatError.emptySid) { try Format.ConnectSuccessSid.encode(sid: "") }
        #expect(throws: SshRelayFormatError.nonASCIISid) { try Format.ConnectSuccessSid.encode(sid: "ñ") }
    }

    @Test func decodeWhenMessageComplete() throws {
        let (sid, read) = try Format.ConnectSuccessSid.decode(Self.vector)
        #expect(read == 9)
        #expect(sid == "Sid")
    }

    @Test func decodeWhenMessageTruncated() {
        #expect(throws: SshRelayFormatError.truncated(required: 10, available: 9)) {
            try Format.ConnectSuccessSid.decode([0, 1, 0, 0, 0, 4, 0x53, 0x69, 0x64])
        }
    }

    @Test func decodeMapsNonASCIIToQuestionMark() throws {
        let (sid, _) = try Format.ConnectSuccessSid.decode([0, 1, 0, 0, 0, 2, 0x41, 0xC3])
        #expect(sid == "A?")
    }

    @Test func decodeRejectsOversizedArray() {
        #expect(throws: SshRelayFormatError.invalidArrayLength(16385)) {
            try Format.ConnectSuccessSid.decode([0, 1, 0, 0, 0x40, 0x01, 0x41])
        }
    }

    @Test func decodeRejectsWrongTag() {
        #expect(throws: SshRelayFormatError.unexpectedTag(expected: 1, actual: 4)) {
            try Format.ConnectSuccessSid.decode([0, 4, 0, 0, 0, 1, 0x41])
        }
    }
}

// MARK: - RECONNECT_SUCCESS_ACK / ACK

@Suite("SshRelayFormat.ReconnectAck")
struct RelayReconnectAckTests {
    @Test func encodeWhenBufferSufficient() throws {
        var message = [UInt8](repeating: 0, count: 10)
        let written = try Format.ReconnectAck.encode(into: &message, ack: 42)
        #expect(written == 10)
        #expect(message == [0, 2, 0, 0, 0, 0, 0, 0, 0, 42])
        #expect(try Format.ReconnectAck.decode(message).ack == 42)
    }

    @Test func encodeWhenBufferTooSmall() {
        var message = [UInt8](repeating: 0, count: 9)
        #expect(throws: SshRelayFormatError.self) {
            try Format.ReconnectAck.encode(into: &message, ack: 42)
        }
    }

    @Test func encodeKeepsAll64Bits() throws {
        // El C# trunca a UInt32 al codificar; aquí se preserva el valor completo.
        let message = Format.ReconnectAck.encode(ack: 0x0102_0304_0506_0708)
        #expect(message == [0, 2, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func decodeWhenMessageComplete() throws {
        let (ack, read) = try Format.ReconnectAck.decode([0, 2, 0, 0, 0, 0, 0, 0, 0, 3])
        #expect(read == 10)
        #expect(ack == 3)
    }

    @Test func decodeWhenMessageTruncated() {
        #expect(throws: SshRelayFormatError.truncated(required: 10, available: 9)) {
            try Format.ReconnectAck.decode([0, 1, 1, 2, 3, 4, 5, 6, 7])
        }
    }
}

@Suite("SshRelayFormat.Ack")
struct RelayAckTests {
    @Test func encodeWhenBufferSufficient() throws {
        var message = [UInt8](repeating: 0, count: 10)
        let written = try Format.Ack.encode(into: &message, ack: 77)
        #expect(written == 10)
        #expect(message == [0, 7, 0, 0, 0, 0, 0, 0, 0, 77])
    }

    @Test func encodeWhenBufferTooSmall() {
        var message = [UInt8](repeating: 0, count: 9)
        #expect(throws: SshRelayFormatError.self) { try Format.Ack.encode(into: &message, ack: 77) }
    }

    @Test func decodeWhenMessageComplete() throws {
        let (ack, read) = try Format.Ack.decode([0, 7, 0, 0, 0, 0, 0, 0, 0, 3])
        #expect(read == 10)
        #expect(ack == 3)
    }

    @Test func decodeWhenMessageTruncated() {
        #expect(throws: SshRelayFormatError.self) { try Format.Ack.decode([0, 7, 1, 2, 3, 4, 5, 6, 7]) }
    }

    @Test func bigEndianMaxValue() throws {
        let message = Format.Ack.encode(ack: .max)
        #expect(message == [0, 7] + [UInt8](repeating: 0xFF, count: 8))
        #expect(try Format.Ack.decode(message).ack == .max)
    }
}

// MARK: - DATA

@Suite("SshRelayFormat.Data")
struct RelayDataTests {
    @Test func encodeWhenDataIsEmpty() {
        var message = [UInt8](repeating: 0, count: Format.Data.maxPayloadLength)
        #expect(throws: SshRelayFormatError.emptyPayload) {
            try Format.Data.encode(into: &message, data: [], length: 0)
        }
    }

    @Test func encodeWhenDataTooLarge() {
        let size = Format.Data.maxPayloadLength + 1
        var message = [UInt8](repeating: 0, count: size)
        let data = [UInt8](repeating: 0, count: size)
        #expect(throws: SshRelayFormatError.payloadTooLarge(size)) {
            try Format.Data.encode(into: &message, data: data, length: data.count)
        }
    }

    @Test func encodeWhenBufferTooSmall() {
        var message = [UInt8](repeating: 0, count: Format.maxMessageSize - 1)
        let data = [UInt8](repeating: 0, count: Format.Data.maxPayloadLength)
        #expect(throws: SshRelayFormatError.self) {
            try Format.Data.encode(into: &message, data: data, length: data.count)
        }
    }

    @Test func encodeWhenDataIsMaxSize() throws {
        var message = [UInt8](repeating: 0, count: Format.maxMessageSize)
        var data = [UInt8](repeating: 0, count: Format.Data.maxPayloadLength)
        data[0] = UInt8(ascii: "A")
        data[data.count - 1] = UInt8(ascii: "Z")

        let written = try Format.Data.encode(into: &message, data: data, length: data.count)
        #expect(written == Format.maxMessageSize)
        #expect(Array(message.prefix(6)) == [0, 4, 0, 0, 0x40, 0x00])
        #expect(message[6] == UInt8(ascii: "A"))
        #expect(message[Format.maxMessageSize - 1] == UInt8(ascii: "Z"))
    }

    @Test func encodeWhenIndexNotZero() throws {
        var message = [UInt8](repeating: 0, count: 7)
        var data = [UInt8](repeating: 0, count: Format.Data.maxPayloadLength + 1)
        data[Format.Data.maxPayloadLength] = UInt8(ascii: "D")

        let written = try Format.Data.encode(
            into: &message, data: data, offset: Format.Data.maxPayloadLength, length: 1)
        #expect(written == 7)
        #expect(message == [0, 4, 0, 0, 0, 1, 0x44])
    }

    @Test func encodeRejectsOutOfRangeSource() {
        var message = [UInt8](repeating: 0, count: 16)
        #expect(throws: SshRelayFormatError.invalidRange) {
            try Format.Data.encode(into: &message, data: [1, 2], offset: 1, length: 2)
        }
    }

    @Test func decodeWhenMessageComplete() throws {
        var data = [UInt8](repeating: 0, count: 1)
        let (length, read) = try Format.Data.decode(
            [0, 4, 0, 0, 0, 1, 0x44], into: &data, targetLength: data.count)
        #expect(read == 7)
        #expect(length == 1)
        #expect(data[0] == 0x44)
    }

    @Test func decodeWhenTargetIndexNotZero() throws {
        var data = [UInt8](repeating: 0, count: 2)
        let (length, read) = try Format.Data.decode(
            [0, 4, 0, 0, 0, 1, 0x44], into: &data, targetOffset: 1, targetLength: 1)
        #expect(read == 7)
        #expect(length == 1)
        #expect(data[1] == 0x44)
    }

    @Test func decodeWhenMessageTruncated() {
        var data = [UInt8](repeating: 0, count: 1)
        #expect(throws: SshRelayFormatError.truncated(required: 8, available: 7)) {
            try Format.Data.decode([0, 4, 0, 0, 0, 2, 0x44], into: &data, targetOffset: 1, targetLength: 1)
        }
    }

    @Test func decodeWhenTargetTooSmallForData() {
        var data = [UInt8](repeating: 0, count: 1)
        #expect(throws: SshRelayFormatError.targetBufferTooSmall) {
            try Format.Data.decode([0, 4, 0, 0, 0, 2, 0x44, 0x61], into: &data, targetLength: data.count)
        }
    }

    @Test func decodeRejectsZeroAndOversizedLength() {
        #expect(throws: SshRelayFormatError.invalidArrayLength(0)) {
            try Format.Data.decode([0, 4, 0, 0, 0, 0, 0])
        }
        #expect(throws: SshRelayFormatError.invalidArrayLength(16385)) {
            try Format.Data.decode([0, 4, 0, 0, 0x40, 0x01, 0])
        }
    }

    @Test func decodeIgnoresTrailingBytes() throws {
        let (payload, read) = try Format.Data.decode([0, 4, 0, 0, 0, 1, 0x44, 0xEE, 0xEE])
        #expect(Array(payload) == [0x44])
        #expect(read == 7)
    }
}

// MARK: - LONG_CLOSE

@Suite("SshRelayFormat.LongClose")
struct RelayLongCloseTests {
    @Test func encodeWhenBufferTooSmall() {
        var message = [UInt8](repeating: 0, count: Format.LongClose.minMessageLength - 1)
        #expect(throws: SshRelayFormatError.self) {
            try Format.LongClose.encode(into: &message, code: .errorUnknown, reason: "")
        }
    }

    @Test func encodeWhenReasonEmpty() throws {
        var message = [UInt8](repeating: 0, count: Format.LongClose.minMessageLength)
        let written = try Format.LongClose.encode(into: &message, code: .errorUnknown, reason: "")
        #expect(written == Format.LongClose.minMessageLength)
        #expect(message == [0, 10, 0, 0, 0x0F, 0xA0, 0, 0, 0, 0])
    }

    @Test func encodeNilReasonMatchesEmpty() throws {
        #expect(try Format.LongClose.encode(code: .normal, reason: nil)
            == Format.LongClose.encode(code: .normal, reason: ""))
    }

    @Test func encodeWhenReasonTooLarge() {
        let reason = String(repeating: "x", count: Format.maxArrayLength + 1)
        #expect(throws: SshRelayFormatError.reasonTooLarge(Format.maxArrayLength + 1)) {
            try Format.LongClose.encode(code: .normal, reason: reason)
        }
    }

    @Test func decodeWhenMessageComplete() throws {
        let message: [UInt8] = [
            0, 10,
            0, 0, 0x0F, 0xA1,  // 4001
            0, 0, 0, 4,
            0x46, 0x61, 0x69, 0x6C,  // "Fail"
        ]
        let (code, reason, read) = try Format.LongClose.decode(message)
        #expect(read == message.count)
        #expect(SshRelayCloseCode(rawValue: code) == .sidUnknown)
        #expect(reason == "Fail")
    }

    @Test func decodeWhenBufferTooSmall() {
        #expect(throws: SshRelayFormatError.self) {
            try Format.LongClose.decode([0, 10, 0, 0, 0xFA, 0x01, 4, 0x46, 0x61, 0x69])
        }
    }

    @Test func decodeKeepsUnknownCodeAndUTF8Reason() throws {
        let reason = "Falló ✓"
        var message = [UInt8](repeating: 0, count: 64)
        let written = try Format.LongClose.encode(into: &message, code: 4999, reason: reason)
        let decoded = try Format.LongClose.decode(message)
        #expect(decoded.code == 4999)
        #expect(SshRelayCloseCode(rawValue: decoded.code) == nil)
        #expect(decoded.reason == reason)
        #expect(decoded.bytesRead == written)
    }
}

// MARK: - Decode genérico, roundtrip y fuzz

/// PRNG determinista (SplitMix64) para que el fuzz sea reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func randomBytes(_ count: Int, using rng: inout SplitMix64) -> [UInt8] {
    (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
}

private func randomMessage(using rng: inout SplitMix64) throws -> SshRelayMessage {
    switch Int.random(in: 0..<5, using: &rng) {
    case 0:
        let length = Int.random(in: 1...64, using: &rng)
        let sid = String((0..<length).map { _ in Character(Unicode.Scalar(UInt8.random(in: 0x21...0x7E, using: &rng))) })
        return .connectSuccessSid(sid)
    case 1: return .reconnectSuccessAck(rng.next())
    case 2: return .ack(rng.next())
    case 3:
        let length = Int.random(in: 1...Format.Data.maxPayloadLength, using: &rng)
        return .data(randomBytes(length, using: &rng))
    default:
        let scalars = (0..<Int.random(in: 0...40, using: &rng)).compactMap { _ in
            Unicode.Scalar(UInt32.random(in: 0x20...0x2FFF, using: &rng))
        }
        return .longClose(code: UInt32.random(in: 1000...4999, using: &rng),
                          reason: String(String.UnicodeScalarView(scalars)))
    }
}

private func encode(_ message: SshRelayMessage) throws -> [UInt8] {
    switch message {
    case .connectSuccessSid(let sid): return try Format.ConnectSuccessSid.encode(sid: sid)
    case .reconnectSuccessAck(let ack): return Format.ReconnectAck.encode(ack: ack)
    case .ack(let ack): return Format.Ack.encode(ack: ack)
    case .data(let payload): return try Format.Data.encode(payload)
    case .longClose(let code, let reason):
        var buffer = [UInt8](repeating: 0, count: Format.LongClose.minMessageLength + reason.utf8.count)
        try Format.LongClose.encode(into: &buffer, code: code, reason: reason)
        return buffer
    case .unknown(let tag): return [UInt8(tag >> 8), UInt8(tag & 0xFF)]
    }
}

@Suite("SshRelayFormat decode genérico")
struct RelayGenericDecodeTests {
    @Test(arguments: [
        ([0, 1, 0, 0, 0, 3, 0x53, 0x69, 0x64], SshRelayMessage.connectSuccessSid("Sid")),
        ([0, 2, 0, 0, 0, 0, 0, 0, 0, 42], .reconnectSuccessAck(42)),
        ([0, 4, 0, 0, 0, 1, 0x44], .data([0x44])),
        ([0, 7, 0, 0, 0, 0, 0, 0, 0, 77], .ack(77)),
        ([0, 10, 0, 0, 0x0F, 0xA1, 0, 0, 0, 4, 0x46, 0x61, 0x69, 0x6C], .longClose(code: 4001, reason: "Fail")),
        ([0, 3, 0xAA], .unknown(tag: 3)),
        ([0, 9], .unknown(tag: 9)),
        ([0xFF, 0xFF, 1, 2, 3], .unknown(tag: 0xFFFF)),
    ] as [([UInt8], SshRelayMessage)])
    func decodesCSharpVectors(bytes: [UInt8], expected: SshRelayMessage) throws {
        #expect(try Format.decode(bytes).message == expected)
    }

    @Test func closeCodeView() {
        #expect(SshRelayMessage.longClose(code: 4033, reason: "").closeCode == .notAuthorized)
        #expect(SshRelayMessage.ack(1).closeCode == nil)
    }
}

@Suite("SshRelayFormat roundtrip y fuzz")
struct RelayFuzzTests {
    @Test func roundtripRandomMessages() throws {
        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<500 {
            let message = try randomMessage(using: &rng)
            let bytes = try encode(message)
            let (decoded, read) = try Format.decode(bytes)
            #expect(decoded == message)
            #expect(read == bytes.count)

            // Con basura al final, se consume exactamente el mensaje.
            let padded = bytes + randomBytes(Int.random(in: 1...16, using: &rng), using: &rng)
            let (decodedPadded, readPadded) = try Format.decode(padded)
            #expect(decodedPadded == message)
            #expect(readPadded == bytes.count)
        }
    }

    @Test func everyStrictPrefixIsTruncated() throws {
        var rng = SplitMix64(state: 0xBADC0DE)
        for _ in 0..<50 {
            let message = try randomMessage(using: &rng)
            let bytes = try encode(message)
            for length in 0..<bytes.count {
                #expect(throws: SshRelayFormatError.self) {
                    try Format.decode(Array(bytes.prefix(length)))
                }
            }
        }
    }

    @Test func randomBytesNeverCrash() {
        var rng = SplitMix64(state: 42)
        for _ in 0..<20_000 {
            var bytes = randomBytes(Int.random(in: 0...32, using: &rng), using: &rng)
            // Sesgar hacia tags conocidos y longitudes pequeñas para cubrir más ramas.
            if bytes.count >= 2, Bool.random(using: &rng) {
                bytes[0] = 0
                bytes[1] = [1, 2, 4, 7, 10].randomElement(using: &rng)!
            }
            if bytes.count >= 6, Bool.random(using: &rng) {
                bytes[2] = 0; bytes[3] = 0; bytes[4] = 0
            }
            do {
                let (_, read) = try Format.decode(bytes)
                #expect(read >= 2 && read <= bytes.count)
            } catch {
                // Cualquier fallo debe ser un error tipado, nunca un trap.
            }
        }
    }
}
