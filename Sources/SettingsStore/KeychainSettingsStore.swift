import Foundation
import Security

/// Persistent storage for sensitive settings. Values are only ever encoded into
/// Keychain data and are never mirrored into UserDefaults or rendered as strings.
public struct KeychainSettingsStore: SettingsStore, Sendable {
    public let service: String

    public init(service: String = "com.iap-mac.settings.secure") {
        precondition(!service.isEmpty, "The Keychain service must not be empty")
        self.service = service
    }

    public func read<Value: Codable & Equatable & Sendable>(
        key: String,
        displayName: String?,
        description: String?,
        category: String?,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)?
    ) throws -> Setting<Value> {
        var query = baseQuery(key: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return Setting(
                key: key,
                displayName: displayName,
                description: description,
                category: category,
                defaultValue: defaultValue,
                validate: validate
            )
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SettingsError.keychainFailure(status)
        }

        let value: Value
        do {
            value = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw SettingsError.invalidValue(key: key)
        }
        return Setting(
            key: key,
            displayName: displayName,
            description: description,
            category: category,
            value: value,
            defaultValue: defaultValue,
            isSpecified: true,
            validate: validate
        )
    }

    public func write(_ setting: any AnySetting) throws {
        guard setting.isSpecified else {
            try delete(key: setting.key)
            return
        }

        let payload = try setting.encodedValue()
        let query = baseQuery(key: setting.key)
        var insert = query
        insert[kSecValueData as String] = payload
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw SettingsError.keychainFailure(addStatus)
        }

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: payload] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw SettingsError.keychainFailure(updateStatus)
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SettingsError.keychainFailure(status)
        }
    }

    private func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SettingsError.keychainFailure(status)
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
