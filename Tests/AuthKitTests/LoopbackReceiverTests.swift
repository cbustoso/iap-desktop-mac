// AuthKit T-AUTH-2 tests: receptor loopback real (127.0.0.1 efímero).
import Testing
import Foundation
import Network
@testable import AuthKit

@Suite("LoopbackReceiver")
struct LoopbackReceiverTests {
    @Test func redirectURIShape() async throws {
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        #expect(uri.scheme == "http")
        #expect(uri.host == "127.0.0.1")
        #expect((uri.port ?? 0) > 0)
        #expect(uri.path == "/authorize")
        await receiver.cancel()
    }

    @Test func roundTripCode() async throws {
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        var components = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: "auth-code-123")]
        let task = Task { try await receiver.waitForCode(timeoutSeconds: 10) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("close this window") == true)
        #expect(try await task.value == "auth-code-123")
    }

    @Test func callbackURLCarriesFullQuery() async throws {
        // Camino loopback de la carrera: URL completa (code+state) aunque la
        // sesión del navegador no intercepte.
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        var components = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "auth-code-123"),
            URLQueryItem(name: "state", value: "state-abc"),
        ]
        let task = Task { try await receiver.waitForCallbackURL(timeoutSeconds: 10) }
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let callback = try await task.value
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first(where: { $0.name == "code" })?.value == "auth-code-123")
        #expect(items?.first(where: { $0.name == "state" })?.value == "state-abc")
        #expect(callback.host == "127.0.0.1")
        await receiver.cancel()
    }

    @Test func earlyCallbackURLIsKept() async throws {
        // Como codeBeforeWaitIsKept pero para la URL completa.
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        var components = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: "early-code")]
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let callback = try await receiver.waitForCallbackURL(timeoutSeconds: 10)
        #expect(callback.absoluteString.contains("code=early-code"))
        await receiver.cancel()
    }

    @Test func codeBeforeWaitIsKept() async throws {
        // Review #2: el código que llega antes de waitForCode no se descarta.
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        var components = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "code", value: "early-code")]
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await receiver.waitForCode(timeoutSeconds: 10) == "early-code")
        await receiver.cancel()
    }

    @Test func errorFailsFast() async throws {
        // Review #9: ?error=access_denied falla al momento, no espera 120 s.
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        var components = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "error", value: "access_denied")]
        let task = Task { try await receiver.waitForCode(timeoutSeconds: 30) }
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        await #expect(throws: AuthError.userCancelled) { try await task.value }
        await receiver.cancel()
    }

    @Test func timeoutThrows() async throws {
        let receiver = LoopbackReceiver()
        _ = try await receiver.start()
        await #expect(throws: AuthError.loopbackTimeout) {
            try await receiver.waitForCode(timeoutSeconds: 1)
        }
        await receiver.cancel()
    }

    @Test func earlyErrorFailsFast() async throws {
        // Re-review R2 #3: un ?error= que llega antes de waitForCode no se
        // pierde (antes esperaba el timeout completo).
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        var components = URLComponents(url: uri, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "error", value: "access_denied")]
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        await #expect(throws: AuthError.userCancelled) {
            try await receiver.waitForCode(timeoutSeconds: 3)
        }
        await receiver.cancel()
    }

    @Test func abruptCloseDoesNotHang() async throws {
        // Re-review R2 #4: conexión rota a mitad de headers → sin bucle de
        // Tasks; la espera expira con normalidad.
        let receiver = LoopbackReceiver()
        let uri = try await receiver.start()
        let port = NWEndpoint.Port(rawValue: UInt16(uri.port ?? 0))!
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data("GET /incomplete".utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        await #expect(throws: AuthError.loopbackTimeout) {
            try await receiver.waitForCode(timeoutSeconds: 2)
        }
        await receiver.cancel()
    }

    @Test func extractCodeParsing() {
        #expect(LoopbackReceiver.extractCode(from: "/authorize/?code=abc&scope=x") == "abc")
        #expect(LoopbackReceiver.extractCode(from: "/authorize?code=abc") == "abc")
        #expect(LoopbackReceiver.extractCode(from: "/authorize/?scope=x") == nil)
        #expect(LoopbackReceiver.extractCode(from: "/other/?code=abc") == nil)
    }
}
