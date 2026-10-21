import Foundation

// MARK: - Transporte HTTP (inyectable en tests)

public struct BastionHTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public protocol BastionHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> BastionHTTPResponse
}

/// `URLSession` (proxy del sistema incluido, REQ-AZ-9). Los `URLError` se
/// traducen a `BastionTunnelError` sin URL (la del DELETE lleva el authToken).
public struct URLSessionBastionTransport: BastionHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> BastionHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BastionTunnelError.protocolChanged(status: nil) }
            return BastionHTTPResponse(status: http.statusCode, body: data)
        } catch let error as URLError {
            throw error.code == .timedOut ? BastionTunnelError.timeout : BastionTunnelError.network("URLError \(error.code.rawValue)")
        }
    }
}

// MARK: - Plano de datos: POST/DELETE /api/tokens

/// Plano de datos del Bastion (research §3.3 (2), `tunnel.py` L80‑114 y L210‑230):
/// `POST https://{dnsName}/api/tokens` crea la sesión de una conexión TCP y
/// `DELETE /api/tokens/{authToken}` la cierra.
public struct BastionSessionClient: Sendable {
    /// `{authToken, nodeId, websocketToken}`. `description` redacta los tokens.
    public struct Session: Sendable, Equatable, Decodable, CustomStringConvertible {
        public let authToken: String
        public let nodeID: String
        public let websocketToken: String

        public init(authToken: String, nodeID: String, websocketToken: String) {
            self.authToken = authToken
            self.nodeID = nodeID
            self.websocketToken = websocketToken
        }

        private enum CodingKeys: String, CodingKey {
            case authToken
            case nodeID = "nodeId"
            case websocketToken
        }

        public var description: String {
            "Session(authToken: \(BastionRedaction.fingerprint(authToken)), nodeID: \(nodeID), "
                + "websocketToken: \(BastionRedaction.fingerprint(websocketToken)))"
        }
    }

    public enum CloseOutcome: Sendable, Equatable {
        case deleted
        /// 404: la sesión ya no existía (`tunnel.py` L225‑228); no es error.
        case alreadyGone
    }

    public static let requestTimeout: TimeInterval = 30

    private let transport: any BastionHTTPTransport
    /// Base distinta de `https://{dnsName}` (solo tests: `http://127.0.0.1:{puerto}`
    /// del servidor falso, para el contrato e2e por el wire).
    private let endpointOverride: URL?

    public init(transport: any BastionHTTPTransport = URLSessionBastionTransport(), endpointOverride: URL? = nil) {
        self.transport = transport
        self.endpointOverride = endpointOverride
    }

    /// Pide la sesión de una conexión. Con `previous`, encadena `token` +
    /// `X-Node-Id` como hace el CLI entre conexiones del mismo túnel.
    public func open(_ target: BastionTarget, armToken: String, previous: Session?) async throws -> Session {
        let response = try await transport.send(
            Self.openRequest(target, armToken: armToken, previous: previous, base: endpointOverride))
        guard response.status == 200 else { throw Self.error(for: response) }
        guard let session = try? JSONDecoder().decode(Session.self, from: response.body) else {
            throw BastionTunnelError.protocolChanged(status: 200)
        }
        return session
    }

    @discardableResult
    public func close(_ target: BastionTarget, _ session: Session) async throws -> CloseOutcome {
        let response = try await transport.send(try Self.closeRequest(target, session, base: endpointOverride))
        switch response.status {
        case 200, 204: return .deleted
        case 404: return .alreadyGone
        default: throw Self.error(for: response)
        }
    }

    // MARK: - Peticiones (estáticas para testearlas sin transporte)

    /// Campos en el orden de `tunnel.py` L84‑92; `token` solo si hay sesión previa.
    static func formFields(_ target: BastionTarget, armToken: String, previous: Session?) -> [(String, String)] {
        var fields = [
            ("resourceId", target.vmResourceID),
            ("protocol", "tcptunnel"),
            ("workloadHostPort", String(target.port)),
            ("aztoken", armToken),
        ]
        if let previous { fields.append(("token", previous.authToken)) }
        return fields
    }

    /// Conjunto de `urllib.parse.quote_plus` (lo que usa `requests` para el
    /// form): alfanuméricos y `_.-~`; el resto, percent-encoding.
    static let formAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")

    static func formEncode(_ fields: [(String, String)]) -> Data {
        let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "" }
        return Data(fields.map { "\(encode($0))=\(encode($1))" }.joined(separator: "&").utf8)
    }

    static func openRequest(
        _ target: BastionTarget, armToken: String, previous: Session?, base: URL? = nil
    ) -> URLRequest {
        var request = URLRequest(url: (base ?? baseURL(target)).appendingPathComponent("api/tokens"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let previous { request.setValue(previous.nodeID, forHTTPHeaderField: "X-Node-Id") }
        request.httpBody = formEncode(formFields(target, armToken: armToken, previous: previous))
        return request
    }

    static func closeRequest(_ target: BastionTarget, _ session: Session, base: URL? = nil) throws -> URLRequest {
        // El CLI interpola el token tal cual; un token que no forme una URL válida
        // indicaría un cambio de formato.
        let root = base.map { $0.absoluteString.hasSuffix("/") ? String($0.absoluteString.dropLast()) : $0.absoluteString }
            ?? "https://\(target.dnsName)"
        guard let url = URL(string: "\(root)/api/tokens/\(session.authToken)") else {
            throw BastionTunnelError.protocolChanged(status: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = requestTimeout
        request.setValue(session.nodeID, forHTTPHeaderField: "X-Node-Id")
        return request
    }

    private static func baseURL(_ target: BastionTarget) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = target.dnsName
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func error(for response: BastionHTTPResponse) -> BastionTunnelError {
        let message = BastionTunnelError.message(in: response.body)
        switch response.status {
        case 401, 403: return .unauthorized(message: message)
        case 404: return .targetNotFound
        default: return .serviceError(status: response.status, message: message)
        }
    }
}

// MARK: - Sesión compartida entre conexiones

/// Igual que el CLI (`tunnel.py` L155‑159, L210‑230): cada conexión TCP hace
/// su `POST` encadenando la sesión anterior y, cuando no queda ninguna activa,
/// un único `DELETE` de la última. Los `POST` se serializan para que el
/// encadenado sea determinista con conexiones concurrentes.
///
/// GH-95 (renovación): un `POST` que falla con un error reintentable
/// (`BastionTunnelError.isRetryable`) se repite con backoff, encadenando la
/// misma sesión previa (`token` + `X-Node-Id`). Ante 401/403 se descarta el
/// token ARM cacheado antes del siguiente intento; ante 404 con sesión
/// encadenada (el Bastion ya la olvidó) se pide una sesión nueva sin encadenar.
public actor BastionSessionPool {
    public typealias ArmTokenProvider = @Sendable () async throws -> String
    /// Olvida el token ARM cacheado (p. ej. `AzCliTokenSource.clearCache`).
    public typealias ArmTokenInvalidator = @Sendable () async -> Void

    public nonisolated let target: BastionTarget
    private let client: BastionSessionClient
    private let armToken: ArmTokenProvider
    private let invalidateArmToken: ArmTokenInvalidator
    private let retry: BastionRetryPolicy
    private let telemetry: BastionTelemetry
    private var current: BastionSessionClient.Session?
    private var active = 0
    private var tail: Task<Void, Never>?

    public init(
        target: BastionTarget,
        client: BastionSessionClient,
        retry: BastionRetryPolicy = .default,
        telemetry: BastionTelemetry = .oslog,
        invalidateArmToken: @escaping ArmTokenInvalidator = {},
        armToken: @escaping ArmTokenProvider
    ) {
        self.target = target
        self.client = client
        self.retry = retry
        self.telemetry = telemetry
        self.invalidateArmToken = invalidateArmToken
        self.armToken = armToken
    }

    /// Conexiones con sesión pedida o en uso.
    public var activeCount: Int { active }

    /// Sesión para una conexión nueva. Cada `acquire` exitoso exige un
    /// `release` (o `abandon`).
    public func acquire() async throws -> BastionSessionClient.Session {
        active += 1
        let previousTail = tail
        let post = Task { () async throws -> BastionSessionClient.Session in
            await previousTail?.value
            return try await self.postWithRetry()
        }
        tail = Task { _ = try? await post.value }
        do {
            return try await post.value
        } catch {
            active -= 1
            await deleteIfIdle()
            throw error
        }
    }

    public func release() async {
        active = max(0, active - 1)
        await deleteIfIdle()
    }

    /// Suelta una sesión cuyo WebSocket no llegó a abrirse **sin** `DELETE`:
    /// el siguiente `acquire` la encadena (renovación). Si ese `acquire` no
    /// llega o falla, el `DELETE` sale entonces (sigue siendo uno solo).
    public func abandon() {
        active = max(0, active - 1)
    }

    /// Tras un `abandon` sin reintento posterior (cancelación): `DELETE` si
    /// ninguna conexión usa ya la sesión.
    public func deleteIfUnused() async {
        await deleteIfIdle()
    }

    /// Cierre del forwarder/perfil: borra la sesión aunque queden conexiones.
    public func shutdown() async {
        active = 0
        await deleteIfIdle()
    }

    private func postWithRetry() async throws -> BastionSessionClient.Session {
        var attempt = 1
        while true {
            let chained = current != nil
            telemetry.record(target, .sessionRequested(attempt: attempt, chained: chained))
            do {
                let session = try await post()
                telemetry.record(target, .sessionOpened(attempt: attempt, chained: chained))
                return session
            } catch let error as BastionTunnelError {
                telemetry.record(target, .sessionFailed(attempt: attempt, error: error))
                let chainGone = error == .targetNotFound && chained
                guard attempt < retry.maxAttempts, error.isRetryable || chainGone else {
                    throw attempt > 1 ? BastionTunnelError.retriesExhausted(attempts: attempt, last: error) : error
                }
                if case .unauthorized = error {
                    await invalidateArmToken()
                    telemetry.record(target, .armTokenInvalidated)
                }
                if chainGone {
                    current = nil  // ya no existe en el Bastion: sin DELETE
                    telemetry.record(target, .chainDropped)
                }
                let delay = retry.delay(after: attempt)
                telemetry.record(target, .retryScheduled(attempt: attempt, delay: delay, reason: error))
                try await retry.sleep(delay)
                attempt += 1
            }
        }
    }

    private func post() async throws -> BastionSessionClient.Session {
        // Token ARM fresco por conexión: el proveedor renueva antes de caducar.
        let token = try await armToken()
        let session = try await client.open(target, armToken: token, previous: current)
        current = session
        return session
    }

    private func deleteIfIdle() async {
        guard active == 0, let session = current else { return }
        current = nil  // antes del await: un único DELETE por sesión
        do {
            telemetry.record(target, .sessionDeleted(try await client.close(target, session)))
        } catch {
            telemetry.record(target, .sessionDeleteFailed(BastionTunnelError(error)))
        }
    }
}

extension BastionTunnelError {
    /// Cualquier error como `BastionTunnelError` (los ajenos, como red sin clasificar).
    init(_ error: any Error) {
        if let error = error as? BastionTunnelError {
            self = error
        } else {
            self = .network(String(describing: type(of: error)))
        }
    }
}
