// T-SSH-4 (CBU-40): StreamingDecoder no rompe secuencias UTF-8 partidas.
import Foundation
import Testing
@testable import SSHKit

@Suite("StreamingDecoder")
struct StreamingDecoderTests {
    private let sample = "a ñ € 😀 日本 ✓ z"

    @Test func everySplitPointDecodesIdentically() {
        let bytes = Array(sample.utf8)
        for cut in 0...bytes.count {
            var decoder = StreamingDecoder()
            let text = decoder.decode(Data(bytes[..<cut])) + decoder.decode(Data(bytes[cut...]))
            #expect(text == sample, "corte en \(cut)")
            #expect(!text.contains("\u{FFFD}"))
            #expect(decoder.pendingByteCount == 0)
        }
    }

    @Test func byteByByteDecodesIdentically() {
        var decoder = StreamingDecoder()
        var text = ""
        for byte in sample.utf8 { text += decoder.decode(Data([byte])) }
        #expect(text == sample)
    }

    @Test func holdsOnlyTheIncompleteTail() {
        var decoder = StreamingDecoder()
        // "a" completo + primeros 2 bytes de "€" (E2 82 AC).
        #expect(decoder.decode(Data([0x61, 0xE2, 0x82])) == "a")
        #expect(decoder.pendingByteCount == 2)
        #expect(decoder.decode(Data([0xAC])) == "€")
    }

    @Test func invalidBytesBecomeReplacementWithoutStalling() {
        var decoder = StreamingDecoder()
        // FF y C0 nunca son válidos; una continuación suelta tampoco.
        #expect(decoder.decode(Data([0x61, 0xFF, 0x62, 0x80, 0x63, 0xC0])) == "a\u{FFFD}b\u{FFFD}c\u{FFFD}")
        #expect(decoder.pendingByteCount == 0)
    }

    @Test func finishFlushesTruncatedSequenceAsReplacement() {
        var decoder = StreamingDecoder()
        #expect(decoder.decode(Data([0x6F, 0x6B, 0xF0, 0x9F])) == "ok")
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(decoder.pendingByteCount == 0)
    }
}
