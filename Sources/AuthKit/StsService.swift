// GH-67 (T-AUTH-7): cliente de Security Token Service (sts.googleapis.com) para
// Workforce Identity Federation: canje del código del auth portal, refresh,
// IntrospectToken y revocación. Tokens, códigos y secret nunca van a logs ni a
// `description` (REQ-AUTH-6).
import Foundation
import OSLog

/// Respuesta de `POST /v1/introspect` (RFC 7662). Redactada en texto.
public struct StsIntrospection: Sendable, Equatable, Decodable, CustomStringConvertible {
    public let active: Bool
    public let clientID: String?
    /// `principal://iam.googleapis.com/locations/…/workforcePools/…/subject/…`
    public let username: String?
    public let scope: String?
    public let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case active
        case clientID = "client_id"
        case username
        case scope
        case exp
    }

    public init(active: Bool, clientID: String?, username: String?, scope: String?, expiresAt: Date?) {
        self.active = active
        self.clientID = clientID
        self.username = username
        self.scope = scope
        self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        clientID = try container.decodeIfPresent(String.self, forKey: .clientID)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        // `exp` llega como número o como string según el servidor.
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: .exp) {
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .exp), let seconds = Double(text) {
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else {
            expiresAt = nil
        }
    }

    /// Identidad workforce del token, o `nil` si no es un `principal://` workforce.
    public var workforceIdentity: WorkforceIdentity? { username.flatMap(WorkforceIdentity.init(principal:)) }

    public var description: String {
        "StsIntrospection(active: \(active), identity: \(workforceIdentity.map(\.description) ?? "nil"))"
    }
}

/// Cliente STS. `URLSession` inyectable para tests.
public struct StsClient: Sendable {
    public var tokenURL: URL
    public var introspectURL: URL
    public var revokeURL: URL
    public var clientID: String
    /// Secreto del cliente OAuth de workforce: va en `Authorization: Basic`,
    /// nunca en el cuerpo ni en logs.
    public var clientSecret: String?
    private var session: URLSession

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    public init(
        tokenURL: URL = URL(string: "https://sts.googleapis.com/v1/oauthtoken")!,
        introspectURL: URL = URL(string: "https://sts.googleapis.com/v1/introspect")!,
        revokeURL: URL = URL(string: "https://sts.googleapis.com/v1/revoke")!,
        clientID: String,
        clientSecret: String? = nil,
        session: URLSession = .shared
    ) {
        self.tokenURL = tokenURL
        self.introspectURL = introspectURL
        self.revokeURL = revokeURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
    }

    /// Canjea el código del auth portal (+ verificador PKCE).
    public func exchange(code: String, verifier: String, redirectURI: URL) async throws -> TokenResponse {
        try await token(fields: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier,
        ], operation: "exchange")
    }

    public func refresh(refreshToken: String) async throws -> TokenResponse {
        try await token(fields: ["grant_type": "refresh_token", "refresh_token": refreshToken], operation: "refresh")
    }

    /// IntrospectToken: valida el token y devuelve quién es (`principal://`).
    public func introspect(token: String) async throws -> StsIntrospection {
        let data = try await post(introspectURL, fields: ["token": token], operation: "introspect")
        do {
            return try JSONDecoder().decode(StsIntrospection.self, from: data)
        } catch {
            throw AuthError.malformedTokenResponse
        }
    }

    /// Best-effort, como `RevokeClient`.
    @discardableResult
    public func revoke(token: String) async -> Bool {
        (try? await post(revokeURL, fields: ["token": token], operation: "revoke")) != nil
    }

    // MARK: - Transporte

    private func token(fields: [String: String], operation: String) async throws -> TokenResponse {
        let data = try await post(tokenURL, fields: fields, operation: operation)
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.malformedTokenResponse
        }
    }

    /// Autenticación del cliente (RFC 6749 §2.3.1): con secret, Basic; sin
    /// él, `client_id` en el cuerpo. Nunca ambos.
    func request(_ url: URL, fields: [String: String]) -> URLRequest {
        var body = fields
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let clientSecret, !clientSecret.isEmpty {
            let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: FormURLEncoder.allowed) ?? value }
            let credentials = Data("\(encode(clientID)):\(encode(clientSecret))".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        } else {
            body["client_id"] = clientID
        }
        request.httpBody = FormURLEncoder.encode(body)
        return request
    }

    private func post(_ url: URL, fields: [String: String], operation: String) async throws -> Data {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AuthError.clientNotConfigured
        }
        let context = "client=\(LogRedaction.clientIDPrefix(clientID)) secretPresent=\(clientSecret?.isEmpty == false)"
        Self.log.notice("sts request op=\(operation, privacy: .public) \(context, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(url, fields: fields))
        } catch {
            throw AuthError.network(TokenClient.describe(networkError: error))
        }
        guard let http = response as? HTTPURLResponse else { throw AuthError.malformedTokenResponse }
        guard http.statusCode == 200 else {
            let body = try? JSONDecoder().decode(StsErrorBody.self, from: data)
            Self.log.error("""
                sts response op=\(operation, privacy: .public) http=\(http.statusCode, privacy: .public) \
                oauth_error=\(body?.error ?? "-", privacy: .public) \(context, privacy: .public)
                """)
            throw AuthError.tokenEndpoint(status: http.statusCode, error: body?.error, description: body?.errorDescription)
        }
        return data
    }

    private struct StsErrorBody: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}

extension StsClient: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "StsClient(client: \(LogRedaction.clientIDPrefix(clientID)), secret: \(clientSecret == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }
}
