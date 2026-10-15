import CryptoKit
import Foundation
import Testing
@testable import App

@Suite("Sparkle updates")
struct UpdateTests {
    @Test func parsesSignedAppcastWithoutNetwork() throws {
        let signature = Data(repeating: 0xA5, count: 64)
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
              <channel><item><enclosure
                url="https://github.com/cbustoso/iap-desktop-mac/releases/download/v1.2.3/IAPDesktopMac.zip"
                sparkle:version="123"
                sparkle:edSignature="\(signature.base64EncodedString())"
                length="42" type="application/octet-stream" />
              </item></channel>
            </rss>
            """

        let entries = try AppcastValidation.entries(in: Data(xml.utf8))

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.version == "123")
        #expect(entry.downloadURL.lastPathComponent == "IAPDesktopMac.zip")
        #expect(entry.edSignature == signature)
    }

    @Test func verifiesEdDSASignatureWithEphemeralTestKeyPair() throws {
        // Par exclusivamente de prueba, generado en memoria: ninguna clave
        // privada (real ni fixture) queda escrita en el repositorio.
        let privateKey = Curve25519.Signing.PrivateKey()
        let archive = Data("test-only update archive".utf8)
        let signature = try privateKey.signature(for: archive)

        #expect(try AppcastValidation.verify(
            signature: signature,
            for: archive,
            publicKey: privateKey.publicKey.rawRepresentation))
        #expect(try !AppcastValidation.verify(
            signature: signature,
            for: Data("tampered archive".utf8),
            publicKey: privateKey.publicKey.rawRepresentation))
    }

    @Test func automaticChecksAreReadFromSettings() throws {
        let suite = "UpdateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UpdateSettings(defaults: defaults)

        #expect(settings.automaticallyChecks)
        settings.automaticallyChecks = false
        #expect(!UpdateSettings(defaults: defaults).automaticallyChecks)
    }
}
