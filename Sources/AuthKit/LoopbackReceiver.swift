import Foundation
import Network

/// Receptor loopback para OAuth installed-app (`http://127.0.0.1:{puerto}/authorize/`).
///
/// Equivale a `LoopbackCodeReceiver` (C#) en modo `TcpListener`: sin HttpSys
/// (Windows-only). El puerto es efímero; se prefiere `127.0.0.1` a `localhost`
/// por coherencia IPv4/IPv6 (REQ-AUTH-1).
public actor LoopbackReceiver {
    /// Sin trailing slash: `URL.path` normaliza `/authorize/` → `/authorize`.
    public static let callbackPath = "/authorize"

    private var listener: NWListener?
    private var port: UInt16?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var settled = false

    public init() {}

    /// Enlaza `127.0.0.1:0` y devuelve la redirect URI. Llamar antes de `waitForCode`.
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: parameters, on: 0)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { resume in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resume.resume(returning: port)
                    } else {
                        resume.resume(throwing: AuthError.invalidResponse)
                    }
                case .failed(let error):
                    resume.resume(throwing: error)
                case .cancelled:
                    // Ignorado a propósito: cancel() tras un start() exitoso
                    // dispara .cancelled y la continuación ya se consumió.
                    break
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        self.port = boundPort
        return URL(string: "http://127.0.0.1:\(boundPort)\(Self.callbackPath)")!
    }

    /// Espera el `code` de la redirección del IdP (timeout 120 s por defecto).
    public func waitForCode(timeoutSeconds: UInt64 = 120) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.codeContinuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                await self.failPending(with: AuthError.loopbackTimeout)
            }
        }
    }

    /// Cancela el listener y falla la espera pendiente.
    public func cancel() async {
        await failPending(with: AuthError.userCancelled)
        listener?.cancel()
        listener = nil
    }

    private func failPending(with error: Error) {
        guard !settled, let continuation = codeContinuation else { return }
        settled = true
        codeContinuation = nil
        continuation.resume(throwing: error)
    }

    private func deliver(code: String) {
        guard !settled, let continuation = codeContinuation else { return }
        settled = true
        codeContinuation = nil
        continuation.resume(returning: code)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            Task { await self.respond(connection: connection, request: data) }
        }
    }

    private func respond(connection: NWConnection, request data: Data?) {
        guard
            let data, let text = String(data: data, encoding: .utf8),
            let requestLine = text.components(separatedBy: "\r\n").first,
            let target = requestLine.split(separator: " ").dropFirst().first,
            let code = Self.extractCode(from: String(target))
        else {
            send(status: "400 Bad Request", body: "Bad request", over: connection)
            return
        }
        deliver(code: code)
        send(status: "200 OK", body: "Authentication complete. You may close this window.", over: connection)
    }

    private func send(status: String, body: String, over connection: NWConnection) {
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        // Cancelar solo tras el flush: cancelar antes corta la conexión (-1005).
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Extrae `code` del target de un `GET` cuyo path sea `/authorize[/]`.
    static func extractCode(from target: String) -> String? {
        guard
            let components = URLComponents(string: target),
            components.path == callbackPath || components.path == callbackPath + "/"
        else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }
}
