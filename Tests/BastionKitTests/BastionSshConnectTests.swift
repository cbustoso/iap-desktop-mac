// GH-94: Connect SSH/SFTP in-process sobre el túnel (research §9.5 (4)).
import Foundation
import IAPTestSupport
import NIOSSH
import SSHKit
import Testing
@testable import BastionKit

struct BastionSshConnectTests {
    /// research §9.5 (4): SSH in-process, sin puerto local:
    /// SshSession ─ BastionTunnelStream ─ WS ─▶ FakeBastionServer ─ TCP ─▶ MockSSHServer.
    @Test func sshAndSftpRunInProcessOverTheTunnel() async throws {
        let key = NIOSSHPrivateKey(p256Key: .init())
        let ssh = try await MockSSHServer.start(username: "azureuser", authorizedKey: key.publicKey)
        let server = try await FakeBastionServer.start(.forward(port: ssh.port))
        defer {
            Task {
                await server.shutdown()
                await ssh.shutdown()
            }
        }
        let http = StubBastionHTTP()
        let connector = BastionSshConnector(
            factory: makeFactory(server: server, http: http),
            hostKeyPolicy: InMemoryKnownHosts().policy(for: SshTarget(project: "sub-1", zone: "rg-1", instance: "vm-linux")),
            timeout: .seconds(10))

        let session = try await connector.connect(username: "azureuser", privateKey: key)
        _ = try await session.openSubsystem("sftp")
        #expect(await eventually { ssh.observed.subsystems == ["sftp"] })
        await session.close()

        #expect(http.postRequests.count == 1)
        #expect(await eventually { http.deleteRequests.count == 1 })
    }
}
