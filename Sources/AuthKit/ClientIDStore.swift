import Foundation

/// Persists and resolves the OAuth client ID without exposing it in descriptions.
///
/// Orden de resolución (CBU-36):
/// 1. `UserDefaults` (`oauth.clientID`): override manual guardado desde la UI.
/// 2. `Info.plist` (`OAuthClientID`): valor por defecto embebido por el
///    maintainer. El placeholder `__OAUTH_CLIENT_ID__` (o vacío) cuenta como
///    ausente.
/// 3. Entorno `GOOGLE_OAUTH_CLIENT_ID` (desarrollo / `swift run`).
public struct ClientIDStore: CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultsKey = "oauth.clientID"
    public static let infoPlistKey = "OAuthClientID"
    public static let secretPlistKey = "OAuthClientSecret"
    public static let environmentKey = "GOOGLE_OAUTH_CLIENT_ID"
    public static let secretEnvironmentKey = "GOOGLE_OAUTH_CLIENT_SECRET"
    /// Valor de `Info.plist` que significa "sin client ID embebido".
    public static let bundlePlaceholder = "__OAUTH_CLIENT_ID__"
    /// Dónde crear un client ID de tipo "Desktop app".
    public static let cloudConsoleCredentialsURL = URL(
        string: "https://console.cloud.google.com/apis/credentials")!

    private let defaults: UserDefaults
    private let bundledClientID: String?
    private let bundledClientSecret: String?
    private let environment: [String: String]

    public init(
        defaults: UserDefaults = .standard,
        bundledClientID: String? = Bundle.main.object(forInfoDictionaryKey: ClientIDStore.infoPlistKey)
            as? String,
        bundledClientSecret: String? = Bundle.main.object(forInfoDictionaryKey: ClientIDStore.secretPlistKey)
            as? String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.bundledClientID = bundledClientID
        self.bundledClientSecret = bundledClientSecret
        self.environment = environment
    }

    @discardableResult
    public func save(_ value: String) throws -> String {
        let clientID = try Self.validated(value)
        defaults.set(clientID, forKey: Self.defaultsKey)
        return clientID
    }

    /// Client ID efectivo. Lanza `userCancelled` si no hay ninguno y
    /// `invalidResponse` si la fuente que manda tiene un valor mal formado.
    public func resolve() throws -> String {
        if let stored = defaults.string(forKey: Self.defaultsKey) {
            return try Self.validated(stored)
        }
        if let bundled = Self.meaningfulBundleValue(bundledClientID) {
            return try Self.validated(bundled)
        }
        if let environmentValue = environment[Self.environmentKey] {
            return try Self.validated(environmentValue)
        }
        throw AuthError.userCancelled
    }

    /// `true` si `resolve()` devolvería un client ID válido.
    public var isConfigured: Bool { (try? resolve()) != nil }

    /// Client ID para iniciar sesión a partir del campo de la UI.
    ///
    /// Vacío o igual al valor ya resuelto → usa el resuelto sin persistir nada
    /// (no fija el default embebido como override, así una actualización del
    /// `Info.plist` sigue aplicando). Distinto → lo valida y lo guarda como
    /// override manual.
    public func clientIDForSignIn(fieldValue: String) throws -> String {
        let typed = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = try? resolve()
        if typed.isEmpty || typed == resolved {
            return try resolve()
        }
        return try save(typed)
    }

    /// Client secret efectivo (Info.plist → entorno). Sin UserDefaults: el
    /// secret acompaña al bundle, no se edita desde la UI. `nil` si ausente.
    public func clientSecret() -> String? {
        if let bundled = bundledClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundled.isEmpty {
            return bundled
        }
        if let environmentValue = environment[Self.secretEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        return nil
    }

    /// Borra el override manual (vuelve al default embebido / entorno).
    public func clearOverride() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    public var description: String {
        "ClientIDStore(key: \(Self.defaultsKey), value: <redacted>)"
    }

    public var debugDescription: String { description }

    private static func meaningfulBundleValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != bundlePlaceholder
        else { return nil }
        return trimmed
    }

    private static func validated(_ value: String) throws -> String {
        let clientID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw AuthError.invalidResponse
        }
        return clientID
    }
}
