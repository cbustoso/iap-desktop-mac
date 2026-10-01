import Foundation
import Testing
@testable import SettingsStore

@Suite("MergedSettingsStore")
struct MergedSettingsStoreTests {
    @Test(
        "Overlay matrix: specified x valid",
        arguments: [
            OverlayCase(specified: false, value: 1, expected: 10),
            OverlayCase(specified: false, value: -1, expected: 10),
            OverlayCase(specified: true, value: 20, expected: 20),
            OverlayCase(specified: true, value: -2, expected: -2),
        ]
    )
    func overlayMatrix(testCase: OverlayCase) throws {
        let lower = MemorySettingsStore()
        let higher = MemorySettingsStore()
        try lower.put(key: "port", value: 10)
        if testCase.specified {
            try higher.put(key: "port", value: testCase.value)
        }
        let merged = MergedSettingsStore(stores: [lower, higher], behavior: .overlay)

        let setting: Setting<Int> = try merged.read(
            key: "port",
            defaultValue: testCase.value,
            validate: { $0 > 0 }
        )

        #expect(setting.value == testCase.expected)
        #expect(setting.defaultValue == 10)
        #expect(setting.isSpecified)
        #expect(!setting.isReadOnly)
    }

    @Test(
        "Policy matrix: specified valid policy wins, invalid policy is ignored",
        arguments: [
            PolicyCase(value: 20, expected: 20, expectedReadOnly: true),
            PolicyCase(value: -2, expected: 10, expectedReadOnly: false),
        ]
    )
    func policyMatrix(testCase: PolicyCase) throws {
        let local = MemorySettingsStore()
        let policy = MemorySettingsStore()
        try local.put(key: "port", value: 10)
        try policy.put(key: "port", value: testCase.value)
        let merged = MergedSettingsStore(stores: [local, policy], behavior: .policy)

        let setting: Setting<Int> = try merged.read(
            key: "port",
            defaultValue: 1,
            validate: { $0 > 0 }
        )

        #expect(setting.value == testCase.expected)
        #expect(setting.isReadOnly == testCase.expectedReadOnly)
        #expect(merged.isPolicyPresent)
    }

    @Test("Writes are routed by merge behavior")
    func writeRouting() throws {
        let lower = MemorySettingsStore()
        let higher = MemorySettingsStore()
        var setting = Setting(key: "port", defaultValue: 1)
        setting.value = 22

        try MergedSettingsStore(stores: [lower, higher], behavior: .overlay).write(setting)
        #expect(try higher.persisted(Int.self, key: "port") == 22)
        #expect(try lower.persisted(Int.self, key: "port") == nil)

        try MergedSettingsStore(stores: [lower, higher], behavior: .policy).write(setting)
        #expect(try lower.persisted(Int.self, key: "port") == 22)
    }

    @Test("A merged store cannot be cleared")
    func clearRejected() throws {
        let merged = MergedSettingsStore(stores: [MemorySettingsStore()], behavior: .overlay)
        #expect(throws: SettingsError.mergedStoreNotClearable) {
            try merged.clear()
        }
    }
}

@Suite("UserDefaultsSettingsStore")
struct UserDefaultsSettingsStoreTests {
    @Test("Round trip in an ephemeral suite")
    func roundTrip() throws {
        let suite = "com.iap-mac.settings.tests.\(UUID().uuidString)"
        let store = UserDefaultsSettingsStore(suiteName: suite)
        defer { try? store.clear() }

        var original = Setting(key: "connection.port", defaultValue: 22)
        original.value = 3389
        try store.write(original)

        let loaded: Setting<Int> = try store.read(key: "connection.port", defaultValue: 22)
        #expect(loaded.value == 3389)
        #expect(loaded.isSpecified)
        #expect(!loaded.isDirty)

        var reset = loaded
        reset.reset()
        try store.write(reset)
        let missing: Setting<Int> = try store.read(key: "connection.port", defaultValue: 22)
        #expect(missing.value == 22)
        #expect(!missing.isSpecified)
    }
}

@Suite("KeychainSettingsStore", .serialized)
struct KeychainSettingsStoreTests {
    @Test("Sensitive value round trips only through Keychain")
    func roundTripAndNeverWritesUserDefaults() throws {
        let identifier = UUID().uuidString
        let service = "com.iap-mac.settings.tests.\(identifier)"
        let suite = "com.iap-mac.settings.tests.defaults.\(identifier)"
        let store = KeychainSettingsStore(service: service)
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? store.clear()
            defaults.removePersistentDomain(forName: suite)
        }

        var secret = Setting(key: "ssh.password", defaultValue: "")
        secret.value = "do-not-persist-in-defaults"
        try store.write(secret)

        let loaded: Setting<String> = try store.read(key: "ssh.password", defaultValue: "")
        #expect(loaded.value == "do-not-persist-in-defaults")
        #expect(loaded.isSpecified)
        #expect(defaults.object(forKey: "ssh.password") == nil)
        #expect(!defaults.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("do-not-persist-in-defaults")
        })
    }
}

@Suite("SettingsStoreHierarchy")
struct SettingsStoreHierarchyTests {
    @Test("Effective values override and fall back through all four levels")
    func inheritance() throws {
        let universe = MemorySettingsStore()
        let project = MemorySettingsStore()
        let zone = MemorySettingsStore()
        let instance = MemorySettingsStore()
        try universe.put(key: "port", value: 22)
        try zone.put(key: "port", value: 2200)

        let hierarchy = SettingsStoreHierarchy { scope, _ in
            switch scope {
            case .universe: universe
            case .project: project
            case .zone: zone
            case .instance: instance
            }
        }

        let projectValue: Setting<Int> = try hierarchy.effectiveStore(
            at: .project("sample-project")
        ).read(key: "port", defaultValue: 1)
        let zoneValue: Setting<Int> = try hierarchy.effectiveStore(
            at: .zone(project: "sample-project", zone: "us-central1-a")
        ).read(key: "port", defaultValue: 1)
        let instanceFallback: Setting<Int> = try hierarchy.effectiveStore(
            at: .instance(project: "sample-project", zone: "us-central1-a", instance: "vm-1")
        ).read(key: "port", defaultValue: 1)

        #expect(projectValue.value == 22)
        #expect(zoneValue.value == 2200)
        #expect(instanceFallback.value == 2200)

        try instance.put(key: "port", value: 2222)
        let instanceOverride: Setting<Int> = try hierarchy.effectiveStore(
            at: .instance(project: "sample-project", zone: "us-central1-a", instance: "vm-1")
        ).read(key: "port", defaultValue: 1)
        #expect(instanceOverride.value == 2222)
        #expect(SettingsScope.zone(project: "p", zone: "z").persistencePath == "p/zone-z")
        #expect(SettingsScope.instance(project: "p", zone: "z", instance: "vm").persistencePath == "p/vm-vm")
    }

    @Test("writeAll skips clean settings and targets only the selected level")
    func dirtyWritesOnly() throws {
        let universe = MemorySettingsStore()
        let project = MemorySettingsStore()
        let hierarchy = SettingsStoreHierarchy { scope, _ in
            if case .project = scope { return project }
            return universe
        }
        let scope = SettingsScope.project("sample-project")
        let clean: Setting<Int> = try project.read(key: "port", defaultValue: 22)

        try hierarchy.writeAll([SettingsWrite(clean)], at: scope)
        #expect(project.writeCount == 0)
        #expect(universe.writeCount == 0)

        var dirty = clean
        dirty.value = 2200
        try hierarchy.writeAll([SettingsWrite(dirty)], at: scope)
        #expect(project.writeCount == 1)
        #expect(universe.writeCount == 0)
        #expect(try project.persisted(Int.self, key: "port") == 2200)
    }
}

struct OverlayCase: Sendable, CustomTestStringConvertible {
    let specified: Bool
    let value: Int
    let expected: Int

    var testDescription: String { "specified=\(specified), value=\(value)" }
}

struct PolicyCase: Sendable, CustomTestStringConvertible {
    let value: Int
    let expected: Int
    let expectedReadOnly: Bool

    var testDescription: String { "value=\(value)" }
}

private final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    func put<Value: Encodable>(key: String, value: Value) throws {
        let data = try JSONEncoder().encode(value)
        lock.withLock { values[key] = data }
    }

    func persisted<Value: Decodable>(_ type: Value.Type, key: String) throws -> Value? {
        guard let data = lock.withLock({ values[key] }) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    func read<Value: Codable & Equatable & Sendable>(
        key: String,
        displayName: String?,
        description: String?,
        category: String?,
        defaultValue: Value,
        validate: (@Sendable (Value) -> Bool)?
    ) throws -> Setting<Value> {
        guard let data = lock.withLock({ values[key] }) else {
            return Setting(
                key: key,
                displayName: displayName,
                description: description,
                category: category,
                defaultValue: defaultValue,
                validate: validate
            )
        }
        return Setting(
            key: key,
            displayName: displayName,
            description: description,
            category: category,
            value: try JSONDecoder().decode(Value.self, from: data),
            defaultValue: defaultValue,
            isSpecified: true,
            validate: validate
        )
    }

    func write(_ setting: any AnySetting) throws {
        let data = setting.isSpecified ? try setting.encodedValue() : nil
        lock.withLock {
            writes += 1
            values[setting.key] = data
        }
    }

    func clear() throws {
        lock.withLock { values.removeAll() }
    }
}
