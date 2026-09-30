import Foundation
import Security

/// Persistencia de credenciales offline en Keychain (multi-issuer).
/// Servicio: `com.iap-mac.auth[.suffix]`; cuenta: `<issuer-raw>:<email>`.
public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.iap-mac.auth") {
        self.service = service
    }

    private func account(for issuer: OidcIssuer, email: String) -> String {
        "\(issuer.rawValue):\(email)"
    }

    private func baseQuery(issuer: OidcIssuer, email: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: issuer, email: email),
        ]
    }

    /// Guarda (inserta o actualiza) la credencial.
    @discardableResult
    public func save(_ credential: OfflineCredential) throws -> Bool {
        let payload = try JSONEncoder().encode(credential)
        var query = baseQuery(issuer: credential.issuer, email: credential.email)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = payload
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AuthError.keychain(status: addStatus) }
            return true
        }
        guard status == errSecSuccess else { throw AuthError.keychain(status: status) }
        let updateStatus = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: payload] as CFDictionary)
        guard updateStatus == errSecSuccess else { throw AuthError.keychain(status: updateStatus) }
        return true
    }

    /// Carga la credencial o `nil` si no existe.
    public func load(issuer: OidcIssuer, email: String) throws -> OfflineCredential? {
        var query = baseQuery(issuer: issuer, email: email)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthError.keychain(status: status)
        }
        return try JSONDecoder().decode(OfflineCredential.self, from: data)
    }

    /// Lists stored identities without returning secret payloads.
    public func accounts() throws -> [(issuer: OidcIssuer, email: String)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw AuthError.keychain(status: status) }

        let dictionaries: [[String: Any]]
        if let matches = item as? [[String: Any]] {
            dictionaries = matches
        } else if let match = item as? [String: Any] {
            dictionaries = [match]
        } else {
            throw AuthError.keychain(status: errSecInternalError)
        }

        return dictionaries.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            for issuer in [OidcIssuer.gaia, .sts] {
                let prefix = issuer.rawValue + ":"
                if account.hasPrefix(prefix) {
                    let email = String(account.dropFirst(prefix.count))
                    return email.isEmpty ? nil : (issuer, email)
                }
            }
            return nil
        }
    }

    /// Borra la credencial; `true` si existía.
    @discardableResult
    public func delete(issuer: OidcIssuer, email: String) throws -> Bool {
        let status = SecItemDelete(baseQuery(issuer: issuer, email: email) as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw AuthError.keychain(status: status) }
        return true
    }
}
