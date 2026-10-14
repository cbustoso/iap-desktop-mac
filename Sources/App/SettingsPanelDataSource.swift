import AuthKit
import ExplorerUI
import Foundation
import SettingsStore

@MainActor
final class ApplicationSettingsDataSource: SettingsPanelDataSource {
    private let projects: () -> [ProjectInfo]
    private let hierarchy: SettingsStoreHierarchy

    /// GH-72: `environment` fija el namespace del perfil (el legado conserva
    /// los nombres de siempre).
    init(environment: ProfileEnvironment, projects: @escaping () -> [ProjectInfo]) {
        self.projects = projects
        hierarchy = SettingsStoreHierarchy { scope, isSensitive in
            ApplicationSettingsDataSource.store(for: scope, isSensitive: isSensitive, environment: environment)
        }
    }

    func availableScopes() -> [SettingsPanelScope] {
        var result: [SettingsPanelScope] = [.universe]
        for project in projects() {
            result.append(.project(project.name))
            for zone in project.zones {
                result.append(.zone(project: project.name, zone: zone.name))
                result.append(contentsOf: zone.instances.map {
                    .instance(project: project.name, zone: zone.name, instance: $0.name)
                })
            }
        }
        return result
    }

    func loadSettings(at panelScope: SettingsPanelScope) throws -> SettingsPanelSnapshot {
        let scope = panelScope.storeScope
        let fields = try Self.descriptors.map { descriptor in
            try load(descriptor, scope: scope, parentScope: scope.parent)
        }
        return SettingsPanelSnapshot(scope: panelScope, fields: fields)
    }

    func saveSettings(_ snapshot: SettingsPanelSnapshot) throws {
        let scope = snapshot.scope.storeScope
        var writes: [SettingsWrite] = []
        for descriptor in Self.descriptors {
            guard let field = snapshot.fields.first(where: { $0.key == descriptor.key }) else { continue }
            writes.append(try makeWrite(field, descriptor: descriptor, scope: scope))
        }
        try hierarchy.writeAll(writes, at: scope)
    }

    private func load(
        _ descriptor: Descriptor,
        scope: SettingsScope,
        parentScope: SettingsScope?
    ) throws -> SettingsPanelField {
        let effective = hierarchy.effectiveStore(at: scope, isSensitive: descriptor.isSensitive)
        let local = hierarchy.localStore(at: scope, isSensitive: descriptor.isSensitive)
        let parent = parentScope.map { hierarchy.effectiveStore(at: $0, isSensitive: descriptor.isSensitive) }

        switch descriptor.defaultValue {
        case .text(let defaultValue):
            let effectiveValue: Setting<String> = try effective.read(key: descriptor.key, defaultValue: defaultValue)
            let localValue: Setting<String> = try local.read(key: descriptor.key, defaultValue: defaultValue)
            let inherited: Setting<String>? = try parent?.read(key: descriptor.key, defaultValue: defaultValue)
            return descriptor.field(
                value: .text(effectiveValue.value),
                inherited: .text(inherited?.value ?? defaultValue),
                overridden: localValue.isSpecified
            )
        case .integer(let defaultValue):
            let effectiveValue: Setting<Int> = try effective.read(key: descriptor.key, defaultValue: defaultValue)
            let localValue: Setting<Int> = try local.read(key: descriptor.key, defaultValue: defaultValue)
            let inherited: Setting<Int>? = try parent?.read(key: descriptor.key, defaultValue: defaultValue)
            return descriptor.field(
                value: .integer(effectiveValue.value),
                inherited: .integer(inherited?.value ?? defaultValue),
                overridden: localValue.isSpecified
            )
        case .toggle(let defaultValue):
            let effectiveValue: Setting<Bool> = try effective.read(key: descriptor.key, defaultValue: defaultValue)
            let localValue: Setting<Bool> = try local.read(key: descriptor.key, defaultValue: defaultValue)
            let inherited: Setting<Bool>? = try parent?.read(key: descriptor.key, defaultValue: defaultValue)
            return descriptor.field(
                value: .toggle(effectiveValue.value),
                inherited: .toggle(inherited?.value ?? defaultValue),
                overridden: localValue.isSpecified
            )
        }
    }

    private func makeWrite(
        _ field: SettingsPanelField,
        descriptor: Descriptor,
        scope: SettingsScope
    ) throws -> SettingsWrite {
        let local = hierarchy.localStore(at: scope, isSensitive: descriptor.isSensitive)
        switch descriptor.defaultValue {
        case .text(let defaultValue):
            var setting: Setting<String> = try local.read(key: descriptor.key, defaultValue: defaultValue)
            if field.isOverridden, case .text(let value) = field.value {
                if !setting.isSpecified || setting.value != value { setting.value = value }
            } else if setting.isSpecified {
                setting.reset()
            }
            return SettingsWrite(setting, isSensitive: descriptor.isSensitive)
        case .integer(let defaultValue):
            var setting: Setting<Int> = try local.read(key: descriptor.key, defaultValue: defaultValue)
            if field.isOverridden, case .integer(let value) = field.value {
                if !setting.isSpecified || setting.value != value { setting.value = value }
            } else if setting.isSpecified {
                setting.reset()
            }
            return SettingsWrite(setting, isSensitive: descriptor.isSensitive)
        case .toggle(let defaultValue):
            var setting: Setting<Bool> = try local.read(key: descriptor.key, defaultValue: defaultValue)
            if field.isOverridden, case .toggle(let value) = field.value {
                if !setting.isSpecified || setting.value != value { setting.value = value }
            } else if setting.isSpecified {
                setting.reset()
            }
            return SettingsWrite(setting, isSensitive: descriptor.isSensitive)
        }
    }

    nonisolated private static func store(
        for scope: SettingsScope,
        isSensitive: Bool,
        environment: ProfileEnvironment
    ) -> any SettingsStore {
        let component = scope.persistencePath.replacingOccurrences(of: "/", with: ".")
        if isSensitive {
            return KeychainSettingsStore(service: environment.settingsSecureService(component: component))
        }
        return UserDefaultsSettingsStore(suiteName: environment.settingsSuite(component: component))
    }

    private struct Descriptor {
        let key: String
        let title: String
        let help: String
        let kind: SettingsFieldKind
        let defaultValue: SettingsFieldValue
        let isSensitive: Bool

        func field(
            value: SettingsFieldValue,
            inherited: SettingsFieldValue,
            overridden: Bool
        ) -> SettingsPanelField {
            SettingsPanelField(
                key: key,
                title: title,
                help: help,
                kind: kind,
                value: value,
                inheritedValue: inherited,
                isOverridden: overridden
            )
        }
    }

    private static let descriptors: [Descriptor] = [
        Descriptor(key: "SshUsername", title: "SSH username", help: "POSIX user used for SSH sessions.", kind: .text, defaultValue: .text(""), isSensitive: false),
        Descriptor(key: "SshPassword", title: "SSH password", help: "Stored only in macOS Keychain.", kind: .secret, defaultValue: .text(""), isSensitive: true),
        Descriptor(key: "SshPort", title: "SSH port", help: "Remote SSH port.", kind: .integer(1...65_535), defaultValue: .integer(22), isSensitive: false),
        Descriptor(key: "RdpUsername", title: "Windows username", help: "Account used for RDP sessions.", kind: .text, defaultValue: .text(""), isSensitive: false),
        Descriptor(key: "RdpPassword", title: "Windows password", help: "Stored only in macOS Keychain.", kind: .secret, defaultValue: .text(""), isSensitive: true),
        Descriptor(key: "RdpDomain", title: "Windows domain", help: "Optional Windows domain.", kind: .text, defaultValue: .text(""), isSensitive: false),
        Descriptor(key: "RdpPort", title: "RDP port", help: "Remote Desktop port.", kind: .integer(1...65_535), defaultValue: .integer(3389), isSensitive: false),
        Descriptor(key: "RdpRedirectClipboard", title: "Redirect clipboard", help: "Share the clipboard with the remote desktop.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalFontSize", title: "Terminal font size", help: "Terminal font size in points.", kind: .integer(8...72), defaultValue: .integer(13), isSensitive: false),
    ]
}

private extension SettingsPanelScope {
    var storeScope: SettingsScope {
        switch self {
        case .universe: .universe
        case .project(let project): .project(project)
        case .zone(let project, let zone): .zone(project: project, zone: zone)
        case .instance(let project, let zone, let instance):
            .instance(project: project, zone: zone, instance: instance)
        }
    }
}

private extension SettingsScope {
    var parent: SettingsScope? {
        switch self {
        case .universe: nil
        case .project: .universe
        case .zone(let project, _): .project(project)
        case .instance(let project, let zone, _): .zone(project: project, zone: zone)
        }
    }
}
