public enum MergeBehavior: Sendable {
    case overlay
    case policy
}

public struct MergedSettingsStore: SettingsStore, Sendable {
    private let stores: [any SettingsStore]
    public let behavior: MergeBehavior

    public var isPolicyPresent: Bool {
        behavior == .policy && stores.count > 1
    }

    public init(stores: [any SettingsStore], behavior: MergeBehavior) {
        precondition(!stores.isEmpty, "MergedSettingsStore requires at least one store")
        self.stores = stores
        self.behavior = behavior
    }

    public func read<Value: Codable & Equatable & Sendable>(
        key: String,
        displayName: String?,
        description: String?,
        category: String?,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)?
    ) throws -> Setting<Value> {
        var result = try stores[0].read(
            key: key,
            displayName: displayName,
            description: description,
            category: category,
            defaultValue: defaultValue,
            validate: validate
        )

        for store in stores.dropFirst() {
            let higher = try store.read(
                key: key,
                displayName: displayName,
                description: description,
                category: category,
                defaultValue: defaultValue,
                validate: validate
            )
            result = merge(lesser: result, higher: higher)
        }
        return result
    }

    public func write(_ setting: any AnySetting) throws {
        switch behavior {
        case .overlay:
            try stores[stores.count - 1].write(setting)
        case .policy:
            try stores[0].write(setting)
        }
    }

    public func clear() throws {
        throw SettingsError.mergedStoreNotClearable
    }

    private func merge<Value>(lesser: Setting<Value>, higher: Setting<Value>) -> Setting<Value> {
        switch behavior {
        case .overlay:
            if higher.isSpecified {
                return lesser.replacing(
                    value: higher.value,
                    defaultValue: lesser.value,
                    isSpecified: true,
                    isReadOnly: higher.isReadOnly,
                    isDirty: higher.isDirty
                )
            }
            return lesser.replacing(
                value: lesser.value,
                defaultValue: lesser.value,
                isSpecified: lesser.isSpecified,
                isReadOnly: lesser.isReadOnly,
                isDirty: lesser.isDirty
            )

        case .policy:
            guard higher.isSpecified, higher.isCurrentValueValid else { return lesser }
            return lesser.replacing(
                value: higher.value,
                defaultValue: lesser.defaultValue,
                isSpecified: true,
                isReadOnly: true,
                isDirty: false
            )
        }
    }
}
