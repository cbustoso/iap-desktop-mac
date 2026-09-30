import Foundation

/// Persists and resolves the OAuth client ID without exposing it in descriptions.
public struct ClientIDStore: CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultsKey = "oauth.clientID"
    public static let environmentKey = "GOOGLE_OAUTH_CLIENT_ID"

    private let defaults: UserDefaults
    private let environment: [String: String]

    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
    }

    @discardableResult
    public func save(_ value: String) throws -> String {
        let clientID = try Self.validated(value)
        defaults.set(clientID, forKey: Self.defaultsKey)
        return clientID
    }

    public func resolve() throws -> String {
        if let stored = defaults.string(forKey: Self.defaultsKey) {
            return try Self.validated(stored)
        }
        if let environmentValue = environment[Self.environmentKey] {
            return try Self.validated(environmentValue)
        }
        throw AuthError.userCancelled
    }

    public var description: String {
        "ClientIDStore(key: \(Self.defaultsKey), value: <redacted>)"
    }

    public var debugDescription: String { description }

    private static func validated(_ value: String) throws -> String {
        let clientID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw AuthError.invalidResponse
        }
        return clientID
    }
}
