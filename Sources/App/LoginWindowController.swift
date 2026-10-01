import AppKit
import AuthKit
import Foundation
import OSLog

/// Programmatic AppKit login window for the Google installed-app OAuth flow.
@MainActor
final class LoginWindowController: NSWindowController {
    typealias TokenClientFactory = @Sendable (String, String?) -> TokenClient
    typealias SessionFactory = @MainActor @Sendable (NSWindow) -> LoginSession

    private let facade: CredentialFacade
    private let clientIDStore: ClientIDStore
    private let tokenClientFactory: TokenClientFactory
    private let sessionFactory: SessionFactory

    private let clientIDField = NSTextField()
    private let saveClientIDButton = NSButton(title: "Save", target: nil, action: nil)
    private let customClientIDButton = NSButton(
        title: "Use a different OAuth client…", target: nil, action: nil)
    private var clientIDRow = NSStackView()
    private let signInButton = NSButton(title: "Sign in", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let headerLabel = NSTextField(labelWithString: "IAP Desktop Mac")
    private let descriptionLabel = NSTextField(labelWithString:
        "Sign in and start using IAP Desktop Mac to securely connect to your Linux and Windows VMs.")

    init(
        facade: CredentialFacade,
        clientID: String,
        tokenClientFactory: @escaping TokenClientFactory = { TokenClient(clientID: $0, clientSecret: $1) },
        sessionFactory: @escaping SessionFactory = { LoginSession(window: $0) }
    ) {
        self.facade = facade
        // Orden (CBU-36): override en UserDefaults > Info.plist > entorno.
        var environment = ProcessInfo.processInfo.environment
        if !clientID.isEmpty { environment[ClientIDStore.environmentKey] = clientID }
        self.clientIDStore = ClientIDStore(environment: environment)
        self.tokenClientFactory = tokenClientFactory
        self.sessionFactory = sessionFactory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Sign In"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        headerLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        headerLabel.alignment = .center
        descriptionLabel.font = .systemFont(ofSize: 12)
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.preferredMaxLayoutWidth = 340

        let signInRow = NSStackView(views: [GoogleGView(), signInButton])
        signInRow.orientation = .horizontal
        signInRow.alignment = .centerY
        signInRow.spacing = 8

        clientIDRow = NSStackView(views: [clientIDField, saveClientIDButton])
        clientIDRow.orientation = .horizontal
        clientIDRow.spacing = 8
        clientIDField.placeholderString = "OAuth client ID"

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: "Version \(version ?? "0.1")")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .right

        let stack = NSStackView(views: [
            headerLabel,
            descriptionLabel,
            signInRow,
            customClientIDButton,
            clientIDRow,
            statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Una etiqueta de `labelWithString` no hace wrap: sin esto los
        // mensajes largos (p. ej. el del enlace a Cloud Console) se cortan.
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 340
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        // Necesario para que el enlace a Cloud Console sea clicable.
        statusLabel.isSelectable = true
        statusLabel.allowsEditingTextAttributes = true

        customClientIDButton.isBordered = false
        customClientIDButton.font = .systemFont(ofSize: 11)
        customClientIDButton.contentTintColor = .linkColor
        customClientIDButton.target = self
        customClientIDButton.action = #selector(showCustomClientID(_:))

        // Como el IAP Desktop original: con client ID disponible solo se ve
        // "Sign in"; el campo queda como opción avanzada.
        if let clientID = try? clientIDStore.resolve() {
            clientIDField.stringValue = clientID
            clientIDRow.isHidden = true
        } else {
            customClientIDButton.isHidden = true
            showMissingClientIDStatus()
        }
        clientIDField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        saveClientIDButton.bezelStyle = .rounded
        saveClientIDButton.target = self
        saveClientIDButton.action = #selector(saveClientID(_:))
        signInButton.bezelStyle = .rounded
        signInButton.target = self
        signInButton.action = #selector(beginSignIn(_:))
        contentView.addSubview(stack)
        contentView.addSubview(versionLabel)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -30),
            versionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            versionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    /// Letra G multicolor estilo Google, dibujada por código (sin assets).
    final class GoogleGView: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let side = min(bounds.width, bounds.height)
            let lineWidth = side * 0.24
            let radius = side / 2 - lineWidth / 2 - 0.5
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            // Arcos en sentido antihorario con hueco al este; barra roja al centro.
            let segments: [(start: CGFloat, end: CGFloat, color: NSColor)] = [
                (25, 140, NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.96, alpha: 1)),   // azul
                (140, 245, NSColor(calibratedRed: 0.20, green: 0.66, blue: 0.33, alpha: 1)),  // verde
                (245, 300, NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.0, alpha: 1)),   // amarillo
                (300, 335, NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1)),  // rojo
            ]
            for segment in segments {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius,
                               startAngle: segment.start, endAngle: segment.end)
                path.lineWidth = lineWidth
                path.lineCapStyle = .butt
                segment.color.setStroke()
                path.stroke()
            }
            let bar = NSBezierPath(rect: NSRect(
                x: center.x - lineWidth / 2, y: center.y - lineWidth / 2,
                width: radius + lineWidth / 2, height: lineWidth))
            NSColor(calibratedRed: 0.92, green: 0.26, blue: 0.21, alpha: 1).setFill()
            bar.fill()
        }
    }

    @objc private func showCustomClientID(_ sender: Any?) {
        customClientIDButton.isHidden = true
        clientIDRow.isHidden = false
        window?.makeFirstResponder(clientIDField)
    }

    @objc private func saveClientID(_ sender: Any?) {
        // Campo vacío = quitar el override y volver al client ID por defecto.
        if clientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clientIDStore.clearOverride()
            if let clientID = try? clientIDStore.resolve() {
                clientIDField.stringValue = clientID
                statusLabel.stringValue = "Using the default client ID."
            } else {
                showMissingClientIDStatus()
            }
            return
        }
        do {
            clientIDField.stringValue = try clientIDStore.save(clientIDField.stringValue)
            statusLabel.stringValue = "Client ID saved."
        } catch {
            statusLabel.stringValue = "Enter a valid Google OAuth client ID."
        }
    }

    /// Sin client ID: mensaje con enlace a Cloud Console y el campo visible.
    private func showMissingClientIDStatus() {
        clientIDRow.isHidden = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        var link = base
        link[.link] = ClientIDStore.cloudConsoleCredentialsURL
        let message = NSMutableAttributedString(
            string: "No OAuth client ID configured. Create a Desktop app client in ", attributes: base)
        message.append(NSAttributedString(string: "Google Cloud Console", attributes: link))
        message.append(NSAttributedString(string: " and paste it above.", attributes: base))
        statusLabel.attributedStringValue = message
    }

    @objc private func beginSignIn(_ sender: Any?) {
        Task { @MainActor [weak self] in
            await self?.signIn()
        }
    }

    private func signIn() async {
        let clientID: String
        do {
            // Con client ID disponible (override, Info.plist o entorno) va
            // directo al navegador; solo persiste si el usuario escribió otro.
            clientID = try clientIDStore.clientIDForSignIn(fieldValue: clientIDField.stringValue)
            clientIDField.stringValue = clientID
        } catch AuthError.invalidResponse {
            clientIDRow.isHidden = false
            statusLabel.stringValue = "Enter a valid Google OAuth client ID."
            return
        } catch {
            showMissingClientIDStatus()
            return
        }
        signInButton.isEnabled = false
        defer { signInButton.isEnabled = true }
        var stage = LoginStage.preparing
        // Etapa visible + traza; nunca registra code, state, URLs ni tokens.
        func enter(_ next: LoginStage) {
            stage = next
            statusLabel.stringValue = next.statusText
            Self.log.info("login stage=\(next.rawValue, privacy: .public)")
        }
        enter(.preparing)

        do {
            // openid + email desde el primer intento: sin ellos Google no emite
            // id_token con email y no hay identidad que guardar (CBU-46).
            var scopes = AuthorizeURL.signInScopes
            for attempt in 0..<2 {
                let pkce = PKCE()
                let receiver = LoopbackReceiver()
                let redirectURI = try await receiver.start()
                do {
                    let authorize = AuthorizeURL(clientID: clientID, scopes: scopes)
                    let request = authorize.build(redirectURI: redirectURI, pkce: pkce)
                    guard let window else { throw AuthError.userCancelled }
                    let session = sessionFactory(window)
                    let authURL = request.url
                    let scheme = redirectURI.scheme
                    enter(.waitingForBrowser)
                    // El code puede llegar por el callback interceptado (sesión)
                    // o por el GET directo al loopback (el navegador no
                    // interceptó y el usuario vio la página de confirmación).
                    // Carrera: gana la primera URL completa (permite validar
                    // `state` en ambos casos); el perdedor se cancela, lo que
                    // cierra la hoja del navegador si el loopback ganó.
                    // Los fallos no deciden: si el usuario cierra la hoja pero
                    // el loopback entrega el código, el login continúa.
                    let callback: URL = try await withThrowingTaskGroup(of: URL.self) { group in
                        group.addTask { try await session.authenticate(url: authURL, callbackScheme: scheme) }
                        group.addTask { try await receiver.waitForCallbackURL() }
                        var firstError: Error?
                        while let result = await group.nextResult() {
                            switch result {
                            case .success(let url):
                                group.cancelAll()
                                return url
                            case .failure(let error):
                                if firstError == nil { firstError = error }
                            }
                        }
                        throw firstError ?? AuthError.userCancelled
                    }
                    // Paridad IAP Desktop: al volver del navegador la app se
                    // activa automáticamente y muestra el árbol.
                    NSApplication.shared.activate()
                    window.makeKeyAndOrderFront(nil)
                    await receiver.cancel()

                    if Self.callbackError(callback) == "consent_required", attempt == 0 {
                        // Fallback conservado: un segundo intento con email
                        // garantizado (ya incluido desde CBU-46; idempotente).
                        if !scopes.contains(AuthorizeURL.emailScope) { scopes.append(AuthorizeURL.emailScope) }
                        statusLabel.stringValue = "Additional consent is required…"
                        continue
                    }

                    enter(.validatingCallback)
                    let code = try authorize.validate(
                        callback: callback,
                        expectedState: request.state)
                    enter(.exchangingCode)
                    let response = try await tokenClientFactory(clientID, clientIDStore.clientSecret()).exchange(
                        code: code,
                        verifier: pkce.verifier,
                        redirectURI: redirectURI)
                    enter(.verifyingIdentity)
                    // Consentimiento granular: el usuario pudo desmarcar Cloud.
                    if !AuthorizeURL.missingScopes(granted: response.scope).isEmpty {
                        throw CloudAccessNotGranted()
                    }
                    let credential = try Self.offlineCredential(
                        from: response,
                        requestedScopes: scopes)
                    enter(.savingCredentials)
                    try await facade.authorize(
                        credential,
                        accessToken: response.accessToken,
                        expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)))
                    statusLabel.stringValue = "Signed in as \(credential.email)."
                    Self.log.info("login succeeded")
                    close()
                    return
                } catch {
                    await receiver.cancel()
                    throw error
                }
            }
            throw AuthError.consentRequired
        } catch is CloudAccessNotGranted {
            Self.log.error("login failed stage=\(stage.rawValue, privacy: .public) error=cloudPlatformNotGranted")
            statusLabel.stringValue = CloudAccessNotGranted.message
        } catch {
            Self.logFailure(error, at: stage)
            statusLabel.stringValue = LoginFailure.message(for: error, at: stage)
        }
    }

    /// El usuario desmarcó el permiso de Google Cloud en el consentimiento.
    private struct CloudAccessNotGranted: Error {
        static let message = "Google Cloud access was not granted. Sign in again and keep the "
            + "\"See, edit, configure and delete your Google Cloud data\" permission checked."
    }

    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    /// Traza del fallo: estado HTTP y error OAuth públicos; los `AuthError` no
    /// contienen secretos. De otros errores solo se registra el tipo.
    private static func logFailure(_ error: any Error, at stage: LoginStage) {
        switch error {
        case AuthError.tokenEndpoint(let status, let oauthError, let description):
            log.error("""
                login failed stage=\(stage.rawValue, privacy: .public) http=\(status, privacy: .public) \
                oauth_error=\(oauthError ?? "-", privacy: .public) description=\(description ?? "-", privacy: .public)
                """)
        case let authError as AuthError:
            log.error("""
                login failed stage=\(stage.rawValue, privacy: .public) \
                error=\(String(describing: authError), privacy: .public)
                """)
        default:
            log.error("""
                login failed stage=\(stage.rawValue, privacy: .public) \
                type=\(String(describing: type(of: error)), privacy: .public)
                """)
        }
    }

    private static func callbackError(_ callback: URL) -> String? {
        URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "error" })?.value
    }

    private static func offlineCredential(
        from response: TokenResponse,
        requestedScopes: [String]
    ) throws -> OfflineCredential {
        // Errores específicos: sin refresh_token / sin id_token / id_token sin email.
        let identity = try response.identity()
        let scopes = response.scope?.split(separator: " ").map(String.init) ?? requestedScopes
        return OfflineCredential(
            issuer: .gaia,
            email: identity.email,
            refreshToken: identity.refreshToken,
            idToken: identity.idToken,
            scopes: scopes)
    }
}
