import AppKit
import AuthKit
import Foundation

/// Programmatic AppKit login window for the Google installed-app OAuth flow.
@MainActor
final class LoginWindowController: NSWindowController {
    typealias TokenClientFactory = @Sendable (String) -> TokenClient
    typealias SessionFactory = @MainActor @Sendable (NSWindow) -> LoginSession

    private let facade: CredentialFacade
    private let clientID: String
    private let tokenClientFactory: TokenClientFactory
    private let sessionFactory: SessionFactory

    private let signInButton = NSButton(title: "Sign in with Google", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Sign in to access Google Cloud resources.")

    init(
        facade: CredentialFacade,
        clientID: String,
        tokenClientFactory: @escaping TokenClientFactory = { TokenClient(clientID: $0) },
        sessionFactory: @escaping SessionFactory = { LoginSession(window: $0) }
    ) {
        self.facade = facade
        self.clientID = clientID
        self.tokenClientFactory = tokenClientFactory
        self.sessionFactory = sessionFactory

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
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
        let stack = NSStackView(views: [statusLabel, signInButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        signInButton.bezelStyle = .rounded
        signInButton.target = self
        signInButton.action = #selector(beginSignIn(_:))
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -30),
        ])
    }

    @objc private func beginSignIn(_ sender: Any?) {
        Task { @MainActor [weak self] in
            await self?.signIn()
        }
    }

    private func signIn() async {
        guard !clientID.isEmpty else {
            statusLabel.stringValue = "Set GOOGLE_OAUTH_CLIENT_ID before signing in."
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
