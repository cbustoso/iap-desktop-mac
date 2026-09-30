/// Decide el método de autorización de la llave SSH efímera (OS Login vs metadata
/// keys) y resuelve el usuario POSIX, sin conocer el transporte SSH ni la generación
/// de llaves (esas responsabilidades viven en `Sources/SSHKit/Transport/` y
/// `Sources/SSHKit/Keys/`, fuera de este módulo).
///
/// Paridad `PlatformCredentialFactory.CreateCredentialAsync` (C#) — ver
/// `specs/ssh/requirements.md` REQ-SSH-3 y `specs/ssh/design.md` §"Llaves efímeras y
/// autorización".
public actor CredentialResolver {
    private let osLoginStatusProvider: any InstanceOsLoginStatusProviding
    private let osLoginAuthorizer: any OsLoginKeyAuthorizing
    private let metadataPublisher: any MetadataKeyPublishing

    public init(
        osLoginStatusProvider: any InstanceOsLoginStatusProviding,
        osLoginAuthorizer: any OsLoginKeyAuthorizing,
        metadataPublisher: any MetadataKeyPublishing
    ) {
        self.osLoginStatusProvider = osLoginStatusProvider
        self.osLoginAuthorizer = osLoginAuthorizer
        self.metadataPublisher = metadataPublisher
    }

    /// Resuelve la credencial para conectar a `instance`.
    ///
    /// - Parameters:
    ///   - publicKeyOpenSSH: llave pública efímera ya generada (formato OpenSSH).
    ///   - preferredUsername: usuario POSIX preferido por el usuario, si alguno.
    ///   - emailHint: email de la sesión activa, usado para derivar un usuario si no
    ///     hay `preferredUsername` (paridad `LinuxUser.SuggestUsername`).
    ///   - allowedMethods: métodos permitidos por política (default: todos).
    public func resolve(
        project: String,
        zone: String,
        instance: String,
        publicKeyOpenSSH: String,
        preferredUsername: String?,
        emailHint: String,
        allowedMethods: KeyAuthorizationMethods = .all
    ) async throws -> AuthorizedCredential {
        let status = try await osLoginStatusProvider.osLoginStatus(
            project: project, zone: zone, instance: instance)

        if status.isEnabled {
            //
            // OS Login habilitado: se ignora cualquier llave de metadata.
            //
            guard allowedMethods.contains(.osLogin) else {
                throw SshAuthError.osLoginRequired
            }
            guard !status.requiresSecurityKey else {
                throw SshAuthError.osLoginSecurityKeyNotSupported
            }
            return try await osLoginAuthorizer.authorizeViaOsLogin(
                project: project, zone: zone, instance: instance,
                publicKeyOpenSSH: publicKeyOpenSSH)
        }

        guard allowedMethods.contains(.instanceMetadata) || allowedMethods.contains(.projectMetadata) else {
            throw SshAuthError.metadataAuthorizationNotAllowed
        }

        let username = try Self.resolveUsername(preferred: preferredUsername, emailHint: emailHint)

        return try await metadataPublisher.publishToMetadata(
            project: project, zone: zone, instance: instance,
            publicKeyOpenSSH: publicKeyOpenSSH, username: username,
            allowedMethods: allowedMethods)
    }

    static func resolveUsername(preferred: String?, emailHint: String) throws -> String {
        if let preferred, !preferred.isEmpty {
            guard PosixUsername.isValid(preferred) else {
                throw SshAuthError.invalidUsername(preferred)
            }
            return preferred
        }
        return PosixUsername.suggest(fromEmail: emailHint)
    }
}
