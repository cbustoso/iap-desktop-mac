/// Estado de OS Login para una instancia, resuelto a partir de la metadata de
/// proyecto/instancia (paridad `ComputeMetadata.{IsOsLoginEnabled,
/// IsOsLoginWithSecurityKeyEnabled}`, flags `enable-oslogin` / `enable-oslogin-sk`).
public struct InstanceOsLoginStatus: Sendable, Equatable {
    /// `true` si la instancia o el proyecto exigen OS Login (`enable-oslogin`).
    public let isEnabled: Bool

    /// `true` si además exige llave de seguridad hardware (`enable-oslogin-sk`),
    /// no soportado en v1 (paridad `OsLoginSkNotSupportedException`).
    public let requiresSecurityKey: Bool

    public init(isEnabled: Bool, requiresSecurityKey: Bool) {
        self.isEnabled = isEnabled
        self.requiresSecurityKey = requiresSecurityKey
    }
}

/// Puerto hacia el proveedor de metadata de Compute Engine (implementado por
/// `GCPClient` en una capa superior; `SSHKit/Auth` no depende de `GCPClient`
/// directamente para no acoplar módulos en desarrollo paralelo — ver
/// `specs/ssh/design.md`).
public protocol InstanceOsLoginStatusProviding: Sendable {
    func osLoginStatus(project: String, zone: String, instance: String) async throws -> InstanceOsLoginStatus
}
