import Foundation
import Testing
@testable import RDPBridge

private func lines(_ text: String) -> [String] {
    text.components(separatedBy: "\r\n").dropLast().map { $0 }
}

@Suite("RdpFileGenerator (CBU-49)")
struct RdpFileGeneratorTests {
    @Test func defaultsSnapshot() throws {
        let text = try RdpFileGenerator.contents(
            parameters: RdpParameters(),
            credential: RdpCredentialReference(username: "ada", domain: "CORP"),
            localPort: 50123)
        #expect(text == """
            full address:s:127.0.0.1:50123\r
            username:s:ada\r
            domain:s:CORP\r
            prompt for credentials:i:0\r
            authentication level:i:0\r
            enablecredsspsupport:i:1\r
            administrative session:i:0\r
            session bpp:i:24\r
            audiomode:i:0\r
            audiocapturemode:i:0\r
            redirectclipboard:i:1\r
            redirectprinters:i:0\r
            redirectsmartcards:i:0\r
            redirectcomports:i:0\r
            drivestoredirect:s:\r
            devicestoredirect:s:\r
            redirectwebauthn:i:1\r
            keyboardhook:i:2\r
            displayconnectionbar:i:1\r
            pinconnectionbar:i:0\r
            dynamic resolution:i:1\r

            """)
    }

    @Test func allRedirectionsEnabledSnapshot() throws {
        var p = RdpParameters()
        p.redirectClipboard = .enabled
        p.redirectPrinter = .enabled
        p.redirectSmartCard = .enabled
        p.redirectPort = .enabled
        p.redirectDrive = .enabled
        p.redirectDevice = .enabled
        p.redirectWebAuthn = .enabled
        p.audioPlayback = .playOnServer
        p.audioInput = .enabled
        let text = try RdpFileGenerator.contents(parameters: p, credential: nil, localPort: 3390)
        #expect(Array(lines(text)[6...17]) == [
            "audiomode:i:1",
            "audiocapturemode:i:1",
            "redirectclipboard:i:1",
            "redirectprinters:i:1",
            "redirectsmartcards:i:1",
            "redirectcomports:i:1",
            "drivestoredirect:s:*",
            "devicestoredirect:s:*",
            "redirectwebauthn:i:1",
            "keyboardhook:i:2",
            "displayconnectionbar:i:1",
            "pinconnectionbar:i:0",
        ])
    }

    @Test func allRedirectionsDisabledSnapshot() throws {
        var p = RdpParameters()
        p.redirectClipboard = .disabled
        p.redirectWebAuthn = .disabled
        p.audioPlayback = .doNotPlay
        let text = try RdpFileGenerator.contents(parameters: p, credential: nil, localPort: 3390)
        let body = lines(text)
        #expect(body.contains("audiomode:i:2"))
        #expect(body.filter { $0.hasPrefix("redirect") }.allSatisfy { $0.hasSuffix(":i:0") })
        #expect(body.contains("drivestoredirect:s:"))
        #expect(body.contains("devicestoredirect:s:"))
    }

    @Test func adminDeepColorPinnedFixedSizeSnapshot() throws {
        var p = RdpParameters()
        p.sessionType = .admin
        p.colorDepth = .deepColor32
        p.connectionBar = .pinned
        p.desktopSize = .screenSize
        p.authenticationLevel = .attemptServerAuthentication
        p.networkLevelAuthentication = .disabled
        p.automaticLogon = .disabled
        p.hookWindowsKeys = .enabled
        let body = lines(try RdpFileGenerator.contents(parameters: p, credential: nil, localPort: 1))
        #expect(body == [
            "full address:s:127.0.0.1:1",
            "prompt for credentials:i:1",
            "authentication level:i:2",
            "enablecredsspsupport:i:0",
            "administrative session:i:1",
            "session bpp:i:32",
            "audiomode:i:0",
            "audiocapturemode:i:0",
            "redirectclipboard:i:1",
            "redirectprinters:i:0",
            "redirectsmartcards:i:0",
            "redirectcomports:i:0",
            "drivestoredirect:s:",
            "devicestoredirect:s:",
            "redirectwebauthn:i:1",
            "keyboardhook:i:1",
            "displayconnectionbar:i:1",
            "pinconnectionbar:i:1",
            "dynamic resolution:i:0",
        ])
    }

    @Test func everyEnumCaseTranslates() throws {
        // Cada caso tiene traducción (los switch son exhaustivos) y es válida.
        #expect(RdpAuthenticationLevel.allCases.map(RdpFileGenerator.authenticationLevel) == [2, 1, 0])
        #expect(RdpColorDepth.allCases.map(RdpFileGenerator.bitsPerPixel) == [16, 24, 32])
        #expect(RdpAudioPlayback.allCases.map(RdpFileGenerator.audioMode) == [0, 1, 2])
        #expect(RdpHookWindowsKeys.allCases.map(RdpFileGenerator.keyboardHook) == [0, 1, 2])
        #expect(RdpAutomaticLogon.allCases.map(RdpFileGenerator.promptForCredentials) == [0, 1, 1])
        #expect(RdpDesktopSize.allCases.map(RdpFileGenerator.dynamicResolution) == [false, false, true])
        var p = RdpParameters()
        p.connectionBar = .off
        let body = lines(try RdpFileGenerator.contents(parameters: p, credential: nil, localPort: 1))
        #expect(body.contains("displayconnectionbar:i:0"))
    }

    @Test func neverContainsPassword() throws {
        let text = try RdpFileGenerator.contents(
            parameters: RdpParameters(), credential: RdpCredentialReference(username: "ada"), localPort: 1)
        #expect(!text.lowercased().contains("password"))
        #expect(!text.contains("domain:s:"))  // dominio vacío se omite
        for line in lines(text) {
            #expect(line.split(separator: ":", maxSplits: 2).count >= 2, "línea mal formada: \(line)")
        }
    }

    @Test func rejectsLineInjectionInCredential() {
        #expect(throws: RdpError.invalidCredentialField("username")) {
            try RdpFileGenerator.contents(
                parameters: RdpParameters(),
                credential: RdpCredentialReference(username: "ada\r\nfull address:s:evil:3389"),
                localPort: 1)
        }
        #expect(throws: RdpError.invalidCredentialField("domain")) {
            try RdpFileGenerator.contents(
                parameters: RdpParameters(),
                credential: RdpCredentialReference(username: "ada", domain: "CORP\n"),
                localPort: 1)
        }
    }

    @Test func makeFileWritesPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdp-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try RdpFileGenerator.makeFile(
            parameters: RdpParameters(), credential: nil, localPort: 4000,
            name: "../win-01 (zone)", directory: directory)
        #expect(url.lastPathComponent == "_win-01__zone_.rdp")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("full address:s:127.0.0.1:4000\r\n"))
        #expect(RdpFileGenerator.fileName(for: "...") == "session.rdp")
    }
}
