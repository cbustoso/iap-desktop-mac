@preconcurrency import AuthenticationServices
import AppKit
import Foundation

/// Browser authorization session. Tests can inject a launcher that returns a
/// fixed callback URL without displaying UI.
public struct LoginSession: Sendable {
    public typealias Launcher = @Sendable (URL, String?) async throws -> URL

    private let launcher: Launcher

    public init(launcher: @escaping Launcher) {
        self.launcher = launcher
    }

    @MainActor
    public init(window: NSWindow) {
        let webLauncher = WebAuthenticationLauncher(window: window)
        self.launcher = { url, callbackScheme in
            try await webLauncher.authenticate(url: url, callbackScheme: callbackScheme)
        }
    }

    public func authenticate(url: URL, callbackScheme: String?) async throws -> URL {
        try await launcher(url, callbackScheme)
    }
}

@MainActor
private final class WebAuthenticationLauncher: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private weak var window: NSWindow?
    private var activeSession: ASWebAuthenticationSession?

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }

    func authenticate(url: URL, callbackScheme: String?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callback, error in
                let result: Result<URL, AuthError>
                if let callback {
                    result = .success(callback)
                } else if let authenticationError = error as? ASWebAuthenticationSessionError,
                          authenticationError.code == .canceledLogin {
                    result = .failure(.userCancelled)
                } else {
                    result = .failure(.invalidResponse)
                }
                Task { @MainActor in
                    self?.activeSession = nil
                    continuation.resume(with: result)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: AuthError.invalidResponse)
                return
            }
        }
    }
}
