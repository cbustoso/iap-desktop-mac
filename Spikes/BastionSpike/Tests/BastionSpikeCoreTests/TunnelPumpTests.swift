import Foundation
import Testing
@testable import BastionSpikeCore

@Suite("Bombeo TCP ↔ WS (framing binario crudo)")
struct TunnelPumpTests {
    static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test("TCP → WS: un frame binario por lectura de ≤ 4096 B; eco WS → TCP intacto aunque llegue troceado")
    func echoWithChunking() async {
        let data = Self.payload(10_000)
        let local = FakeLocal(eofAfterReceiving: data.count)
        let socket = FakeSocket(echoChunk: 1_500)
        await local.input.push(data)

        let result = await TunnelPump.run(local: local, socket: socket)

        #expect(socket.sentFrames.map(\.count) == [4_096, 4_096, 1_808])
        #expect(socket.sentFrames.reduce(Data(), +) == data)
        #expect(local.receivedData == data)
        #expect(result.bytesUp == 10_000)
        #expect(result.bytesDown == 10_000)
        #expect(result.reason == .localEOF)
        #expect(socket.closes >= 1)
        #expect(local.isClosed)
    }

    @Test("Sin cabeceras propias: lo que se envía es exactamente lo leído")
    func noFramingAdded() async {
        let local = FakeLocal()
        let socket = FakeSocket()
        await local.input.push(Data("SSH-2.0-OpenSSH_9.8\r\n".utf8))
        await local.input.push(nil)

        _ = await TunnelPump.run(local: local, socket: socket)

        #expect(socket.sentFrames == [Data("SSH-2.0-OpenSSH_9.8\r\n".utf8)])
    }

    @Test("Banner del servidor llega al cliente; cierre del WS cierra el socket local")
    func remoteCloseClosesLocal() async {
        let local = FakeLocal()
        let socket = FakeSocket()
        socket.serverSends(.binary(Data("SSH-2.0-OpenSSH_8.9\r\n".utf8)))
        socket.serverCloses()

        let result = await TunnelPump.run(local: local, socket: socket)

        #expect(local.receivedData == Data("SSH-2.0-OpenSSH_8.9\r\n".utf8))
        #expect(result.reason == .remoteClosed)
        #expect(local.isClosed)
    }

    @Test("Frame de texto del servidor → error y cierre de ambos extremos")
    func textFrameIsAnError() async {
        let local = FakeLocal()
        let socket = FakeSocket()
        socket.serverSends(.text("hola"))

        let result = await TunnelPump.run(local: local, socket: socket)

        guard case .failed(let why) = result.reason else {
            Issue.record("se esperaba .failed, llegó \(result.reason)")
            return
        }
        #expect(why.contains("unexpectedTextFrame"))
        #expect(local.isClosed)
        #expect(socket.closes >= 1)
    }
}
