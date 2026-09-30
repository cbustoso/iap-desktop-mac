import Foundation

/// Refreshes an expired access token while keeping all credential access in
/// `CredentialFacade`.
public struct TokenRefresher: Sendable {
    public init() {}

    public func refreshedAccessToken(
        facade: CredentialFacade,
        client: TokenClient,
        skewSeconds: TimeInterval = 60
    ) async throws -> String {
        do {
            return try await facade.validAccessToken()
        } catch AuthError.tokenExpired {
            guard let offline = await facade.currentOffline else {
                throw AuthError.tokenExpired
            }
            let response = try await client.refresh(refreshToken: offline.refreshToken)
            try await facade.storeRefreshed(
                accessToken: response.accessToken,
                expiresIn: max(0, TimeInterval(response.expiresIn) - max(0, skewSeconds)),
                refreshToken: response.refreshToken)
            return response.accessToken
        }
    }
}
