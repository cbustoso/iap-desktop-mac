/// Métodos permitidos para autorizar una llave SSH efímera.
///
/// Paridad con `KeyAuthorizationMethods` (C#, `PlatformCredentialFactory.cs`): permite
/// a capas superiores restringir por política qué mecanismo puede usar el
/// `CredentialResolver` para autorizar la llave (ver `specs/ssh/requirements.md` REQ-SSH-3).
public struct KeyAuthorizationMethods: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let instanceMetadata = KeyAuthorizationMethods(rawValue: 1 << 0)
    public static let projectMetadata = KeyAuthorizationMethods(rawValue: 1 << 1)
    public static let osLogin = KeyAuthorizationMethods(rawValue: 1 << 2)

    public static let all: KeyAuthorizationMethods = [.instanceMetadata, .projectMetadata, .osLogin]
}
