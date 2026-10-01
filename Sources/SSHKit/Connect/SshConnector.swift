import Foundation
import NIOSSH
import TunnelKit

/// Instancia destino de una sesión SSH vía IAP.
public struct SshTarget: Sendable, Hashable {
    public var project: String
    public var zone: String
    public var instance: String
    public var port: UInt16
    public var interface: String

    public init(project: String, zone: String, instance: String, port: UInt16 = 22, interface: String = "nic0") {
        self.project = project
        self.zone = zone
        self.instance = instance
        self.port = port
        self.interface = interface
    }

    /// Mismo identificador que `InstanceInfo.id` (una pestaña por instancia).
    public var instanceID: String { "\(project)/\(zone)/\(instance)" }

    public var iapEndpoint: IapEndpoint {
        IapEndpoint(project: project, zone: zone, instance: instance, interface: interface, port: port)
    }
}

/// Error de conexión que no viene del túnel ni de la sesión.
public enum SshConnectError: Error, Sendable, Equatable {
    /// La llave efímera no se puede usar con swift-nio-ssh (RSA).
    case unsupportedKeyAlgorithm
}

/// Abre una sesión SSH completa hacia una VM a través de IAP:
///
/// 1. llave efímera (`KeyProvisioner`, ECDSA P-256 por defecto);
/// 2. autorización (`CredentialResolver`: OS Login o metadata) → usuario POSIX;
/// 3. túnel (`RelayStream` sobre el relay IAP, token del provider);
/// 4. `SshSession` sobre ese túnel (handshake + auth publickey).
///
/// El token, la llave y el SID nunca aparecen en descripciones ni errores.
public struct SshConnector: Sendable, CustomStringConvertible {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private let accessToken: AccessTokenProvider
    private let resolver: CredentialResolver
    private let opener: any RelayChannelOpening
    private let endpoint: @Sendable (SshTarget) -> RelayEndpoint
    private let hostKeys: @Sendable (SshTarget) -> SSHHostKeyPolicy
    private let emailHint: @Sendable () async -> String
    private let preferredUsername: String?
    private let keyAlgorithm: SSHKeyAlgorithm
    private let timeout: Duration
    private let metadataAuthRetries: Int
    private let metadataAuthRetryDelay: Duration

    public init(
        accessToken: @escaping AccessTokenProvider,
        resolver: CredentialResolver,
        opener: any RelayChannelOpening = NIOWebSocketTransport(),
        endpoint: @escaping @Sendable (SshTarget) -> RelayEndpoint = { RelayEndpoint($0.iapEndpoint) },
        hostKeys: @escaping @Sendable (SshTarget) -> SSHHostKeyPolicy,
        emailHint: @escaping @Sendable () async -> String,
        preferredUsername: String? = nil,
        keyAlgorithm: SSHKeyAlgorithm = .ecdsaP256,
        timeout: Duration = .seconds(30),
        metadataAuthRetries: Int = 4,
        metadataAuthRetryDelay: Duration = .seconds(3)
    ) {
        self.accessToken = accessToken
        self.resolver = resolver
        self.opener = opener
        self.endpoint = endpoint
        self.hostKeys = hostKeys
        self.emailHint = emailHint
        self.preferredUsername = preferredUsername
        self.keyAlgorithm = keyAlgorithm
        self.timeout = timeout
        self.metadataAuthRetries = max(0, metadataAuthRetries)
        self.metadataAuthRetryDelay = metadataAuthRetryDelay
    }

    public var description: String {
        "SshConnector(key: \(keyAlgorithm.rawValue), token: <redacted>)"
    }

    public func connect(to target: SshTarget) async throws -> SshSession {
        let key = try KeyProvisioner(algorithm: keyAlgorithm)
        guard let sshKey = key.nioSSHPrivateKey else { throw SshConnectError.unsupportedKeyAlgorithm }

        let credential = try await resolver.resolve(
            project: target.project,
            zone: target.zone,
            instance: target.instance,
            publicKeyOpenSSH: key.publicKey.openSSHRepresentation,
            preferredUsername: preferredUsername,
            emailHint: await emailHint())

        // Una llave publicada en metadata tarda unos segundos en llegar a la VM
        // (el guest agent reescribe authorized_keys): reintentos acotados con
        // túnel nuevo. Con OS Login la autorización es inmediata.
        let retries = credential.method == .osLogin ? 0 : metadataAuthRetries
        var attempt = 0
        while true {
            do {
                return try await openSession(
                    to: target, username: credential.username, key: sshKey)
            } catch SSHTransportError.authenticationFailed where attempt < retries {
                attempt += 1
                try await Task.sleep(for: metadataAuthRetryDelay)
            }
        }
    }

    private func openSession(to target: SshTarget, username: String, key: NIOSSHPrivateKey) async throws -> SshSession {
        let stream = try await RelayStream.connect(
            endpoint: endpoint(target), opener: opener, accessToken: accessToken, timeout: timeout)
        do {
            return try await SshSession.connect(
                over: stream,
                username: username,
                privateKey: key,
                hostKeyPolicy: hostKeys(target),
                timeout: timeout)
        } catch {
            await stream.close()
            // Si el túnel cayó durante el handshake, su motivo es el útil.
            if let tunnelError = await stream.terminationError { throw tunnelError }
            throw error
        }
    }
}

extension RelayStream: SshByteStream {}

/// Host keys aceptadas en este proceso (TOFU en memoria). Provisional hasta
/// T-SSH-7 (persistencia + confirmación del usuario): rechaza un cambio de
/// host key dentro de la misma ejecución.
public final class InMemoryKnownHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: NIOSSHPublicKey] = [:]

    public init() {}

    public func policy(for target: SshTarget) -> SSHHostKeyPolicy {
        let id = target.instanceID
        return SSHHostKeyPolicy { [self] key in
            lock.withLock {
                if let known = keys[id] { return known == key }
                keys[id] = key
                return true
            }
        }
    }
}
