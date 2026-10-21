// GH-95 (F3): contrato e2e pre-release contra `FakeBastionServer` con
// `/api/tokens` por el wire (URLSession → HTTP local) y WebSocket real:
// POSTs encadenados, un único DELETE, renovación con backoff, desconexión
// tipada y proxy CONNECT (T-AZ-11, T-AZ-12, A3.1, A3.2).
import AuthKit
import CFNetwork
import Foundation
import Testing
import TunnelKit
@testable import BastionKit

/// Lee del stream hasta juntar `count` bytes (o fin).
private func collect(_ stream: BastionTunnelStream, count: Int) async -> Data {
    var data = Data()
    for await chunk in stream.incoming() {
        data.append(chunk)
        if data.count >= count { break }
    }
    return data
}

private func echoes(_ stream: BastionTunnelStream, _ text: String = "ping") async throws -> Bool {
    let payload = Data(text.utf8)
    async let echoed = collect(stream, count: payload.count)
    try await stream.send(payload)
    return await echoed == payload
}

private func retry(_ sleeps: SleepRecorder, attempts: Int = 3) -> BastionRetryPolicy {
    BastionRetryPolicy(maxAttempts: attempts, initialDelay: .milliseconds(500), maxDelay: .seconds(8), sleep: sleeps.sleeper)
}

@Suite("Contrato e2e Bastion (GH-95)", .serialized, .timeLimit(.minutes(1)))
struct BastionContractTests {
    @Test func chainedPostsAndASingleDeleteOnLastClose() async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init()))
        defer { Task { await server.shutdown() } }
        let factory = makeContractFactory(server: server, retry: .none)

        let first = try await factory.openStream()
        async let second = factory.openStream()
        async let third = factory.openStream()
        let others = try await [second, third]
        for stream in [first] + others { #expect(try await echoes(stream)) }

        let posts = server.posts
        #expect(posts.map(\.status) == [200, 200, 200])
        #expect(posts[0].formKeys == ["resourceId", "protocol", "workloadHostPort", "aztoken"])
        #expect(posts[0].nodeIDHeader == nil)
        #expect(posts[1].form["token"] == "auth-1-secret")
        #expect(posts[2].form["token"] == "auth-2-secret")
        #expect(posts.dropFirst().allSatisfy { $0.nodeIDHeader == "node-fake-1" })
        #expect(server.observed.upgradeStatuses == [101, 101, 101])

        await first.close()
        await others[0].close()
        #expect(server.deletes.isEmpty)
        await others[1].close()
        #expect(await eventually { server.deletes.count == 1 })
        #expect(server.deletes.first?.status == 200)
        #expect(server.deletes.first?.nodeIDHeader == "node-fake-1")
        #expect(server.liveSessions == 0)
        await factory.shutdown()  // ya no queda sesión: no repite el DELETE
        #expect(server.deletes.count == 1)
        #expect(server.observed.violations.isEmpty)
    }

    @Test func renewalRetriesTheChainedPostWithBackoffAndAFreshArmToken() async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init()))
        defer { Task { await server.shutdown() } }
        let sleeps = SleepRecorder()
        let invalidations = Counter()
        let telemetry = TelemetryRecorder()
        let factory = makeContractFactory(
            server: server, retry: retry(sleeps), telemetry: telemetry.telemetry, invalidations: invalidations)

        let first = try await factory.openStream()
        server.injectPostFailures([401, 503])
        let second = try await factory.openStream()
        #expect(try await echoes(second))

        let posts = server.posts
        #expect(posts.map(\.status) == [200, 401, 503, 200])
        // Cada reintento encadena la misma sesión previa (token + X-Node-Id).
        #expect(posts.dropFirst().allSatisfy { $0.form["token"] == "auth-1-secret" && $0.nodeIDHeader == "node-fake-1" })
        #expect(sleeps.delays == [.milliseconds(500), .seconds(1)])
        #expect(invalidations.value == 1)  // solo el 401 descarta el token ARM
        #expect(telemetry.events.contains(.armTokenInvalidated))
        #expect(telemetry.events.contains(.sessionOpened(attempt: 3, chained: true)))

        await first.close()
        await second.close()
        #expect(await eventually { server.deletes.count == 1 })
        #expect(server.liveSessions == 0)
        #expect(server.observed.violations.isEmpty)
    }

    @Test func exhaustedRenewalIsTypedAndLeavesNothingBehind() async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init(postFailures: [503, 503, 503])))
        defer { Task { await server.shutdown() } }
        let sleeps = SleepRecorder()
        let factory = makeContractFactory(server: server, retry: retry(sleeps))

        await #expect(throws: BastionTunnelError.retriesExhausted(
            attempts: 3, last: .serviceError(status: 503, message: "injected 503"))) {
            try await factory.openStream()
        }
        #expect(server.posts.count == 3)
        #expect(sleeps.delays == [.milliseconds(500), .seconds(1)])
        #expect(server.deletes.isEmpty)  // nunca hubo sesión
        #expect(await factory.activeSessions == 0)
        #expect(BastionTunnelError.retriesExhausted(attempts: 3, last: .timeout).userMessage.hasPrefix("Tras 3 intentos"))
    }

    @Test(arguments: [404, 400])
    func nonRetryableErrorsFailFastWithoutBackoff(status: Int) async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init(postFailures: [status])))
        defer { Task { await server.shutdown() } }
        let sleeps = SleepRecorder()
        let factory = makeContractFactory(server: server, retry: retry(sleeps))

        await #expect(throws: BastionTunnelError.self) { try await factory.openStream() }
        #expect(server.posts.count == 1)
        #expect(sleeps.delays.isEmpty)
    }

    @Test func expiredChainedSessionFallsBackToAFreshOne() async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init()))
        defer { Task { await server.shutdown() } }
        let telemetry = TelemetryRecorder()
        let factory = makeContractFactory(server: server, retry: retry(SleepRecorder()), telemetry: telemetry.telemetry)

        let first = try await factory.openStream()
        server.expireSessions()  // el Bastion olvidó auth-1
        let second = try await factory.openStream()
        #expect(try await echoes(second))

        let posts = server.posts
        #expect(posts.map(\.status) == [200, 404, 200])
        #expect(posts[1].form["token"] == "auth-1-secret")
        #expect(posts[2].form["token"] == nil)  // sin encadenar
        #expect(posts[2].nodeIDHeader == nil)
        #expect(telemetry.events.contains(.chainDropped))

        await first.close()
        await second.close()
        #expect(await eventually { server.deletes.count == 1 })
        #expect(server.deletes.first?.status == 200)  // DELETE de la sesión nueva, no de la caducada
    }

    @Test func rejectedWebSocketUpgradeRenewsWithAChainedPost() async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init(rejectedUpgrades: 1)))
        defer { Task { await server.shutdown() } }
        let sleeps = SleepRecorder()
        let factory = makeContractFactory(server: server, retry: retry(sleeps))

        let stream = try await factory.openStream()
        #expect(try await echoes(stream))
        #expect(server.observed.upgradeStatuses == [401, 101])
        let posts = server.posts
        #expect(posts.count == 2)
        #expect(posts[1].form["token"] == "auth-1-secret")
        #expect(posts[1].nodeIDHeader == "node-fake-1")
        #expect(sleeps.delays == [.milliseconds(500)])
        // El websocketToken es de un solo uso: el segundo upgrade usa el nuevo.
        #expect(server.observed.handshakes.map(\.path) == ["/webtunnelv2/ws-1-secret", "/webtunnelv2/ws-2-secret"])

        await stream.close()
        #expect(await eventually { server.deletes.count == 1 })
        #expect(server.liveSessions == 0)
        #expect(server.observed.violations.isEmpty)
    }

    @Test func droppedWebSocketEndsTheStreamWithATypedErrorAndReleasesTheSession() async throws {
        let server = try await FakeBastionServer.start(.init(behavior: .dropAfter(.milliseconds(200)), contract: .init()))
        defer { Task { await server.shutdown() } }
        let telemetry = TelemetryRecorder()
        let factory = makeContractFactory(server: server, retry: .none, telemetry: telemetry.telemetry)

        let stream = try await factory.openStream()
        for await _ in stream.incoming() {}  // termina: no se queda colgado
        #expect(await stream.terminationError == .connectionLost(code: nil))
        await #expect(throws: BastionTunnelError.connectionLost(code: nil)) { try await stream.send(Data("x".utf8)) }
        #expect(telemetry.events.contains(.tunnelLost(.connectionLost(code: nil))))
        #expect(await eventually { server.deletes.count == 1 })

        // La siguiente conexión funciona con una sesión nueva.
        let next = try await factory.openStream()
        #expect(server.posts.count == 2)
        await next.close()
    }

    @Test func halfOpenLinkIsDetectedByThePing() async throws {
        let server = try await FakeBastionServer.start(.init(behavior: .ignorePings, contract: .init()))
        defer { Task { await server.shutdown() } }
        let factory = makeContractFactory(server: server, retry: .none, pingInterval: .milliseconds(150))

        let stream = try await factory.openStream()
        #expect(try await echoes(stream))
        for await _ in stream.incoming() {}
        #expect(await stream.terminationError == .connectionLost(code: 1006))
        #expect(await eventually { server.deletes.count == 1 })
    }

    @Test func telemetryNeverCarriesTokens() async throws {
        let server = try await FakeBastionServer.start(.init(contract: .init(postFailures: [401], rejectedUpgrades: 1)))
        defer { Task { await server.shutdown() } }
        let telemetry = TelemetryRecorder()
        let factory = makeContractFactory(server: server, retry: retry(SleepRecorder()), telemetry: telemetry.telemetry)
        let stream = try await factory.openStream()
        await stream.close()
        #expect(await eventually { server.deletes.count == 1 })

        #expect(telemetry.events.count >= 6)
        for event in telemetry.events {
            let text = String(describing: event)
            #expect(!text.contains("secret"))
            #expect(!text.contains(Secrets.armToken))
        }
    }
}

// MARK: - Proxy CONNECT (T-AZ-11)

@Suite("Proxy CONNECT Bastion (GH-95)", .serialized, .timeLimit(.minutes(1)))
struct BastionProxyTests {
    private func transport(proxyPort: Int) throws -> NIOBastionWebSocketTransport {
        var sockets = NIOBastionWebSocketTransport(
            proxy: ProxyConfig(host: "127.0.0.1", port: proxyPort), connectTimeout: .seconds(5))
        sockets.tlsConfiguration = try TestTLS.clientConfiguration()
        return sockets
    }

    @Test func webSocketTraversesTheProxyWithConnectToTheBastionHost() async throws {
        let server = try await FakeBastionServer.start(.init(behavior: .echo, tls: true))
        defer { Task { await server.shutdown() } }
        let proxy = try await FakeConnectProxy.start(.tunnel(toPort: server.port))
        defer { Task { await proxy.shutdown() } }
        let factory = BastionTunnelFactory(
            target: target, sessions: BastionSessionClient(transport: StubBastionHTTP()),
            sockets: try transport(proxyPort: proxy.port), retry: .none, telemetry: .disabled,
            armToken: { Secrets.armToken })

        let stream = try await factory.openStream()
        #expect(try await echoes(stream, "a través del proxy"))
        // Sondeo + túnel: ambos CONNECT van al host del Bastion, nunca a 127.0.0.1.
        #expect(proxy.connectRequests == Array(repeating: "CONNECT bst-123.bastion.azure.com:443 HTTP/1.1", count: 2))
        let handshake = try #require(server.observed.handshakes.first)
        #expect(handshake.path == "/webtunnelv2/\(Secrets.websocketToken(1))")
        #expect(handshake.origin == "https://bst-123.bastion.azure.com")
        await stream.close()
        #expect(await stream.terminationError == nil)
    }

    @Test(arguments: [403, 407])
    func proxyThatRefusesTheConnectIsTypedAndNotRetried(status: Int) async throws {
        let proxy = try await FakeConnectProxy.start(.deny(status: status))
        defer { Task { await proxy.shutdown() } }
        let http = StubBastionHTTP()
        let sleeps = SleepRecorder()
        let factory = BastionTunnelFactory(
            target: target, sessions: BastionSessionClient(transport: http),
            sockets: try transport(proxyPort: proxy.port), retry: retry(sleeps), telemetry: .disabled,
            armToken: { Secrets.armToken })

        await #expect(throws: BastionTunnelError.proxyBlocked) { try await factory.openStream() }
        #expect(proxy.connectRequests.count == 1)  // solo el sondeo: rechazo inmediato, sin esperar al timeout
        #expect(sleeps.delays.isEmpty)
        #expect(await eventually { http.deleteRequests.count == 1 })  // la sesión pedida no queda viva
    }

    @Test func networkConfigurationTakesTheSystemProxyForTheBastionHost() async {
        let seen = LockedBox<[String]>([])
        let resolver = ProxyResolver(
            systemSettings: { [:] },
            proxiesForURL: { url, _ in
                seen.withValue { $0.append(url.absoluteString) }
                return [[
                    kCFProxyTypeKey as AnyHashable: kCFProxyTypeHTTPS as String,
                    kCFProxyHostNameKey as AnyHashable: "proxy.corp.example",
                    kCFProxyPortNumberKey as AnyHashable: 8443,
                ]]
            })
        let network = await BastionNetworkConfiguration.resolve(for: target, resolver: resolver)
        #expect(network.proxy == ProxyConfig(host: "proxy.corp.example", port: 8443))
        #expect(network.sockets.proxy == network.proxy)
        #expect(seen.value == ["https://bst-123.bastion.azure.com"])

        let direct = await BastionNetworkConfiguration.resolve(
            for: target, resolver: ProxyResolver(systemSettings: { nil }))
        #expect(direct.proxy == nil)
        #expect(direct.sockets.proxy == nil)
    }
}

// MARK: - Política de reintentos y errores

struct BastionRetryPolicyTests {
    @Test func backoffDoublesUpToTheCap() {
        let policy = BastionRetryPolicy(maxAttempts: 6, initialDelay: .milliseconds(500), maxDelay: .seconds(3))
        #expect((1...5).map(policy.delay(after:)) == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3), .seconds(3)])
        #expect(BastionRetryPolicy(maxAttempts: 0).maxAttempts == 1)
    }

    @Test(arguments: [
        (BastionTunnelError.unauthorized(message: nil), true),
        (.serviceError(status: 503, message: nil), true),
        (.serviceError(status: 429, message: nil), true),
        (.serviceError(status: 400, message: nil), false),
        (.timeout, true),
        (.network("x"), true),
        (.connectionLost(code: nil), true),
        (.targetNotFound, false),
        (.proxyBlocked, false),
        (.protocolChanged(status: 200), false),
        (.nativeClientDisabled(sku: "Basic"), false),
    ])
    func retryableClassification(error: BastionTunnelError, retryable: Bool) {
        #expect(error.isRetryable == retryable)
    }

    @Test func kindHasNoServerText() {
        let error = BastionTunnelError.retriesExhausted(attempts: 2, last: .unauthorized(message: "user@corp.example"))
        #expect(error.kind == "retriesExhausted(2, unauthorized)")
        #expect(error.tunnelError == .connectionDenied)
    }
}
