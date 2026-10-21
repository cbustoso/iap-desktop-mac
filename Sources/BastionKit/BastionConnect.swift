import Foundation
import NIOSSH
import RDPBridge
import SSHKit

// GH-94: Connect sobre Azure Bastion reutilizando las piezas existentes.
// SSH/SFTP: `SshSession` in-process sobre `BastionTunnelStream` (sin puerto
// local); SFTP abre su canal sobre esa misma sesión (`SftpChannel.open(over:)`).
// RDP: `BastionLocalForwarder` como `RdpTunnel` del `RdpFallbackConnector`, que
// ya escribe el `.rdp` (`full address:s:127.0.0.1:{puerto}`) y abre Windows App.

/// Sesión SSH hacia una VM detrás de un Bastion. La credencial es local de la
/// VM (usuario + llave), no de Entra (REQ-AZ-6).
public struct BastionSshConnector: Sendable, CustomStringConvertible {
    private let factory: BastionTunnelFactory
    private let hostKeyPolicy: SSHHostKeyPolicy
    private let timeout: Duration

    public init(factory: BastionTunnelFactory, hostKeyPolicy: SSHHostKeyPolicy, timeout: Duration = .seconds(30)) {
        self.factory = factory
        self.hostKeyPolicy = hostKeyPolicy
        self.timeout = timeout
    }

    public var description: String { "BastionSshConnector(\(factory.target), key: <redacted>)" }

    public func connect(username: String, privateKey: NIOSSHPrivateKey) async throws -> SshSession {
        let stream = try await factory.openStream()
        do {
            return try await SshSession.connect(
                over: stream, username: username, privateKey: privateKey,
                hostKeyPolicy: hostKeyPolicy, timeout: timeout)
        } catch {
            await stream.close()
            // Si el túnel cayó durante el handshake, su motivo es el útil.
            if let tunnelError = await stream.terminationError { throw tunnelError }
            throw error
        }
    }
}

/// `RdpTunnelOpening` sobre Bastion: el `RdpFallbackConnector` existente
/// genera el `.rdp` y lanza Windows App contra el puerto del forwarder.
///
/// `RdpTarget` se reutiliza tal cual; quien cablea el perfil Azure decide cómo
/// mapearlo (p. ej. suscripción / grupo de recursos / VM) en `resolve`.
public struct BastionRdpTunnels: RdpTunnelOpening {
    public typealias Resolve = @Sendable (_ target: RdpTarget, _ remotePort: UInt16) async throws -> BastionTunnelFactory

    private let resolve: Resolve
    private let probe: Bool

    /// `probe`: abre y cierra un túnel antes de lanzar Windows App para fallar
    /// pronto con un error tipado (SKU, RBAC, VM apagada), como el probe de IAP.
    public init(probe: Bool = true, resolve: @escaping Resolve) {
        self.resolve = resolve
        self.probe = probe
    }

    public func openTunnel(to target: RdpTarget, remotePort: UInt16) async throws -> any RdpTunnel {
        let factory = try await resolve(target, remotePort)
        if probe {
            let stream = try await factory.openStream()
            await stream.close()
            if let failure = await stream.terminationError { throw failure }
        }
        return try await BastionLocalForwarder.start(factory: factory)
    }
}
