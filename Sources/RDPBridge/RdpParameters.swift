import Foundation

// CBU-49 (T-RDP-3): parámetros RDP con los valores numéricos congelados del
// original (`Extensions.Session/Protocol/Rdp/RdpParameters.cs`, tabla en
// specs/rdp/requirements.md REQ-RDP-3). Se persisten como settings y los
// comparten la vía FreeRDP y el fallback `.rdp`: un caso nuevo recibe el
// siguiente `rawValue` libre, nunca se reasigna ni reutiliza uno existente.

public enum RdpConnectionBarState: Int, CaseIterable, Sendable {
    case autoHide = 0
    case pinned = 1
    case off = 2
    public static let defaultValue = Self.autoHide
}

public enum RdpAuthenticationLevel: Int, CaseIterable, Sendable {
    case attemptServerAuthentication = 0
    /// Oculto en la UI: con IAP casi siempre falla (no hay cert para localhost).
    case requireServerAuthentication = 1
    case noServerAuthentication = 3
    public static let defaultValue = Self.noServerAuthentication
}

public enum RdpColorDepth: Int, CaseIterable, Sendable {
    case highColor16 = 0
    case trueColor24 = 1
    case deepColor32 = 2
    public static let defaultValue = Self.trueColor24
}

public enum RdpAudioPlayback: Int, CaseIterable, Sendable {
    case playLocally = 0
    case playOnServer = 1
    case doNotPlay = 2
    public static let defaultValue = Self.playLocally
}

public enum RdpAudioInput: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpNetworkLevelAuthentication: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.enabled
}

public enum RdpAutomaticLogon: Int, CaseIterable, Sendable {
    case enabled = 0
    /// Oculto, heredado: no usar.
    case legacyAbortOnFailure = 1
    case disabled = 2
    public static let defaultValue = Self.enabled
}

public enum RdpRedirectClipboard: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.enabled
}

public enum RdpRedirectPrinter: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpRedirectSmartCard: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpRedirectPort: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpRedirectDrive: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpRedirectDevice: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpRedirectWebAuthn: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.enabled
}

public enum RdpHookWindowsKeys: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    case fullScreenOnly = 2
    public static let defaultValue = Self.fullScreenOnly
}

public enum RdpRestrictedAdminMode: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.disabled
}

public enum RdpSessionType: Int, CaseIterable, Sendable {
    case user = 0
    case admin = 1
    public static let defaultValue = Self.user
}

public enum RdpDpiScaling: Int, CaseIterable, Sendable {
    case disabled = 0
    case enabled = 1
    public static let defaultValue = Self.enabled
}

public enum RdpDesktopSize: Int, CaseIterable, Sendable {
    /// Oculto, heredado.
    case legacyClientSize = 0
    case screenSize = 1
    case autoAdjust = 2
    public static let defaultValue = Self.autoAdjust
}

/// Settings RDP de una instancia. Los defaults son los del original.
public struct RdpParameters: Equatable, Sendable {
    public var port: UInt16 = 3389
    public var connectionTimeout: TimeInterval = 30
    public var connectionBar = RdpConnectionBarState.defaultValue
    public var authenticationLevel = RdpAuthenticationLevel.defaultValue
    public var colorDepth = RdpColorDepth.defaultValue
    public var audioPlayback = RdpAudioPlayback.defaultValue
    public var audioInput = RdpAudioInput.defaultValue
    public var networkLevelAuthentication = RdpNetworkLevelAuthentication.defaultValue
    public var automaticLogon = RdpAutomaticLogon.defaultValue
    public var redirectClipboard = RdpRedirectClipboard.defaultValue
    public var redirectPrinter = RdpRedirectPrinter.defaultValue
    public var redirectSmartCard = RdpRedirectSmartCard.defaultValue
    public var redirectPort = RdpRedirectPort.defaultValue
    public var redirectDrive = RdpRedirectDrive.defaultValue
    public var redirectDevice = RdpRedirectDevice.defaultValue
    public var redirectWebAuthn = RdpRedirectWebAuthn.defaultValue
    public var hookWindowsKeys = RdpHookWindowsKeys.defaultValue
    public var restrictedAdminMode = RdpRestrictedAdminMode.defaultValue
    public var sessionType = RdpSessionType.defaultValue
    public var dpiScaling = RdpDpiScaling.defaultValue
    public var desktopSize = RdpDesktopSize.defaultValue

    public init() {}
}
