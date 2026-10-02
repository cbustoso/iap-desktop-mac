import Foundation

// CBU-54: credenciales Windows por instancia, persistidas (la App las guarda
// en Keychain vía `KeychainSettingsStore`, clave `RdpPassword` en ámbito
// instancia). Este coordinador decide "reutilizar o generar" y garantiza que
// regenerar sustituye la anterior; no sabe nada de Keychain ni de GCE.

/// Usuario + contraseña Windows. Nunca imprime la contraseña.
public struct WindowsLogonCredential: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Utilizable para conectar sin regenerar.
    public var isUsable: Bool { !username.isEmpty && !password.isEmpty }

    public var description: String { "WindowsLogonCredential(username: \(username), password: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["username": username, "password": "<redacted>"]) }
}

/// Persistencia por instancia (Keychain en la App; en memoria en tests).
public protocol WindowsCredentialVault: Sendable {
    func load(for instance: InstanceInfo) throws -> WindowsLogonCredential?
    func save(_ credential: WindowsLogonCredential, for instance: InstanceInfo) throws
}

@MainActor
public final class WindowsCredentialCoordinator {
    /// Resetea `username` en la VM y devuelve la contraseña nueva (GCE).
    public typealias Generator = @MainActor (InstanceInfo, String) async throws -> WindowsLogonCredential

    public struct Generated: Equatable, Sendable {
        public let credential: WindowsLogonCredential
        /// `false` si el reset funcionó pero no se pudo guardar (Keychain).
        public let persisted: Bool

        public init(credential: WindowsLogonCredential, persisted: Bool) {
            self.credential = credential
            self.persisted = persisted
        }
    }

    private let vault: any WindowsCredentialVault
    private let generator: Generator

    public init(vault: any WindowsCredentialVault, generator: @escaping Generator) {
        self.vault = vault
        self.generator = generator
    }

    /// Credencial guardada y utilizable, o `nil` (también si no se pudo leer).
    public func stored(for instance: InstanceInfo) -> WindowsLogonCredential? {
        guard let credential = try? vault.load(for: instance), credential.isUsable else { return nil }
        return credential
    }

    /// Genera (o regenera: el agente cambia la contraseña y la anterior deja de
    /// valer) y sustituye la guardada.
    public func generate(for instance: InstanceInfo, username: String) async throws -> Generated {
        let credential = try await generator(instance, username)
        do {
            try vault.save(credential, for: instance)
            return Generated(credential: credential, persisted: true)
        } catch {
            return Generated(credential: credential, persisted: false)
        }
    }
}
