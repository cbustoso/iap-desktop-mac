import Foundation
import Network

/// Receptor loopback para OAuth installed-app (`http://127.0.0.1:{puerto}/authorize`).
///
/// Equivale a `LoopbackCodeReceiver` (C#) en modo `TcpListener`: sin HttpSys
/// (Windows-only). El puerto es efímero; se prefiere `127.0.0.1` a `localhost`
/// por coherencia IPv4/IPv6 (REQ-AUTH-1).
///
/// Single-shot por código: tras entregar un `code`, el listener se cierra.
/// Un `waitForCode` posterior espera un código nuevo (o expira).
public actor LoopbackReceiver {
    /// Sin trailing slash: `URL.path` normaliza `/authorize/` → `/authorize`.
    public static let callbackPath = "/authorize"
    private static let maxHeaderBytes = 64 * 1024

    private var listener: NWListener?
    private var port: UInt16?
    private var receivedCode: String?
    private var receivedError: AuthError?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    /// Enlaza `127.0.0.1:0` y devuelve la redirect URI. Cierra un listener
    /// previo si `start()` se llama dos veces (review #14).
    public func start() async throws -> URL {
        await cancelListenerOnly()
        receivedCode = nil
        receivedError = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let listener = try NWListener(using: parameters, on: 0)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection: connection) }
        }
        // NWListener invoca stateUpdateHandler en serie: la guarda local basta
        // para no resumir dos veces (review #1: .failed tras .ready).
        final class StartGate: @unchecked Sendable { var done = false }
        let gate = StartGate()
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { resume in
            listener.stateUpdateHandler = { state in
                guard !gate.done else { return }
                switch state {
                case .ready:
                    gate.done = true
                    if let port = listener.port?.rawValue {
                        resume.resume(returning: port)
                    } else {
                        resume.resume(throwing: AuthError.invalidResponse)
                    }
                case .failed(let error):
                    gate.done = true
                    resume.resume(throwing: error)
                case .cancelled:
                    gate.done = true
                    resume.resume(throwing: AuthError.userCancelled)
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
    /// Si el código (o un `?error=`) llegó antes, se devuelve/falla de
    /// inmediato (re-review R2 #3).
    public func waitForCode(timeoutSeconds: UInt64 = 120) async throws -> String {
        if let code = receivedCode {
            receivedCode = nil
            return code
        }
        if let error = receivedError {
            receivedError = nil
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.codeContinuation = continuation
            self.timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self.expire()  // la Task hereda el aislamiento del actor
            }
        }
    }

    /// Cancela el listener y falla la espera pendiente.
    public func cancel() async {
        failPending(with: AuthError.userCancelled)
        await cancelListenerOnly()
    }

    private func cancelListenerOnly() async {
        listener?.cancel()
        listener = nil
    }

    private func expire() {
        failPending(with: AuthError.loopbackTimeout)
    }

    private func settle() {
        codeContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func failPending(with error: Error) {
        guard let continuation = codeContinuation else { return }
        settle()
        continuation.resume(throwing: error)
    }

    private func deliver(code: String) {
        receivedCode = code
        if let continuation = codeContinuation {
            receivedCode = nil
            settle()
            continuation.resume(returning: code)
        }
        // Single-shot: cerrar el listener tras entregar (review #14).
        Task { await self.cancelListenerOnly() }
    }

    private func deliver(error: AuthError) {
        // Solo se guarda si no hay espera que lo consuma: si no, un segundo
        // waitForCode lanzaría un error obsoleto (R3-D). start() también limpia.
        if codeContinuation != nil {
            failPending(with: error)
        } else {
            receivedError = error
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveHeaders(connection: connection, accumulated: Data())
    }

    /// Acumula hasta `\r\n\r\n` (límite 64 KB): una petición fragmentada
    /// no debe dar 400 (review #14). Un error de transporte cancela sin
    /// reintentar: rearmar el receive sobre una conexión rota entraría en
    /// un bucle de Tasks (re-review R2 #4).
    private func receiveHeaders(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > Self.maxHeaderBytes || isComplete && buffer.isEmpty {
                Task { await self.respond(connection: connection, request: nil) }
                return
            }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete {
                Task { await self.respond(connection: connection, request: buffer) }
            } else {
                Task { await self.receiveHeaders(connection: connection, accumulated: buffer) }
            }
        }
    }

    private func respond(connection: NWConnection, request data: Data?) {
        guard
            let data, let text = String(data: data, encoding: .utf8),
            let requestLine = text.components(separatedBy: "\r\n").first,
            let target = requestLine.split(separator: " ").dropFirst().first
        else {
            send(status: "400 Bad Request", body: "Bad request", over: connection)
            return
        }
        let targetString = String(target)
        // ?error=access_denied (u otro) falla al momento en vez de esperar
        // al timeout (review #9 parcial; state/CSRF llega en T-AUTH-4).
        if Self.extractError(from: targetString) != nil {
            deliver(error: .userCancelled)
            send(status: "400 Bad Request", body: "Authorization denied", over: connection)
            return
        }
        guard let code = Self.extractCode(from: targetString) else {
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
        guard Self.isCallbackPath(target) else { return nil }
        return queryItems(of: target)?.first(where: { $0.name == "code" })?.value
    }

    /// Extrae `error` del target (`?error=access_denied`, etc.).
    static func extractError(from target: String) -> String? {
        guard Self.isCallbackPath(target) else { return nil }
        return queryItems(of: target)?.first(where: { $0.name == "error" })?.value
    }

    private static func isCallbackPath(_ target: String) -> Bool {
        guard let path = URLComponents(string: target)?.path else { return false }
        return path == callbackPath || path == callbackPath + "/"
    }

    private static func queryItems(of target: String) -> [URLQueryItem]? {
        URLComponents(string: target)?.queryItems
    }
}
