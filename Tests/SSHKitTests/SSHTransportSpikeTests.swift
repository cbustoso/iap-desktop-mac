// T-SSH-1 (CBU-37): el spike conecta, autentica con publickey y abre shell
// contra un servidor SSH mock en loopback (sin sshd del sistema ni red).
import CryptoKit
import Foundation
import NIOSSH
import Testing
@testable import SSHKit

/// Lee `output` hasta que el texto acumulado contenga `marker`.
private func read(until marker: String, from iterator: inout AsyncStream<Data>.Iterator) async -> String {
    var text = ""
    while !text.contains(marker), let chunk = await iterator.next() {
        text += String(decoding: chunk, as: UTF8.self)
    }
    return text
}

@Suite("SSH transport spike", .serialized, .timeLimit(.minutes(1)))
struct SSHTransportSpikeTests {
    @Test func connectAuthenticateAndRunShell() async throws {
        let userKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let server = try await MockSSHServer.start(username: "spike", authorizedKey: userKey.publicKey)

        let session = try await SSHTransport.openShell(
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
        let session = try await SSHTransport.openShell(
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
            let session = try await SSHTransport.openShell(
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
            let session = try await SSHTransport.openShell(
                host: "127.0.0.1", port: server.port, username: "spike",
                privateKey: userKey, hostKeyPolicy: .pinned(otherHost))
            await session.close()
        }
        #expect(!server.observed.shellRequested)
        await server.shutdown()
    }
}
