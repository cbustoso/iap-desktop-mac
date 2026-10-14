import AuthKit
import ExplorerUI
import Foundation
import RDPBridge
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

    struct Descriptor {
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

    /// Esquema estable, en el mismo orden funcional que `ConnectionSettings`.
    /// Los enums multivalor se guardan por `rawValue`: sus valores están
    /// congelados en `RdpParameters.swift` y no deben renumerarse. Clipboard
    /// conserva el Bool del esquema anterior para no invalidar preferencias.
    static let descriptors: [Descriptor] = [
        // Remote Desktop connection.
        Descriptor(key: "RdpTransport", title: "RDP connect via", help: "0: IAP tunnel; 1: VPN or Interconnect.", kind: .integer(0...1), defaultValue: .integer(0), isSensitive: false),
        Descriptor(key: "RdpConnectionTimeout", title: "RDP connection timeout", help: "Time allowed to establish a Remote Desktop connection, in seconds.", kind: .integer(0...300), defaultValue: .integer(30), isSensitive: false),
        Descriptor(key: "RdpPort", title: "RDP port", help: "Remote Desktop server port.", kind: .integer(1...65_535), defaultValue: .integer(3389), isSensitive: false),

        // Windows credentials.
        Descriptor(key: "RdpUsername", title: "Windows username", help: "Local account, SAM account name, or UPN used for RDP sessions.", kind: .text, defaultValue: .text(""), isSensitive: false),
        Descriptor(key: "RdpPassword", title: "Windows password", help: "Stored only in macOS Keychain.", kind: .secret, defaultValue: .text(""), isSensitive: true),
        Descriptor(key: "RdpDomain", title: "Windows domain", help: "Optional NetBIOS domain or computer name.", kind: .text, defaultValue: .text(""), isSensitive: false),

        // Remote Desktop display.
        Descriptor(key: "RdpColorDepth", title: "Color depth", help: "0: 16-bit; 1: 24-bit; 2: 32-bit.", kind: .integer(0...2), defaultValue: .integer(RdpColorDepth.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpConnectionBar", title: "Connection bar", help: "0: auto-hide; 1: pinned; 2: off.", kind: .integer(0...2), defaultValue: .integer(RdpConnectionBarState.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpDesktopSize", title: "Display resolution", help: "0: legacy client size; 1: screen size; 2: auto-adjust.", kind: .integer(0...2), defaultValue: .integer(RdpDesktopSize.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpDpiScaling", title: "Display scaling", help: "Scale the remote display to match local display settings.", kind: .integer(0...1), defaultValue: .integer(RdpDpiScaling.defaultValue.rawValue), isSensitive: false),

        // Remote Desktop resources.
        Descriptor(key: "RdpAudioPlayback", title: "Audio playback", help: "0: play locally; 1: play remotely; 2: do not play.", kind: .integer(0...2), defaultValue: .integer(RdpAudioPlayback.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpAudioInput", title: "Microphone", help: "Share the default audio input device with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpAudioInput.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpHookWindowsKeys", title: "Windows shortcuts", help: "0: local; 1: remote; 2: remote in full screen only.", kind: .integer(0...2), defaultValue: .integer(RdpHookWindowsKeys.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRedirectClipboard", title: "Clipboard", help: "Share clipboard contents with the remote desktop.", kind: .toggle, defaultValue: .toggle(RdpRedirectClipboard.defaultValue == .enabled), isSensitive: false),
        Descriptor(key: "RdpRedirectPrinter", title: "Printers", help: "Share local printers with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpRedirectPrinter.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRedirectSmartCard", title: "Smart cards", help: "Share local smart cards with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpRedirectSmartCard.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRedirectPort", title: "Local ports", help: "Share local COM and LPT ports with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpRedirectPort.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRedirectDrive", title: "Drives", help: "Share local drives with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpRedirectDrive.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRedirectDevice", title: "Plug and Play devices", help: "Share local Plug and Play devices with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpRedirectDevice.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRedirectWebAuthn", title: "WebAuthn authenticators", help: "Share WebAuthn and Windows Hello devices with the remote desktop.", kind: .integer(0...1), defaultValue: .integer(RdpRedirectWebAuthn.defaultValue.rawValue), isSensitive: false),

        // Remote Desktop security.
        Descriptor(key: "RdpAutomaticLogon", title: "Automatic logon", help: "0: enabled; 2: disabled. Value 1 is reserved for legacy profiles.", kind: .integer(0...2), defaultValue: .integer(RdpAutomaticLogon.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpNetworkLevelAuthentication", title: "Network level authentication", help: "Secure the connection using NLA.", kind: .integer(0...1), defaultValue: .integer(RdpNetworkLevelAuthentication.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpAuthenticationLevel", title: "Server authentication", help: "0: attempt; 1: require; 3: do not authenticate.", kind: .integer(0...3), defaultValue: .integer(RdpAuthenticationLevel.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpRestrictedAdminMode", title: "Restricted Admin mode", help: "Avoid transmitting reusable credentials to the VM.", kind: .integer(0...1), defaultValue: .integer(RdpRestrictedAdminMode.defaultValue.rawValue), isSensitive: false),
        Descriptor(key: "RdpSessionType", title: "Session type", help: "0: user session; 1: admin session.", kind: .integer(0...1), defaultValue: .integer(RdpSessionType.defaultValue.rawValue), isSensitive: false),

        // SSH connection and credentials.
        Descriptor(key: "SshTransport", title: "SSH connect via", help: "0: IAP tunnel; 1: VPN or Interconnect.", kind: .integer(0...1), defaultValue: .integer(0), isSensitive: false),
        Descriptor(key: "SshConnectionTimeout", title: "SSH connection timeout", help: "Time allowed to establish an SSH connection, in seconds.", kind: .integer(0...300), defaultValue: .integer(30), isSensitive: false),
        Descriptor(key: "SshPort", title: "SSH port", help: "Remote SSH server port.", kind: .integer(1...65_535), defaultValue: .integer(22), isSensitive: false),
        Descriptor(key: "SshUsername", title: "SSH username", help: "Optional POSIX user used for SSH sessions.", kind: .text, defaultValue: .text(""), isSensitive: false),
        Descriptor(key: "SshPassword", title: "SSH password", help: "Stored only in macOS Keychain.", kind: .secret, defaultValue: .text(""), isSensitive: true),
        Descriptor(key: "SshPublicKeyValidity", title: "SSH key validity", help: "Validity of OS Login or metadata keys, in seconds.", kind: .integer(60...Int.max), defaultValue: .integer(2_592_000), isSensitive: false),
        Descriptor(key: "SshPublicKeyType", title: "SSH key type", help: "1: RSA-3072; 17: ECDSA P-256; 18: ECDSA P-384; 19: ECDSA P-521.", kind: .integer(1...19), defaultValue: .integer(18), isSensitive: false),

        // Terminal behavior.
        Descriptor(key: "TerminalCopyPasteCtrl", title: "Copy and paste with Ctrl", help: "Use Ctrl+C and Ctrl+V for terminal copy and paste.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalCopyPasteInsert", title: "Copy and paste with Insert", help: "Use Ctrl+Insert and Shift+Insert for terminal copy and paste.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalQuoteConversion", title: "Convert quotes on paste", help: "Convert typographic quotes when pasting into the terminal.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalBracketedPaste", title: "Bracketed paste", help: "Use bracketed-paste mode when supported by the remote shell.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalScrollCtrlHomeEnd", title: "Scroll with Ctrl+Home/End", help: "Use Ctrl+Home and Ctrl+End to scroll the terminal.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalScrollCtrlPage", title: "Scroll with Ctrl+Page Up/Down", help: "Use Ctrl+Page Up and Ctrl+Page Down to scroll the terminal.", kind: .toggle, defaultValue: .toggle(true), isSensitive: false),
        Descriptor(key: "TerminalFontFamily", title: "Terminal font", help: "Monospaced font family used by terminal sessions.", kind: .text, defaultValue: .text("Menlo"), isSensitive: false),
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
