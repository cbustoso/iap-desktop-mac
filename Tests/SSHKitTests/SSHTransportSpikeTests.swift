// T-SSH-1 (CBU-37): conecta, autentica con publickey y abre shell contra un
// servidor SSH mock en loopback (sin sshd del sistema ni red).
// CBU-41: `SSHTransport.openShell` (spike) está deprecada; estos tests de
// regresión (incluidos los tipos de llave P-384/P-521/Ed25519) usan ya
// `SshSession`, con la misma forma de uso que tenía el spike.
import CryptoKit
import Foundation
import NIOSSH
import Testing
@testable import SSHKit

/// Lee `output` hasta que el texto acumulado contenga `marker`.
private func read(until marker: String, from iterator: inout AsyncStream<String>.Iterator) async -> String {
    var text = ""
    while !text.contains(marker), let chunk = await iterator.next() {
        text += chunk
    }
    return text
}

/// Shell sobre `SshSession` con la forma de uso del antiguo `SSHShellSession`.
private struct SessionShell: Sendable {
    let session: SshSession
    let channel: SshChannel

    var output: AsyncStream<String> { channel.output }
    func write(_ data: Data) async throws { try await channel.write(data) }
    func resize(_ size: SSHTerminalSize) async throws { try await channel.resize(size) }
    func close() async { await session.close() }
}

private func openShell(
    host: String, port: Int, username: String, privateKey: NIOSSHPrivateKey,
    hostKeyPolicy: SSHHostKeyPolicy, terminal: SSHTerminalSize = .init()
) async throws -> SessionShell {
    let session = try await SshSession.connect(
        host: host, port: port, username: username, privateKey: privateKey, hostKeyPolicy: hostKeyPolicy)
    do {
        return SessionShell(session: session, channel: try await session.openShell(terminal: terminal))
    } catch {
        await session.close()
        throw error
    }
}

@Suite("SSH transport spike", .serialized, .timeLimit(.minutes(1)))
struct SSHTransportSpikeTests {
    @Test func connectAuthenticateAndRunShell() async throws {
        let userKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: userKey.publicKey)

        let session = try await openShell(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: userKey, hostKeyPolicy: .pinned(server.hostKey),
            terminal: SSHTerminalSize(columns: 120, rows: 40))
        var output = session.output.makeAsyncIterator()

        #expect(await read(until: "mock-shell$ ", from: &output).hasSuffix("mock-shell$ "))
        try await session.write(Data("hola ñandú\n".utf8))
        #expect(await read(until: "mock-shell$ ", from: &output).contains("echo:hola ñandú"))

        try await session.resize(SSHTerminalSize(columns: 100, rows: 30))
        try await session.write(Data("exit\n".utf8))
        _ = await read(until: "\u{0}never", from: &output)  // hasta EOF: el shell cerró

        let observed = server.observed
        #expect(observed.ptyTerm == "xterm-256color")
        #expect(observed.ptySize?.columns == 120)
        #expect(observed.ptySize?.rows == 40)
        #expect(observed.shellRequested)
        #expect(observed.resizes == [100])

        await session.close()
        await server.shutdown()
    }

    @Test(arguments: ["p384", "p521", "ed25519"])
    func otherSupportedUserKeyTypes(kind: String) async throws {
        let userKey: NIOSSHPrivateKey = switch kind {
        case "p384": NIOSSHPrivateKey(p384Key: P384.Signing.PrivateKey())
        case "p521": NIOSSHPrivateKey(p521Key: P521.Signing.PrivateKey())
        default: NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        }
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: userKey.publicKey)
        let session = try await openShell(
            host: "127.0.0.1", port: server.port, username: "spike",
            privateKey: userKey, hostKeyPolicy: .pinned(server.hostKey))
        var output = session.output.makeAsyncIterator()
        #expect(await read(until: "mock-shell$ ", from: &output).hasSuffix("mock-shell$ "))
        await session.close()
        await server.shutdown()
    }

    @Test func unauthorizedKeyFailsAuthentication() async throws {
        let authorized = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let intruder = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: authorized.publicKey)
        await #expect(throws: SSHTransportError.authenticationFailed) {
            let session = try await openShell(
                host: "127.0.0.1", port: server.port, username: "spike",
                privateKey: intruder, hostKeyPolicy: .pinned(server.hostKey))
            await session.close()
        }
        #expect(!server.observed.shellRequested)
        await server.shutdown()
    }

    @Test func unexpectedHostKeyIsRejected() async throws {
        let userKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: userKey.publicKey)
        let otherHost = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey()).publicKey
        await #expect(throws: SSHTransportError.hostKeyRejected) {
            let session = try await openShell(
                host: "127.0.0.1", port: server.port, username: "spike",
                privateKey: userKey, hostKeyPolicy: .pinned(otherHost))
            await session.close()
        }
        #expect(!server.observed.shellRequested)
        await server.shutdown()
    }
}
