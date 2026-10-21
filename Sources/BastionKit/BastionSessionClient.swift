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

    public init(transport: any BastionHTTPTransport = URLSessionBastionTransport()) {
        self.transport = transport
    }

    /// Pide la sesión de una conexión. Con `previous`, encadena `token` +
    /// `X-Node-Id` como hace el CLI entre conexiones del mismo túnel.
    public func open(_ target: BastionTarget, armToken: String, previous: Session?) async throws -> Session {
        let response = try await transport.send(
            Self.openRequest(target, armToken: armToken, previous: previous))
        guard response.status == 200 else { throw Self.error(for: response) }
        guard let session = try? JSONDecoder().decode(Session.self, from: response.body) else {
            throw BastionTunnelError.protocolChanged(status: 200)
        }
        return session
    }

    @discardableResult
    public func close(_ target: BastionTarget, _ session: Session) async throws -> CloseOutcome {
        let response = try await transport.send(try Self.closeRequest(target, session))
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

    static func openRequest(_ target: BastionTarget, armToken: String, previous: Session?) -> URLRequest {
        var request = URLRequest(url: baseURL(target).appendingPathComponent("api/tokens"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let previous { request.setValue(previous.nodeID, forHTTPHeaderField: "X-Node-Id") }
        request.httpBody = formEncode(formFields(target, armToken: armToken, previous: previous))
        return request
    }

    static func closeRequest(_ target: BastionTarget, _ session: Session) throws -> URLRequest {
        // El CLI interpola el token tal cual; un token que no forme una URL válida
        // indicaría un cambio de formato.
        guard let url = URL(string: "https://\(target.dnsName)/api/tokens/\(session.authToken)") else {
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
public actor BastionSessionPool {
    public typealias ArmTokenProvider = @Sendable () async throws -> String

    public nonisolated let target: BastionTarget
    private let client: BastionSessionClient
    private let armToken: ArmTokenProvider
    private var current: BastionSessionClient.Session?
    private var active = 0
    private var tail: Task<Void, Never>?

    public init(target: BastionTarget, client: BastionSessionClient, armToken: @escaping ArmTokenProvider) {
        self.target = target
        self.client = client
        self.armToken = armToken
    }

    /// Conexiones con sesión pedida o en uso.
    public var activeCount: Int { active }

    /// Sesión para una conexión nueva. Cada `acquire` exitoso exige un `release`.
    public func acquire() async throws -> BastionSessionClient.Session {
        active += 1
        let previousTail = tail
        let post = Task { () async throws -> BastionSessionClient.Session in
            await previousTail?.value
            return try await self.post()
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

    /// Cierre del forwarder/perfil: borra la sesión aunque queden conexiones.
    public func shutdown() async {
        active = 0
        await deleteIfIdle()
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
        _ = try? await client.close(target, session)
    }
}
