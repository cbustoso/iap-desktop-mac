import AppKit
import AuthKit
import Foundation

/// Programmatic AppKit login window for the Google installed-app OAuth flow.
@MainActor
final class LoginWindowController: NSWindowController {
    typealias TokenClientFactory = @Sendable (String) -> TokenClient
    typealias SessionFactory = @MainActor @Sendable (NSWindow) -> LoginSession

    private let facade: CredentialFacade
    private let clientIDStore: ClientIDStore
    private let tokenClientFactory: TokenClientFactory
    private let sessionFactory: SessionFactory

    private let clientIDField = NSTextField()
    private let saveClientIDButton = NSButton(title: "Save", target: nil, action: nil)
    private let signInButton = NSButton(title: "Sign in", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let headerLabel = NSTextField(labelWithString: "IAP Desktop Mac")
    private let descriptionLabel = NSTextField(labelWithString:
        "Sign in and start using IAP Desktop Mac to securely connect to your Linux and Windows VMs.")

    init(
        facade: CredentialFacade,
        clientID: String,
        tokenClientFactory: @escaping TokenClientFactory = { TokenClient(clientID: $0) },
        sessionFactory: @escaping SessionFactory = { LoginSession(window: $0) }
    ) {
        self.facade = facade
        self.clientIDStore = ClientIDStore(environment: clientID.isEmpty ? [:] : [
            ClientIDStore.environmentKey: clientID
        ])
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

        let clientIDRow = NSStackView(views: [clientIDField, saveClientIDButton])
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
            clientIDRow,
            statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        if let clientID = try? clientIDStore.resolve() {
            clientIDField.stringValue = clientID
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

    @objc private func saveClientID(_ sender: Any?) {
        do {
            clientIDField.stringValue = try clientIDStore.save(clientIDField.stringValue)
            statusLabel.stringValue = "Client ID saved."
        } catch {
            statusLabel.stringValue = "Enter a valid Google OAuth client ID."
        }
    }

    @objc private func beginSignIn(_ sender: Any?) {
        Task { @MainActor [weak self] in
            await self?.signIn()
        }
    }

    private func signIn() async {
        let clientID: String
        do {
            if clientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clientID = try clientIDStore.resolve()
            } else {
                clientID = try clientIDStore.save(clientIDField.stringValue)
                clientIDField.stringValue = clientID
            }
        } catch AuthError.invalidResponse {
            statusLabel.stringValue = "Enter a valid Google OAuth client ID."
            return
        } catch {
            statusLabel.stringValue = "Enter your Google OAuth client ID before signing in."
            return
        }
        signInButton.isEnabled = false
        statusLabel.stringValue = "Opening Google sign-in…"
        defer { signInButton.isEnabled = true }

        do {
            var scopes = [AuthorizeURL.cloudScope]
            for attempt in 0..<2 {
                let pkce = PKCE()
                let receiver = LoopbackReceiver()
                let redirectURI = try await receiver.start()
                do {
                    let authorize = AuthorizeURL(clientID: clientID, scopes: scopes)
                    let request = authorize.build(redirectURI: redirectURI, pkce: pkce)
                    guard let window else { throw AuthError.userCancelled }
                    let callback = try await sessionFactory(window).authenticate(
                        url: request.url,
                        callbackScheme: redirectURI.scheme)
                    await receiver.cancel()

                    if Self.callbackError(callback) == "consent_required", attempt == 0 {
                        scopes.append(AuthorizeURL.emailScope)
                        statusLabel.stringValue = "Additional consent is required…"
                        continue
                    }

                    let code = try authorize.validate(
                        callback: callback,
                        expectedState: request.state)
                    statusLabel.stringValue = "Completing sign-in…"
                    let response = try await tokenClientFactory(clientID).exchange(
                        code: code,
                        verifier: pkce.verifier,
                        redirectURI: redirectURI)
                    let credential = try Self.offlineCredential(
                        from: response,
                        requestedScopes: scopes)
                    try await facade.authorize(
                        credential,
                        accessToken: response.accessToken,
                        expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn)))
                    statusLabel.stringValue = "Signed in as \(credential.email)."
                    close()
                    return
                } catch {
                    await receiver.cancel()
                    throw error
                }
            }
            throw AuthError.consentRequired
        } catch AuthError.userCancelled {
            statusLabel.stringValue = "Sign-in was cancelled."
        } catch AuthError.consentRequired {
            statusLabel.stringValue = "Google requires additional consent."
        } catch {
            statusLabel.stringValue = "Sign-in failed. Please try again."
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
        guard
            let refreshToken = response.refreshToken,
            let idToken = response.idToken,
            let email = email(fromIDToken: idToken)
        else {
            throw AuthError.invalidResponse
        }
        let scopes = response.scope?.split(separator: " ").map(String.init) ?? requestedScopes
        return OfflineCredential(
            issuer: .gaia,
            email: email,
            refreshToken: refreshToken,
            idToken: idToken,
            scopes: scopes)
    }

    private static func email(fromIDToken token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = object["email"] as? String,
            !email.isEmpty
        else { return nil }
        return email
    }
}
