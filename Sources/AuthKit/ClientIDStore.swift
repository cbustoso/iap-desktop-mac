import Foundation

/// Persists and resolves the OAuth client ID without exposing it in descriptions.
///
/// Orden de resolución (CBU-36):
/// 1. `UserDefaults` (`oauth.clientID`): override manual guardado desde la UI.
/// 2. `Info.plist` (`OAuthClientID`): solo para builds de distribución que lo
///    inyecten al empaquetar. En el repo es el placeholder `__OAUTH_CLIENT_ID__`
///    (GH-80: nada de secretos embebidos), que cuenta como ausente.
/// 3. Entorno `GOOGLE_OAUTH_CLIENT_ID` / `GOOGLE_OAUTH_CLIENT_SECRET`.
/// 4. Fichero local `~/.config/iap-desktop-mac/secrets.env` (solo si existe;
///    ver `LocalSecretsFile`). El entorno manda sobre el fichero, clave a clave.
public struct ClientIDStore: CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultsKey = "oauth.clientID"
    public static let infoPlistKey = "OAuthClientID"
    public static let secretPlistKey = "OAuthClientSecret"
    public static let environmentKey = "GOOGLE_OAUTH_CLIENT_ID"
    public static let secretEnvironmentKey = "GOOGLE_OAUTH_CLIENT_SECRET"
    /// Valor de `Info.plist` que significa "sin client ID embebido".
    public static let bundlePlaceholder = "__OAUTH_CLIENT_ID__"
    /// Valor de `Info.plist` que significa "sin client secret embebido".
    public static let secretBundlePlaceholder = "__OAUTH_CLIENT_SECRET__"
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
        environment: [String: String] = ProcessInfo.processInfo.environment,
        secretsFile: URL? = LocalSecretsFile.defaultURL()
    ) {
        self.defaults = defaults
        self.bundledClientID = bundledClientID
        self.bundledClientSecret = bundledClientSecret
        let fileValues = secretsFile.map(LocalSecretsFile.load(from:)) ?? [:]
        self.environment = fileValues.merging(environment) { _, explicit in explicit }
    }

    @discardableResult
    public func save(_ value: String) throws -> String {
        let clientID = try Self.validated(value)
        defaults.set(clientID, forKey: Self.defaultsKey)
        return clientID
    }

    /// Client ID efectivo. Lanza `userCancelled` si no hay ninguno (la UI
    /// muestra entonces `missingConfigurationMessage`) y
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

    /// Client secret efectivo (Info.plist → entorno → fichero local). Sin
    /// UserDefaults: no se edita desde la UI. `nil` si ausente.
    public func clientSecret() -> String? {
        if let bundled = bundledClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundled.isEmpty, bundled != Self.secretBundlePlaceholder {
            return bundled
        }
        if let environmentValue = environment[Self.secretEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentValue.isEmpty {
            return environmentValue
        }
        return nil
    }

    /// Qué falta para poder iniciar sesión (`nil` = nada). Los clients
    /// "Desktop app" de Google exigen también el secret en `/token`.
    public var missingConfiguration: MissingClientConfiguration? {
        guard isConfigured else { return .clientID }
        return clientSecret() == nil ? .clientSecret : nil
    }

    /// Mensaje accionable (sin valores) para cuando falta configuración.
    public static let missingConfigurationMessage = """
        No OAuth client configured. Set GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET \
        in the environment or in ~/.config/iap-desktop-mac/secrets.env (see docs/usage.md), \
        or paste a Desktop app client ID in the Sign In window.
        """

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

/// Pieza de configuración OAuth que falta (GH-80).
public enum MissingClientConfiguration: Sendable, Equatable {
    case clientID
    case clientSecret

    public var message: String {
        switch self {
        case .clientID: return ClientIDStore.missingConfigurationMessage
        case .clientSecret:
            return "OAuth client secret missing: set GOOGLE_OAUTH_CLIENT_SECRET in the environment "
                + "or in ~/.config/iap-desktop-mac/secrets.env (see docs/usage.md)."
        }
    }
}
