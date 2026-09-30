/// Errores tipados de `CredentialResolver` (paridad parcial `SshError` de
/// `specs/ssh/design.md`, acotado al alcance de autorización — REQ-SSH-3, REQ-SSH-7).
public enum SshAuthError: Error, Equatable, Sendable {
    /// OS Login está habilitado en la instancia/proyecto pero la política
    /// (`KeyAuthorizationMethods`) no lo permite (paridad
    /// `InvalidOperationException("{instance} requires OS Login")`).
    case osLoginRequired

    /// La instancia exige llave de seguridad hardware (`enable-oslogin-sk`), no
    /// soportado en v1 (paridad `OsLoginSkNotSupportedException`).
    case osLoginSecurityKeyNotSupported

    /// OS Login está deshabilitado y la política no permite ningún método de
    /// metadata (ni instancia ni proyecto) — paridad
    /// `ArgumentException("Unrecognized authorization method")`.
    case metadataAuthorizationNotAllowed

    /// El nombre de usuario preferido no cumple el patrón POSIX
    /// (paridad `LinuxUser.IsValidUsername`).
    case invalidUsername(String)
}
