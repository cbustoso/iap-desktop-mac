import Foundation

/// Respuesta de `POST /token` (`oauth2.googleapis.com/token`).
///
/// Redactada en cualquier representación de texto (REQ-AUTH-6, review #10):
/// un `print`, un log o un fallo de `#expect` nunca muestra tokens.
public struct TokenResponse: Sendable, Codable, Equatable {
    public var accessToken: String
    public var expiresIn: Int
    public var refreshToken: String?
    public var idToken: String?
    public var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case scope
    }
}

extension TokenResponse: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "TokenResponse(expiresIn: \(expiresIn), scope: \(scope ?? "nil"), tokens: <redacted>)"
    }

    public var debugDescription: String { description }
}

/// Formulario `application/x-www-form-urlencoded` con codificación estricta.
///
/// `.urlQueryAllowed` NO vale: deja pasar `+ & = ?` sin escapar y un `+`
/// llega como espacio (review #3). Solo se dejan sin escapar los
/// no reservados de RFC 3986.
enum FormURLEncoder {
    static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ fields: [String: String]) -> Data? {
        fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}

/// Cliente de intercambio de códigos y refresh (`URLSession` inyectable para tests).
public struct TokenClient: Sendable {
    public var tokenURL: URL
    public var clientID: String
    /// Secreto de cliente "Desktop": Google lo acepta y algunas configuraciones
    /// lo exigen en `/token` aunque se use PKCE (review #4). Opcional.
    public var clientSecret: String?
    private var session: URLSession

    public init(
        tokenURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        clientID: String,
        clientSecret: String? = nil,
        session: URLSession = .shared
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.session = session
    }

    /// Intercambia `code` (+ verificador PKCE) por tokens.
    public func exchange(code: String, verifier: String, redirectURI: URL) async throws -> TokenResponse {
        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier,
        ]
        if let secret = clientSecret { fields["client_secret"] = secret }
        return try await post(fields: fields)
    }

    /// Refresca el access token.
    public func refresh(refreshToken: String) async throws -> TokenResponse {
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let secret = clientSecret { fields["client_secret"] = secret }
        return try await post(fields: fields)
    }

    private func post(fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(fields)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.network(String(describing: error))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // Mapeo fino (invalid_grant, consent_required) en T-AUTH-4 (CBU-28).
            throw AuthError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }
}

/// Revocación de tokens (`POST oauth2.googleapis.com/revoke`, REQ-AUTH-3).
///
/// Best-effort por diseño: el logout local siempre se completa aunque la
/// red falle; el servidor expira el token igualmente por tiempo.
public struct RevokeClient: Sendable {
    public var revokeURL: URL
    private var session: URLSession

    public init(
        revokeURL: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
        session: URLSession = .shared
    ) {
        self.revokeURL = revokeURL
        self.session = session
    }

    /// Revoca `token` (access o refresh). No lanza: devuelve `false` si falla.
    @discardableResult
    public func revoke(token: String) async -> Bool {
        var request = URLRequest(url: revokeURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(["token": token])
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
