import Foundation
import Security

public enum SettingsError: Error, Equatable, Sendable {
    case mergedStoreNotClearable
    case readOnlyStore
    case unknownEnumValue(key: String, raw: String)
    case keychainFailure(OSStatus)
    case invalidValue(key: String)
    case mdmUnavailable
}

/// Type-erased surface used by stores when persisting a setting.
///
/// The encoded payload is intentionally data-only: implementations never need to
/// stringify (and potentially log) a secret value.
public protocol AnySetting: Sendable {
    var key: String { get }
    var isSpecified: Bool { get }
    var isDirty: Bool { get }
    func encodedValue() throws -> Data
}

public struct Setting<Value: Codable & Equatable & Sendable>: AnySetting, Sendable {
    public let key: String
    public let displayName: String?
    public let description: String?
    public let category: String?
    public var value: Value {
        didSet {
            isSpecified = true
            isDirty = true
        }
    }
    public let defaultValue: Value
    public private(set) var isSpecified: Bool
    public private(set) var isReadOnly: Bool
    public private(set) var isDirty: Bool

    private let validate: @Sendable (Value) -> Bool

    public var isDefault: Bool { value == defaultValue }
    public var isCurrentValueValid: Bool { validate(value) }

    public init(
        key: String,
        displayName: String? = nil,
        description: String? = nil,
        category: String? = nil,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)? = nil
    ) {
        self.init(
            key: key,
            displayName: displayName,
            description: description,
            category: category,
            value: defaultValue,
            defaultValue: defaultValue,
            isSpecified: false,
            isReadOnly: false,
            isDirty: false,
            validate: validate
        )
    }

    public init(
        key: String,
        displayName: String? = nil,
        description: String? = nil,
        category: String? = nil,
        value: Value,
        defaultValue: Value,
        isSpecified: Bool,
        isReadOnly: Bool = false,
        isDirty: Bool = false,
        validate: (@Sendable (Value) -> Bool)? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.description = description
        self.category = category
        self.value = value
        self.defaultValue = defaultValue
        self.isSpecified = isSpecified
        self.isReadOnly = isReadOnly
        self.isDirty = isDirty
        self.validate = validate ?? { _ in true }
    }

    public mutating func reset() {
        value = defaultValue
        isSpecified = false
        isDirty = true
    }

    public func encodedValue() throws -> Data {
        try JSONEncoder().encode(value)
    }

    func replacing(
        value: Value,
        defaultValue: Value,
        isSpecified: Bool,
        isReadOnly: Bool,
        isDirty: Bool
    ) -> Self {
        Self(
            key: key,
            displayName: displayName,
            description: description,
            category: category,
            value: value,
            defaultValue: defaultValue,
            isSpecified: isSpecified,
            isReadOnly: isReadOnly,
            isDirty: isDirty,
            validate: validate
        )
    }
}

public protocol SettingsStore: Sendable {
    func read<Value: Codable & Equatable & Sendable>(
        key: String,
        displayName: String?,
        description: String?,
        category: String?,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)?
    ) throws -> Setting<Value>

    func write(_ setting: any AnySetting) throws
    func clear() throws
}

public extension SettingsStore {
    func read<Value: Codable & Equatable & Sendable>(
        key: String,
        displayName: String? = nil,
        description: String? = nil,
        category: String? = nil,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)? = nil
    ) throws -> Setting<Value> {
        try read(
            key: key,
            displayName: displayName,
            description: description,
            category: category,
            defaultValue: defaultValue,
            validate: validate
        )
    }
}
