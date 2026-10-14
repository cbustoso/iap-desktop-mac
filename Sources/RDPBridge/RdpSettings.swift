import Foundation

// GH-75: settings efectivos → `RdpParameters` + credencial, paridad
// `SessionContextFactory.CreateRdpContext` / `CreateRdpCredentialFromSettings`
// (cada `context.Parameters.X = settings.RdpX.Value`). La resolución por
// ámbitos (instancia → zona → proyecto → universo) la hace quien implementa
// `RdpSettingsSource` (en la App, `SettingsStoreHierarchy.effectiveStore`);
// RDPBridge no depende de SettingsStore.

/// Valor tal como está persistido. Los enums se guardan por `rawValue`
/// (`.integer`); los toggles del panel Settings, como `.bool`.
public enum RdpSettingValue: Equatable, Sendable {
    case integer(Int)
    case bool(Bool)
    case text(String)
}

/// Lectura de settings ya resueltos por ámbito. `nil` = no especificado en
/// ningún nivel (se usa el default del original).
public protocol RdpSettingsSource {
    func value(forKey key: String) throws -> RdpSettingValue?
}

/// Claves de settings (mismos nombres que el original y el panel Settings).
public enum RdpSettingKey {
    public static let username = "RdpUsername"
    public static let password = "RdpPassword"
    public static let domain = "RdpDomain"
    public static let port = "RdpPort"
    public static let connectionTimeout = "RdpConnectionTimeout"
    public static let connectionBar = "RdpConnectionBar"
    public static let authenticationLevel = "RdpAuthenticationLevel"
    public static let colorDepth = "RdpColorDepth"
    public static let audioPlayback = "RdpAudioPlayback"
    public static let audioInput = "RdpAudioInput"
    public static let networkLevelAuthentication = "RdpNetworkLevelAuthentication"
    public static let automaticLogon = "RdpAutomaticLogon"
    public static let redirectClipboard = "RdpRedirectClipboard"
    public static let redirectPrinter = "RdpRedirectPrinter"
    public static let redirectSmartCard = "RdpRedirectSmartCard"
    public static let redirectPort = "RdpRedirectPort"
    public static let redirectDrive = "RdpRedirectDrive"
    public static let redirectDevice = "RdpRedirectDevice"
    public static let redirectWebAuthn = "RdpRedirectWebAuthn"
    public static let hookWindowsKeys = "RdpHookWindowsKeys"
    public static let restrictedAdminMode = "RdpRestrictedAdminMode"
    public static let sessionType = "RdpSessionType"
    public static let dpiScaling = "RdpDpiScaling"
    public static let desktopSize = "RdpDesktopSize"
}

/// Settings RDP efectivos de una instancia. Sin contraseña: la credencial
/// secreta la resuelve el vault (Keychain) y nunca pasa por aquí ni por el `.rdp`.
public struct RdpEffectiveSettings: Equatable, Sendable {
    public var parameters = RdpParameters()
    /// Usuario/dominio de settings (`nil` si vacíos o no especificados).
    public var username: String?
    public var domain: String?
    /// Claves con valor inválido (tipo o rango): se ignoraron y se usó el default.
    public var ignoredKeys: [String] = []

    public init() {}

    /// Referencia de credencial para el `.rdp`: `username` explícito (p. ej.
    /// el de la credencial generada) o el de settings, con el dominio de settings.
    public func credential(username explicit: String? = nil) -> RdpCredentialReference? {
        guard let user = explicit.flatMap(Self.nonEmpty) ?? username else { return nil }
        return RdpCredentialReference(username: user, domain: domain)
    }

    public static func resolve(from source: some RdpSettingsSource) -> RdpEffectiveSettings {
        var reader = Reader(source: source)
        var settings = RdpEffectiveSettings()
        var p = RdpParameters()
        p.port = reader.port(RdpSettingKey.port) ?? p.port
        p.connectionTimeout = reader.seconds(RdpSettingKey.connectionTimeout) ?? p.connectionTimeout
        p.connectionBar = reader.choice(RdpSettingKey.connectionBar) ?? p.connectionBar
        p.authenticationLevel = reader.choice(RdpSettingKey.authenticationLevel) ?? p.authenticationLevel
        p.colorDepth = reader.choice(RdpSettingKey.colorDepth) ?? p.colorDepth
        p.audioPlayback = reader.choice(RdpSettingKey.audioPlayback) ?? p.audioPlayback
        p.audioInput = reader.choice(RdpSettingKey.audioInput) ?? p.audioInput
        p.networkLevelAuthentication = reader.choice(RdpSettingKey.networkLevelAuthentication) ?? p.networkLevelAuthentication
        p.automaticLogon = reader.choice(RdpSettingKey.automaticLogon) ?? p.automaticLogon
        p.redirectClipboard = reader.choice(RdpSettingKey.redirectClipboard) ?? p.redirectClipboard
        p.redirectPrinter = reader.choice(RdpSettingKey.redirectPrinter) ?? p.redirectPrinter
        p.redirectSmartCard = reader.choice(RdpSettingKey.redirectSmartCard) ?? p.redirectSmartCard
        p.redirectPort = reader.choice(RdpSettingKey.redirectPort) ?? p.redirectPort
        p.redirectDrive = reader.choice(RdpSettingKey.redirectDrive) ?? p.redirectDrive
        p.redirectDevice = reader.choice(RdpSettingKey.redirectDevice) ?? p.redirectDevice
        p.redirectWebAuthn = reader.choice(RdpSettingKey.redirectWebAuthn) ?? p.redirectWebAuthn
        p.hookWindowsKeys = reader.choice(RdpSettingKey.hookWindowsKeys) ?? p.hookWindowsKeys
        p.restrictedAdminMode = reader.choice(RdpSettingKey.restrictedAdminMode) ?? p.restrictedAdminMode
        p.sessionType = reader.choice(RdpSettingKey.sessionType) ?? p.sessionType
        p.dpiScaling = reader.choice(RdpSettingKey.dpiScaling) ?? p.dpiScaling
        p.desktopSize = reader.choice(RdpSettingKey.desktopSize) ?? p.desktopSize
        settings.parameters = p
        settings.username = reader.text(RdpSettingKey.username)
        settings.domain = reader.text(RdpSettingKey.domain)
        settings.ignoredKeys = reader.ignored
        return settings
    }

    fileprivate static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Lector tolerante: un valor ilegible o fuera de rango se ignora (default)
/// y se anota la clave, sin fallar la conexión.
private struct Reader<Source: RdpSettingsSource> {
    let source: Source
    var ignored: [String] = []

    init(source: Source) { self.source = source }

    private mutating func raw(_ key: String) -> RdpSettingValue? {
        do {
            return try source.value(forKey: key)
        } catch {
            ignored.append(key)
            return nil
        }
    }

    private mutating func reject<T>(_ key: String) -> T? {
        ignored.append(key)
        return nil
    }

    mutating func port(_ key: String) -> UInt16? {
        switch raw(key) {
        case nil: return nil
        case .integer(let value) where (1...65_535).contains(value): return UInt16(value)
        default: return reject(key)
        }
    }

    mutating func seconds(_ key: String) -> TimeInterval? {
        switch raw(key) {
        case nil: return nil
        case .integer(let value) where value > 0: return TimeInterval(value)
        default: return reject(key)
        }
    }

    /// Enum por `rawValue`; un toggle (`.bool`) vale 1/0 (`enabled`/`disabled`).
    mutating func choice<E: RawRepresentable<Int>>(_ key: String) -> E? {
        let rawValue: Int
        switch raw(key) {
        case nil: return nil
        case .integer(let value): rawValue = value
        case .bool(let on): rawValue = on ? 1 : 0
        case .text: return reject(key)
        }
        return E(rawValue: rawValue) ?? reject(key)
    }

    mutating func text(_ key: String) -> String? {
        switch raw(key) {
        case nil: return nil
        case .text(let value): return RdpEffectiveSettings.nonEmpty(value)
        default: return reject(key)
        }
    }
}
