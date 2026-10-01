import Testing
@testable import RDPBridge

/// Tabla `nombre → rawValue` de un enum: detecta casos reasignados, añadidos
/// o retirados (cualquiera cambia la tabla y obliga a revisar este test).
private func table<E: RawRepresentable & CaseIterable>(_: E.Type) -> [String: Int] where E.RawValue == Int {
    Dictionary(uniqueKeysWithValues: E.allCases.map { ("\($0)", $0.rawValue) })
}

/// Valores congelados 1:1 con el original (REQ-RDP-3). Se persisten como
/// settings: NO cambiar un número existente; un caso nuevo usa uno libre.
@Suite("RdpParameters congelados (CBU-49)")
struct RdpParametersTests {
    @Test func frozenRawValues() {
        #expect(table(RdpConnectionBarState.self) == ["autoHide": 0, "pinned": 1, "off": 2])
        #expect(table(RdpAuthenticationLevel.self) == [
            "attemptServerAuthentication": 0, "requireServerAuthentication": 1, "noServerAuthentication": 3,
        ])
        #expect(table(RdpColorDepth.self) == ["highColor16": 0, "trueColor24": 1, "deepColor32": 2])
        #expect(table(RdpAudioPlayback.self) == ["playLocally": 0, "playOnServer": 1, "doNotPlay": 2])
        #expect(table(RdpAutomaticLogon.self) == ["enabled": 0, "legacyAbortOnFailure": 1, "disabled": 2])
        #expect(table(RdpHookWindowsKeys.self) == ["disabled": 0, "enabled": 1, "fullScreenOnly": 2])
        #expect(table(RdpSessionType.self) == ["user": 0, "admin": 1])
        #expect(table(RdpDesktopSize.self) == ["legacyClientSize": 0, "screenSize": 1, "autoAdjust": 2])
        let onOff = ["disabled": 0, "enabled": 1]
        #expect(table(RdpAudioInput.self) == onOff)
        #expect(table(RdpNetworkLevelAuthentication.self) == onOff)
        #expect(table(RdpRedirectClipboard.self) == onOff)
        #expect(table(RdpRedirectPrinter.self) == onOff)
        #expect(table(RdpRedirectSmartCard.self) == onOff)
        #expect(table(RdpRedirectPort.self) == onOff)
        #expect(table(RdpRedirectDrive.self) == onOff)
        #expect(table(RdpRedirectDevice.self) == onOff)
        #expect(table(RdpRedirectWebAuthn.self) == onOff)
        #expect(table(RdpRestrictedAdminMode.self) == onOff)
        #expect(table(RdpDpiScaling.self) == onOff)
    }

    @Test func persistedValuesDecode() {
        // 2 nunca fue un nivel de autenticación: no debe decodificar a nada.
        #expect(RdpAuthenticationLevel(rawValue: 3) == .noServerAuthentication)
        #expect(RdpAuthenticationLevel(rawValue: 2) == nil)
        #expect(RdpDesktopSize(rawValue: 0) == .legacyClientSize)
        #expect(RdpConnectionBarState(rawValue: 3) == nil)
    }

    @Test func defaultsMatchOriginal() {
        let p = RdpParameters()
        #expect(p.port == 3389)
        #expect(p.connectionTimeout == 30)
        #expect(p.connectionBar == .autoHide)
        #expect(p.authenticationLevel == .noServerAuthentication)
        #expect(p.colorDepth == .trueColor24)
        #expect(p.audioPlayback == .playLocally)
        #expect(p.audioInput == .disabled)
        #expect(p.networkLevelAuthentication == .enabled)
        #expect(p.automaticLogon == .enabled)
        #expect(p.redirectClipboard == .enabled)
        #expect(p.redirectPrinter == .disabled)
        #expect(p.redirectSmartCard == .disabled)
        #expect(p.redirectPort == .disabled)
        #expect(p.redirectDrive == .disabled)
        #expect(p.redirectDevice == .disabled)
        #expect(p.redirectWebAuthn == .enabled)
        #expect(p.hookWindowsKeys == .fullScreenOnly)
        #expect(p.restrictedAdminMode == .disabled)
        #expect(p.sessionType == .user)
        #expect(p.dpiScaling == .enabled)
        #expect(p.desktopSize == .autoAdjust)
    }
}
