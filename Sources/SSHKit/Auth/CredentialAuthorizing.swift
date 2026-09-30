/// Resultado de autorizar una llave SSH efímera, con el usuario POSIX resuelto y el
/// método usado (paridad `PlatformCredential` — sin exponer material criptográfico:
/// `SSHKit/Auth` no genera ni firma llaves, eso vive en `Sources/SSHKit/Keys/`).
public struct AuthorizedCredential: Sendable, Equatable {
    public let username: String
    public let method: KeyAuthorizationMethods

    public init(username: String, method: KeyAuthorizationMethods) {
        self.username = username
        self.method = method
    }
}

/// Puerto hacia la autorización OS Login (paridad `IOsLoginProfile.AuthorizeKeyAsync`:
/// `ImportSshPublicKey`/`SignPublicKey` cert efímero). Implementado por `GCPClient` en
/// una capa superior.
public protocol OsLoginKeyAuthorizing: Sendable {
    func authorizeViaOsLogin(
        project: String, zone: String, instance: String, publicKeyOpenSSH: String
    ) async throws -> AuthorizedCredential
}

/// Puerto hacia la publicación de la llave en metadata de instancia/proyecto (paridad
/// `ComputeMetadata.AuthorizeKeyAsync`: decide proyecto vs instancia según
/// `allowedMethods`, permisos IAM y `block-project-ssh-keys` — esa decisión vive en la
/// implementación de `GCPClient`, no en `CredentialResolver`).
public protocol MetadataKeyPublishing: Sendable {
    func publishToMetadata(
        project: String, zone: String, instance: String,
        publicKeyOpenSSH: String, username: String,
        allowedMethods: KeyAuthorizationMethods
    ) async throws -> AuthorizedCredential
}
