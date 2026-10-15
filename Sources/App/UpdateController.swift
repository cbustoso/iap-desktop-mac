import AppKit
import CryptoKit
import Foundation
import Sparkle

/// Ajustes globales del actualizador. Sparkle también persiste su calendario,
/// pero esta clave es la fuente explícita que muestra el menú de la app.
struct UpdateSettings {
    static let automaticChecksKey = "updates.automaticallyChecks"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.automaticChecksKey: true])
    }

    var automaticallyChecks: Bool {
        get { defaults.bool(forKey: Self.automaticChecksKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }
}

/// Sparkle se configura en código porque `resources/Info.plist` contiene sólo
/// datos públicos genéricos. `tools/make-app-bundle.sh` inyecta SUPublicEDKey
/// en la copia que se distribuye, nunca una clave privada.
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let feedURL =
        "https://github.com/cbustoso/iap-desktop-mac/releases/latest/download/appcast.xml"

    private let settings: UpdateSettings
    private var standardController: SPUStandardUpdaterController?

    init(settings: UpdateSettings = UpdateSettings()) {
        self.settings = settings
        super.init()
    }

    var automaticallyChecks: Bool { settings.automaticallyChecks }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil)
        standardController = controller
        controller.updater.sendsSystemProfile = false
        controller.updater.automaticallyChecksForUpdates = settings.automaticallyChecks
        do {
            try controller.updater.start()
        } catch {
            AppDelegate.log.error("Sparkle updater did not start: \(String(describing: error), privacy: .public)")
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL }

    func checkForUpdates() {
        guard let standardController else {
            showConfigurationAlert()
            return
        }
        standardController.checkForUpdates(nil)
    }

    func toggleAutomaticChecks() {
        settings.automaticallyChecks = !settings.automaticallyChecks
        standardController?.updater.automaticallyChecksForUpdates = settings.automaticallyChecks
    }

    private func showConfigurationAlert() {
        let alert = NSAlert()
        alert.messageText = "Updates are not configured"
        alert.informativeText = "This development build has no Sparkle public key. Install a release build to check for updates."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Offline validation used by release-focused tests

struct AppcastEntry: Equatable {
    let version: String
    let downloadURL: URL
    let edSignature: Data
}

enum AppcastValidation {
    static func entries(in data: Data) throws -> [AppcastEntry] {
        let parser = XMLParser(data: data)
        let delegate = AppcastParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.entries
    }

    static func verify(signature: Data, for archive: Data, publicKey: Data) throws -> Bool {
        try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            .isValidSignature(signature, for: archive)
    }
}

private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [AppcastEntry] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard elementName == "enclosure",
              let version = attributeDict["sparkle:version"],
              let urlString = attributeDict["url"],
              let url = URL(string: urlString),
              let encodedSignature = attributeDict["sparkle:edSignature"],
              let signature = Data(base64Encoded: encodedSignature)
        else { return }
        entries.append(AppcastEntry(version: version, downloadURL: url, edSignature: signature))
    }
}
