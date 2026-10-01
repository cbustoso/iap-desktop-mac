/// A persistence level in the Universe -> Project -> Zone -> Instance hierarchy.
///
/// `persistencePath` deliberately mirrors the original flat registry layout. An
/// instance inherits through its zone, but is persisted directly below its project.
public enum SettingsScope: Hashable, Sendable {
    case universe
    case project(String)
    case zone(project: String, zone: String)
    case instance(project: String, zone: String, instance: String)

    public var persistencePath: String {
        switch self {
        case .universe:
            "universe"
        case .project(let project):
            project
        case .zone(let project, let zone):
            "\(project)/zone-\(zone)"
        case .instance(let project, _, let instance):
            "\(project)/vm-\(instance)"
        }
    }

    public var lineage: [SettingsScope] {
        switch self {
        case .universe:
            [.universe]
        case .project(let project):
            [.universe, .project(project)]
        case .zone(let project, let zone):
            [.universe, .project(project), .zone(project: project, zone: zone)]
        case .instance(let project, let zone, let instance):
            [
                .universe,
                .project(project),
                .zone(project: project, zone: zone),
                .instance(project: project, zone: zone, instance: instance),
            ]
        }
    }
}

/// Type-erased write request used by settings forms containing mixed value types.
public struct SettingsWrite: Sendable {
    public let setting: any AnySetting
    public let isSensitive: Bool

    public init(_ setting: any AnySetting, isSensitive: Bool = false) {
        self.setting = setting
        self.isSensitive = isSensitive
    }
}

/// Builds effective overlay stores and keeps persistence targeted at one level.
/// Sensitive and ordinary values use independent store families so credentials can
/// always remain in Keychain.
public struct SettingsStoreHierarchy: Sendable {
    public typealias StoreProvider = @Sendable (
        _ scope: SettingsScope,
        _ isSensitive: Bool
    ) -> any SettingsStore

    private let storeProvider: StoreProvider

    public init(storeProvider: @escaping StoreProvider) {
        self.storeProvider = storeProvider
    }

    public func localStore(at scope: SettingsScope, isSensitive: Bool = false) -> any SettingsStore {
        storeProvider(scope, isSensitive)
    }

    public func effectiveStore(at scope: SettingsScope, isSensitive: Bool = false) -> any SettingsStore {
        let stores = scope.lineage.map { storeProvider($0, isSensitive) }
        guard stores.count > 1 else { return stores[0] }
        return MergedSettingsStore(stores: stores, behavior: .overlay)
    }

    /// Persists only edited values and only in the selected level.
    public func writeAll(_ writes: [SettingsWrite], at scope: SettingsScope) throws {
        for write in writes where write.setting.isDirty {
            try storeProvider(scope, write.isSensitive).write(write.setting)
        }
    }
}
