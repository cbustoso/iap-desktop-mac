// GH-89 (specs/azure/azure-bastion-research.md §1, §9.1): login Entra ID para
// la app nativa. Authorization code + PKCE (S256) con loopback es el flujo
// principal; device code es el fallback manual. Public client: no hay
// secreto, y el repo no lleva client ID (GH-80): llega por entorno o por la UI.
import Foundation
import OSLog

/// Configuración del app registration (multitenant, public client).
public struct EntraClientConfig: Sendable, Equatable {
    /// Entorno con el client ID (Application ID, GUID) del app registration.
    public static let environmentKey = "AZURE_OAUTH_CLIENT_ID"
    /// Override guardado desde la UI (por perfil, en la suite `oauth`).
    public static let defaultsKey = "azure.oauth.clientID"
    /// Audiencia `management.core.windows.net` con doble barra a propósito:
    /// es la que manda el Azure CLI y la que Bastion acepta seguro (§1.3).
    public static let armScope = "https://management.core.windows.net//user_impersonation"
    public static let signInScopes = ["openid", "profile", "offline_access", armScope]
    public static let refreshScopes = [armScope, "offline_access"]
    public static let defaultAuthority = URL(string: "https://login.microsoftonline.com")!

    public let clientID: String
    public var authority: URL
    /// Tenant del login inicial: `organizations` (cuentas de trabajo/escuela).
    public var signInTenant: String
    /// Host de la redirect URI loopback. `localhost` es lo que admite el
    /// portal (registrar `http://localhost/authorize`; el puerto se ignora en
    /// el match). `127.0.0.1` exige editar el manifiesto (§1.1).
    public var redirectHost: String

    public init(
        clientID: String, authority: URL = Self.defaultAuthority, signInTenant: String = "organizations",
        redirectHost: String = "localhost"
    ) throws {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else { throw EntraAuthError.clientNotConfigured }
        guard Self.isValidTenant(signInTenant) else { throw EntraAuthError.invalidTenant }
        self.clientID = trimmed.lowercased()
        self.authority = authority
        self.signInTenant = signInTenant
        self.redirectHost = redirectHost
    }

    /// Client ID efectivo: override de la UI (`defaults`) y, si no, entorno.
    /// Sin ninguno → `clientNotConfigured` (nunca se llama a la red).
    public static func resolve(
        defaults: UserDefaults? = nil, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EntraClientConfig {
        let candidates = [defaults?.string(forKey: defaultsKey), environment[environmentKey]]
        guard let value = candidates.compactMap({ $0 }).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { throw EntraAuthError.clientNotConfigured }
        return try EntraClientConfig(clientID: value)
    }

    /// `organizations`, `common`, un GUID o un dominio verificado: va dentro
    /// del path, así que nada de `/`, `?` ni `..`.
    public static func isValidTenant(_ tenant: String) -> Bool {
        (1...256).contains(tenant.count) && !tenant.contains("..")
            && tenant.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == ".") }
    }

    func endpoint(tenant: String, _ name: String) -> URL {
        authority.appendingPathComponent(tenant).appendingPathComponent("oauth2/v2.0/\(name)")
    }

    /// Admin consent para tenants con el consentimiento de usuario deshabilitado.
    public func adminConsentURL(tenant: String) -> URL {
        var components = URLComponents(url: authority.appendingPathComponent(tenant).appendingPathComponent("adminconsent"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        return components.url!
    }
}

/// Respuesta de `/token` de Entra. Redactada en cualquier representación.
public struct EntraTokenResponse: Sendable, Codable, Equatable {
    public var accessToken: String
    public var expiresIn: Int
    public var refreshToken: String?
    public var idToken: String?
    public var scope: String?

    public init(accessToken: String, expiresIn: Int, refreshToken: String? = nil, idToken: String? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case scope
    }

    /// Identidad del `id_token` (sin verificar firma: llega directo de Entra
    /// por TLS en el canje, igual que en `TokenResponse.identity()`).
    public func identity() throws -> EntraIdentity {
        guard let idToken, let claims = JWTClaims.decode(idToken),
              let tenantID = claims["tid"] as? String, let objectID = claims["oid"] as? String,
              EntraClientConfig.isValidTenant(tenantID), !objectID.isEmpty
        else { throw EntraAuthError.missingIdentity }
        let username = (claims["preferred_username"] ?? claims["upn"] ?? claims["email"]) as? String
        return EntraIdentity(homeTenantID: tenantID, objectID: objectID, username: username ?? "")
    }
}

extension EntraTokenResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "EntraTokenResponse(expiresIn: \(expiresIn), scope: \(scope ?? "nil"), tokens: <redacted>)" }
    public var debugDescription: String { description }
}

/// Cuenta Entra: `tid` (tenant de origen) + `oid`. El UPN puede cambiar y en
/// B2B lleva `#EXT#`, así que la clave estable es `<tid>:<oid>` (§1.5).
public struct EntraIdentity: Sendable, Equatable, Codable, CustomStringConvertible {
    public let homeTenantID: String
    public let objectID: String
    public let username: String

    public var keychainAccount: String { "\(homeTenantID):\(objectID)" }
    public var description: String {
        "EntraIdentity(tenant: \(homeTenantID), account: \(ProfileDescriptor.redactedAccount(azureUsername: username)))"
    }
}

/// Lo que muestra la UI del fallback "Iniciar sesión con código".
public struct DeviceCodePrompt: Sendable, Equatable {
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    /// Texto localizado que devuelve Entra (no contiene secretos).
    public let message: String?
}

public enum EntraAuthError: Error, Sendable, Equatable {
    case clientNotConfigured
    case invalidTenant
    case userCancelled
    case loopbackTimeout
    /// `state` del callback no coincide (CSRF o callback ajeno).
    case stateMismatch
    /// Refresh token inválido/expirado/revocado (`invalid_grant`): hay que
    /// iniciar sesión de nuevo.
    case requiresSignIn
    /// MFA o reautenticación exigida (`interaction_required`, AADSTS50076…):
    /// login interactivo con `login_hint` en ese tenant.
    case interactionRequired(tenantID: String?)
    /// La app no tiene consentimiento en el tenant: URL de admin consent.
    case consentRequired(adminConsentURL: URL?)
    /// Conditional Access bloquea el acceso (típico con device code, AADSTS53003).
    case blockedByConditionalAccess
    /// El app registration no permite public client flows (device code).
    case publicClientFlowsDisabled
    case deviceCodeDeclined
    case deviceCodeExpired
    /// La sesión cambió (login/logout) mientras había un refresh en vuelo.
    case sessionChanged
    case missingRefreshToken
    case missingIdentity
    case malformedResponse
    case network(String)
    /// Error OAuth no clasificado: código y `AADSTS…` (sin la descripción, que
    /// puede llevar trace/correlation IDs).
    case tokenEndpoint(status: Int, error: String?, codes: [Int])
}

/// Lo que `AzureCredentialFacade` necesita para refrescar (inyectable).
public protocol EntraTokenRefreshing: Sendable {
    func refresh(_ refreshToken: String, tenantID: String) async throws -> EntraTokenResponse
}

public struct EntraAuthorizer: EntraTokenRefreshing {
    public typealias BrowserOpener = @Sendable (URL) async throws -> Void
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public let config: EntraClientConfig
    private let session: URLSession
    private let loopback: LoopbackReceiver
    private let openBrowser: BrowserOpener
    private let sleep: Sleeper
    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login.entra")
    static let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"

    /// - Parameter openBrowser: abre la URL de autorización en el navegador
    ///   del sistema (en la App, `NSWorkspace.open`); el código vuelve por el loopback.
    public init(
        config: EntraClientConfig,
        session: URLSession = .shared,
        loopback: LoopbackReceiver = LoopbackReceiver(),
        openBrowser: @escaping BrowserOpener,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.config = config
        self.session = session
        self.loopback = loopback
        self.openBrowser = openBrowser
        self.sleep = sleep
    }

    // MARK: - Authorization code + PKCE (principal)

    /// Login interactivo. `tenant` = `organizations` salvo reautenticación en
    /// un tenant concreto (guest/B2B, MFA), con `loginHint` = UPN conocido.
    public func signInInteractive(
        tenant: String? = nil, loginHint: String? = nil, timeoutSeconds: UInt64 = 120
    ) async throws -> EntraTokenResponse {
        let tenant = tenant ?? config.signInTenant
        guard EntraClientConfig.isValidTenant(tenant) else { throw EntraAuthError.invalidTenant }
        let bound = try await loopback.start()
        let redirectURI = Self.redirect(bound, host: config.redirectHost)
        let pkce = PKCE()
        let state = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded()
        let url = authorizeURL(tenant: tenant, redirectURI: redirectURI, pkce: pkce, state: state, loginHint: loginHint)
        Self.log.notice("entra sign-in start flow=pkce tenant=\(tenant, privacy: .public)")

        // Secuencial a propósito: si el callback llega antes de esperar, el
        // receptor lo guarda. La espera no atiende cancelación por sí sola:
        // cancelar la Task cierra el listener y la falla al momento.
        let callback: URL
        let loopback = self.loopback
        do {
            try await openBrowser(url)
            callback = try await withTaskCancellationHandler {
                try await loopback.waitForCallbackURL(timeoutSeconds: timeoutSeconds)
            } onCancel: {
                Task { await loopback.cancel() }
            }
        } catch let error as AuthError {
            await loopback.cancel()
            throw error == .loopbackTimeout ? EntraAuthError.loopbackTimeout : EntraAuthError.userCancelled
        } catch {
            await loopback.cancel()
            throw error
        }
        let code = try Self.code(from: callback, expectedState: state)
        return try await post(tenant: tenant, endpoint: "token", grant: "authorization_code", fields: [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": pkce.verifier,
            "scope": EntraClientConfig.signInScopes.joined(separator: " "),
        ])
    }

    func authorizeURL(tenant: String, redirectURI: URL, pkce: PKCE, state: String, loginHint: String?) -> URL {
        var components = URLComponents(url: config.endpoint(tenant: tenant, "authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: EntraClientConfig.signInScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    /// `http://127.0.0.1:<p>/authorize` → mismo puerto y path con `host`.
    static func redirect(_ bound: URL, host: String) -> URL {
        var components = URLComponents(url: bound, resolvingAgainstBaseURL: false)!
        components.host = host
        return components.url!
    }

    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard values["error"] == nil else { throw EntraAuthError.userCancelled }
        guard values["state"] == expectedState else { throw EntraAuthError.stateMismatch }
        guard let code = values["code"], !code.isEmpty else { throw EntraAuthError.malformedResponse }
        return code
    }

    // MARK: - Device code (fallback)

    /// Device code (RFC 8628). Muchos tenants lo bloquean por Conditional
    /// Access (recomendación de Microsoft): se reporta como
    /// `blockedByConditionalAccess` para que la UI lo explique.
    public func signInWithDeviceCode(
        tenant: String? = nil, present: @Sendable (DeviceCodePrompt) async -> Void
    ) async throws -> EntraTokenResponse {
        let tenant = tenant ?? config.signInTenant
        guard EntraClientConfig.isValidTenant(tenant) else { throw EntraAuthError.invalidTenant }
        Self.log.notice("entra sign-in start flow=device_code tenant=\(tenant, privacy: .public)")
        let (data, _) = try await send(tenant: tenant, endpoint: "devicecode", grant: "device_code", fields: [
            "client_id": config.clientID,
            "scope": EntraClientConfig.signInScopes.joined(separator: " "),
        ])
        guard let device = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data),
              let verificationURI = URL(string: device.verificationURI)
        else { throw EntraAuthError.malformedResponse }
        await present(DeviceCodePrompt(
            userCode: device.userCode, verificationURI: verificationURI, expiresIn: device.expiresIn, message: device.message))

        var interval = max(1, device.interval ?? 5)
        var waited = 0
        while waited < device.expiresIn {
            do {
                try await sleep(.seconds(interval))
            } catch {
                throw EntraAuthError.userCancelled
            }
            waited += interval
            do {
                return try await post(tenant: tenant, endpoint: "token", grant: "device_code", fields: [
                    "grant_type": Self.deviceCodeGrant,
                    "client_id": config.clientID,
                    "device_code": device.deviceCode,
                ])
            } catch let pending as DevicePolling {
                if pending == .slowDown { interval += 5 }
            }
        }
        throw EntraAuthError.deviceCodeExpired
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval, message
        }
    }

    /// Estados "sigue esperando" del polling: nunca salen de este tipo.
    private enum DevicePolling: Error { case pending, slowDown }

    // MARK: - Refresh por tenant

    /// Access token ARM para `tenantID` con el refresh token de la cuenta
    /// (cross-tenant como MSAL/`az`). Entra suele rotar el refresh token: el
    /// llamador debe guardar `refreshToken` si viene.
    public func refresh(_ refreshToken: String, tenantID: String) async throws -> EntraTokenResponse {
        guard EntraClientConfig.isValidTenant(tenantID) else { throw EntraAuthError.invalidTenant }
        return try await post(tenant: tenantID, endpoint: "token", grant: "refresh_token", fields: [
            "grant_type": "refresh_token",
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "scope": EntraClientConfig.refreshScopes.joined(separator: " "),
        ])
    }

    // MARK: - Transporte

    private func post(tenant: String, endpoint: String, grant: String, fields: [String: String]) async throws -> EntraTokenResponse {
        let (data, _) = try await send(tenant: tenant, endpoint: endpoint, grant: grant, fields: fields)
        guard let response = try? JSONDecoder().decode(EntraTokenResponse.self, from: data), !response.accessToken.isEmpty else {
            throw EntraAuthError.malformedResponse
        }
        return response
    }

    private func send(tenant: String, endpoint: String, grant: String, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: config.endpoint(tenant: tenant, endpoint))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EntraAuthError.network(TokenClient.describe(networkError: error))
        }
        guard let http = response as? HTTPURLResponse else { throw EntraAuthError.malformedResponse }
        guard http.statusCode == 200 else {
            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            if grant == "device_code", endpoint == "token" {
                switch body?.error {
                case "authorization_pending": throw DevicePolling.pending
                case "slow_down": throw DevicePolling.slowDown
                case "authorization_declined": throw EntraAuthError.deviceCodeDeclined
                case "expired_token", "code_expired", "bad_verification_code": throw EntraAuthError.deviceCodeExpired
                default: break
                }
            }
            let error = Self.classify(status: http.statusCode, body: body, tenant: tenant, config: config)
            Self.log.error("""
                entra token response grant=\(grant, privacy: .public) tenant=\(tenant, privacy: .public) \
                http=\(http.statusCode, privacy: .public) oauth_error=\(body?.error ?? "-", privacy: .public) \
                codes=\((body?.errorCodes ?? []).map(String.init).joined(separator: ","), privacy: .public)
                """)
            throw error
        }
        return (data, http)
    }

    struct OAuthErrorBody: Decodable {
        let error: String?
        let errorCodes: [Int]?
        let suberror: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorCodes = "error_codes"
            case suberror
        }
    }

    /// Clasificación por `error` y `error_codes` (AADSTS) de Entra (§9.1).
    static func classify(status: Int, body: OAuthErrorBody?, tenant: String, config: EntraClientConfig) -> EntraAuthError {
        let codes = Set(body?.errorCodes ?? [])
        let error = body?.error
        if !codes.isDisjoint(with: [53000, 53001, 53002, 53003, 530032]) { return .blockedByConditionalAccess }
        if codes.contains(7_000_218) { return .publicClientFlowsDisabled }
        if error == "consent_required" || !codes.isDisjoint(with: [65001, 65004, 90094]) {
            return .consentRequired(adminConsentURL: EntraClientConfig.isValidTenant(tenant) ? config.adminConsentURL(tenant: tenant) : nil)
        }
        if error == "interaction_required" || !codes.isDisjoint(with: [50076, 50079, 50158, 50072, 50074]) {
            return .interactionRequired(tenantID: tenant == config.signInTenant ? nil : tenant)
        }
        if error == "invalid_grant" { return .requiresSignIn }
        return .tokenEndpoint(status: status, error: error, codes: (body?.errorCodes ?? []))
    }
}

/// Claims del payload de un JWT, sin verificar firma.
enum JWTClaims {
    static func decode(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
