// CBU-44: SSH end-to-end vía túnel IAP, sin red ni GCP reales:
//   SshConnector ─ WebSocket ─▶ MockIAPRelayServer ─ TCP ─▶ MockSSHServer
// La llave efímera la genera KeyProvisioner y la "publican" los stubs del
// resolver en el mock SSH (como metadata / OS Login en GCP).
import Foundation
import IAPTestSupport
import NIOSSH
import Testing
@testable import SSHKit
@testable import TunnelKit

// MARK: - Stubs del resolver

private struct OsLoginStatusStub: InstanceOsLoginStatusProviding {
    let enabled: Bool
    func osLoginStatus(project: String, zone: String, instance: String) async throws -> InstanceOsLoginStatus {
        InstanceOsLoginStatus(isEnabled: enabled, requiresSecurityKey: false)
    }
}

/// "Publica" la llave autorizándola en el MockSSHServer y devuelve el usuario.
/// `propagationDelay` simula el retraso real de metadata hasta la VM.
private struct PublishingStub: OsLoginKeyAuthorizing, MetadataKeyPublishing {
    let server: MockSSHServer
    let osLoginUsername: String
    var propagationDelay: Duration = .zero

    func authorizeViaOsLogin(
        project: String, zone: String, instance: String, publicKeyOpenSSH: String
    ) async throws -> AuthorizedCredential {
        server.authorize(try NIOSSHPublicKey(openSSHPublicKey: publicKeyOpenSSH))
        return AuthorizedCredential(username: osLoginUsername, method: .osLogin)
    }

    func publishToMetadata(
        project: String, zone: String, instance: String,
        publicKeyOpenSSH: String, username: String, allowedMethods: KeyAuthorizationMethods
    ) async throws -> AuthorizedCredential {
        let key = try NIOSSHPublicKey(openSSHPublicKey: publicKeyOpenSSH)
        if propagationDelay == .zero {
            server.authorize(key)
        } else {
            Task { [server, propagationDelay] in
                try? await Task.sleep(for: propagationDelay)
                server.authorize(key)
            }
        }
        return AuthorizedCredential(username: username, method: .instanceMetadata)
    }
}

/// Cuenta peticiones de token y nunca lo expone.
private final class TokenStub: @unchecked Sendable {
    static let secret = "ya29.e2e-secret-token"
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func token() -> String {
        lock.withLock { count += 1 }
        return Self.secret
    }
}

private struct Chain {
    let ssh: MockSSHServer
    let relay: MockIAPRelayServer
    let connector: SshConnector
    let tokens: TokenStub

    func shutdown() async throws {
        try await relay.shutdown()
        await ssh.shutdown()
    }
}

private let target = SshTarget(project: "demo-web", zone: "europe-west1-b", instance: "web-01")

private func makeChain(osLogin: Bool, sshUsername: String, relayClose: MockIAPRelayServer.CloseBehavior? = nil) async throws -> Chain {
    let ssh = try await MockSSHServer.start(username: sshUsername)
    let relay = try await MockIAPRelayServer.start(
        .init(close: relayClose, backend: .init(port: ssh.port)))
    let stub = PublishingStub(server: ssh, osLoginUsername: "ext_ada_example_com")
    let tokens = TokenStub()
    let knownHosts = InMemoryKnownHosts()
    let connector = SshConnector(
        accessToken: { tokens.token() },
        resolver: CredentialResolver(
            osLoginStatusProvider: OsLoginStatusStub(enabled: osLogin),
            osLoginAuthorizer: stub,
            metadataPublisher: stub),
        opener: NIOWebSocketTransport(userAgent: "e2e-test", connectTimeout: .seconds(5)),
        endpoint: { _ in
            RelayEndpoint(
                connectURL: { relay.connectURL },
                reconnectURL: { sid, ack in relay.reconnectURL(sid: sid, ack: ack) })
        },
        hostKeys: { knownHosts.policy(for: $0) },
        emailHint: { "ada@example.com" },
        timeout: .seconds(10))
    return Chain(ssh: ssh, relay: relay, connector: connector, tokens: tokens)
}

private func read(until marker: String, from iterator: inout AsyncStream<String>.Iterator) async -> String {
    var text = ""
    while !text.contains(marker), let chunk = await iterator.next() { text += chunk }
    return text
}

// MARK: - Tests

@Suite("SSH end-to-end vía IAP (mocks)", .serialized, .timeLimit(.minutes(1)))
struct SshOverIapTests {
    @Test func metadataPathShellEchoThroughTunnel() async throws {
        // Sin OS Login: usuario derivado del email (paridad SuggestUsername).
        let chain = try await makeChain(osLogin: false, sshUsername: "ada")
        let session = try await chain.connector.connect(to: target)
        let shell = try await session.openShell(terminal: SSHTerminalSize(columns: 100, rows: 30))
        var output = shell.output.makeAsyncIterator()

        #expect(await read(until: "mock-shell$ ", from: &output).hasSuffix("mock-shell$ "))
        try await shell.write("hola por IAP ñ€😀\n")
        #expect(await read(until: "mock-shell$ ", from: &output).contains("echo:hola por IAP ñ€😀"))
        try await shell.resize(SSHTerminalSize(columns: 120, rows: 40))
        try await shell.write("split\n")
        #expect(await read(until: "mock-shell$ ", from: &output).contains("ñ€😀"))

        #expect(chain.ssh.observed.ptySize?.columns == 100)
        #expect(chain.ssh.observed.resizes == [120])
        #expect(chain.relay.handshakes.first?.hasBearerToken == true)
        #expect(chain.tokens.calls == 1)

        try await shell.write("exit 0\n")
        _ = await shell.drain()
        #expect(shell.exitStatus == 0)
        await session.close()
        try await chain.shutdown()
    }

    @Test func osLoginPathUsesProfileUsername() async throws {
        let chain = try await makeChain(osLogin: true, sshUsername: "ext_ada_example_com")
        let session = try await chain.connector.connect(to: target)
        #expect(session.username == "ext_ada_example_com")
        let shell = try await session.openShell()
        var output = shell.output.makeAsyncIterator()
        #expect(await read(until: "mock-shell$ ", from: &output).hasSuffix("mock-shell$ "))
        await session.close()
        try await chain.shutdown()
    }

    @Test func deniedTunnelIsTypedWithHelp() async throws {
        let chain = try await makeChain(osLogin: false, sshUsername: "ada", relayClose: .init(code: .notAuthorized))
        do {
            _ = try await chain.connector.connect(to: target)
            Issue.record("se esperaba connectionDenied")
        } catch {
            #expect(error as? TunnelError == .connectionDenied)
            let failure = ConnectionFailure(error)
            #expect(failure.helpTopic == .grantAccess)
            #expect(!failure.message.contains(TokenStub.secret))
        }
        try await chain.shutdown()
    }

    @Test func secretsAreRedacted() async throws {
        let chain = try await makeChain(osLogin: false, sshUsername: "ada")
        let session = try await chain.connector.connect(to: target)
        for text in [String(describing: chain.connector), String(describing: session)] {
            #expect(!text.contains(TokenStub.secret))
            #expect(text.contains("<redacted>"))
        }
        // El mock relay solo registra que hubo Bearer, nunca su valor.
        #expect(!String(describing: chain.relay.handshakes).contains(TokenStub.secret))
        let failures = [TunnelError.connectionDenied, .backendNotFound, .relayClosed(code: 4000)]
            .map { ConnectionFailure($0).message }
        #expect(failures.allSatisfy { !$0.contains(TokenStub.secret) })
        await session.close()
        try await chain.shutdown()
    }

    @Test func metadataPropagationDelayIsRetried() async throws {
        let ssh = try await MockSSHServer.start(username: "ada")
        let relay = try await MockIAPRelayServer.start(.init(backend: .init(port: ssh.port)))
        let stub = PublishingStub(server: ssh, osLoginUsername: "x", propagationDelay: .milliseconds(400))
        let connector = SshConnector(
            accessToken: { "t" },
            resolver: CredentialResolver(
                osLoginStatusProvider: OsLoginStatusStub(enabled: false),
                osLoginAuthorizer: stub, metadataPublisher: stub),
            opener: NIOWebSocketTransport(connectTimeout: .seconds(5)),
            endpoint: { _ in
                RelayEndpoint(connectURL: { relay.connectURL }, reconnectURL: { relay.reconnectURL(sid: $0, ack: $1) })
            },
            hostKeys: { _ in .acceptAnyForTesting },
            emailHint: { "ada@example.com" },
            metadataAuthRetries: 4,
            metadataAuthRetryDelay: .milliseconds(200))
        let session = try await connector.connect(to: target)
        #expect(await session.isConnected)
        // Un túnel por intento: al menos uno fallido antes de la propagación.
        #expect(relay.handshakes.count >= 2)
        await session.close()
        try await relay.shutdown()
        await ssh.shutdown()
    }

    @Test func knownHostsRejectChangedHostKey() async throws {
        let knownHosts = InMemoryKnownHosts()
        let first = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let second = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        #expect(knownHosts.policy(for: target).accepts(first))  // TOFU
        #expect(knownHosts.policy(for: target).accepts(first))
        #expect(!knownHosts.policy(for: target).accepts(second))  // cambio → rechazo
        let other = SshTarget(project: "p", zone: "z", instance: "otra")
        #expect(knownHosts.policy(for: other).accepts(second))
    }

    @Test func rsaKeysAreRejectedBeforeTouchingTheNetwork() async throws {
        let chain = try await makeChain(osLogin: false, sshUsername: "ada")
        let rsaConnector = SshConnector(
            accessToken: { chain.tokens.token() },
            resolver: CredentialResolver(
                osLoginStatusProvider: OsLoginStatusStub(enabled: false),
                osLoginAuthorizer: PublishingStub(server: chain.ssh, osLoginUsername: "x"),
                metadataPublisher: PublishingStub(server: chain.ssh, osLoginUsername: "x")),
            hostKeys: { _ in .acceptAnyForTesting },
            emailHint: { "ada@example.com" },
            keyAlgorithm: .rsa3072)
        await #expect(throws: SshConnectError.unsupportedKeyAlgorithm) {
            _ = try await rsaConnector.connect(to: target)
        }
        #expect(chain.tokens.calls == 0)
        try await chain.shutdown()
    }
}
