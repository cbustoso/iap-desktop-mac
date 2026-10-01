import Foundation

/// Persistent storage for non-sensitive settings in an isolated defaults suite.
public struct UserDefaultsSettingsStore: SettingsStore, Sendable {
    public let suiteName: String

    public init(suiteName: String) {
        precondition(!suiteName.isEmpty, "The UserDefaults suite name must not be empty")
        self.suiteName = suiteName
    }

    public func read<Value: Codable & Equatable & Sendable>(
        key: String,
        displayName: String?,
        description: String?,
        category: String?,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)?
    ) throws -> Setting<Value> {
        guard let data = defaults.data(forKey: key) else {
            return Setting(
                key: key,
                displayName: displayName,
                description: description,
                category: category,
                defaultValue: defaultValue,
                validate: validate
            )
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
        if setting.isSpecified {
            defaults.set(try setting.encodedValue(), forKey: setting.key)
        } else {
            defaults.removeObject(forKey: setting.key)
        }
    }

    public func clear() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create UserDefaults suite \(suiteName)")
        }
        return defaults
    }
}
