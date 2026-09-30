import Foundation

/// Respuesta de `POST /token` (`oauth2.googleapis.com/token`).
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

/// Cliente de intercambio de códigos y refresh (`URLSession` inyectable para tests).
public struct TokenClient: Sendable {
    public var tokenURL: URL
    public var clientID: String
    private var session: URLSession

    public init(
        tokenURL: URL = URL(string: "https://oauth2.googleapis.com/token")!,
        clientID: String,
        session: URLSession = .shared
    ) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.session = session
    }

    /// Intercambia `code` (+ verificador PKCE) por tokens.
    public func exchange(code: String, verifier: String, redirectURI: URL) async throws -> TokenResponse {
        try await post(fields: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier,
        ])
    }

    /// Refresca el access token.
    public func refresh(refreshToken: String) async throws -> TokenResponse {
        try await post(fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    private func post(fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }
}
