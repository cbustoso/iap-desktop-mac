import Foundation

// MARK: - Transporte HTTP (inyectable en tests)

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BastionError.unexpectedResponse }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name)] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

public enum BastionError: Error, Equatable, CustomStringConvertible {
    case skuNotSupported(String)
    case tunnelingDisabled
    case missingDnsName
    case http(operation: String, status: Int, message: String?)
    case unexpectedResponse
    case invalidJSON(String)

    public var description: String {
        switch self {
        case .skuNotSupported(let sku):
            return "El Bastion es SKU \(sku): el túnel nativo exige Standard o Premium."
        case .tunnelingDisabled:
            return "El Bastion no tiene 'Native client support' (enableTunneling = false)."
        case .missingDnsName:
            return "El Bastion no expone properties.dnsName."
        case .http(let operation, let status, let message):
            return "\(operation) → HTTP \(status)" + (message.map { ": \($0)" } ?? "")
        case .unexpectedResponse:
            return "Respuesta HTTP inesperada."
        case .invalidJSON(let what):
            return "JSON inesperado en \(what)."
        }
    }

    static func message(in body: Data) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let message: String?
            let error: Inner?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return nil }
        return envelope.message ?? envelope.error?.message
    }
}

// MARK: - IDs ARM

public enum ResourceID {
    public static func virtualMachine(subscription: String, resourceGroup: String, name: String) -> String {
        "/subscriptions/\(subscription)/resourceGroups/\(resourceGroup)/providers/Microsoft.Compute/virtualMachines/\(name)"
    }

    public static func bastionHost(subscription: String, resourceGroup: String, name: String) -> String {
        "/subscriptions/\(subscription)/resourceGroups/\(resourceGroup)/providers/Microsoft.Network/bastionHosts/\(name)"
    }
}

// MARK: - (c) GET ARM del Bastion

/// La única llamada ARM del túnel (research §3.3 (1)): lectura del bastionHost
/// para `sku.name`, `enableTunneling` y `dnsName`.
public struct BastionHost: Decodable, Sendable, Equatable {
    public struct SKU: Decodable, Sendable, Equatable {
        public let name: String
    }

    public struct Properties: Decodable, Sendable, Equatable {
        public let dnsName: String?
        public let enableTunneling: Bool?
        public let enableIpConnect: Bool?
        public let provisioningState: String?
    }

    public let id: String
    public let name: String
    public let location: String?
    public let sku: SKU?
    public let properties: Properties

    public static let apiVersion = "2024-01-01"
    public static let tunnelSKUs: Set<String> = ["Standard", "Premium"]

    /// Mismo gate que `custom.py` L461‑463 del CLI. Devuelve el `dnsName`.
    public func tunnelEndpoint() throws -> String {
        let skuName = sku?.name ?? "desconocido"
        guard Self.tunnelSKUs.contains(skuName) else { throw BastionError.skuNotSupported(skuName) }
        guard properties.enableTunneling == true else { throw BastionError.tunnelingDisabled }
        guard let dnsName = properties.dnsName, !dnsName.isEmpty else { throw BastionError.missingDnsName }
        return dnsName
    }

    public static func request(
        resourceID: String, armToken: String, armBase: URL = URL(string: "https://management.azure.com")!
    ) -> URLRequest {
        var components = URLComponents(url: armBase, resolvingAgainstBaseURL: false)!
        components.path = resourceID
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(armToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func fetch(
        resourceID: String, armToken: String, transport: any HTTPTransport, log: SpikeLog = .shared
    ) async throws -> BastionHost {
        let request = request(resourceID: resourceID, armToken: armToken)
        log.debug("GET \(request.url!.absoluteString) Authorization: Bearer \(Redact.secret(armToken))")
        let response = try await transport.send(request)
        log.debug("GET bastionHost → HTTP \(response.status)")
        guard response.status == 200 else {
            throw BastionError.http(operation: "GET bastionHost", status: response.status, message: BastionError.message(in: response.body))
        }
        guard let host = try? JSONDecoder().decode(BastionHost.self, from: response.body) else {
            throw BastionError.invalidJSON("bastionHost")
        }
        return host
    }
}

// MARK: - (d) Plano de datos: POST/DELETE /api/tokens

/// `{authToken, nodeId, websocketToken}` de `POST /api/tokens` (`tunnel.py` L112‑114).
public struct BastionSessionTokens: Decodable, Sendable, Equatable, CustomStringConvertible {
    public let authToken: String
    public let nodeId: String
    public let websocketToken: String

    public init(authToken: String, nodeId: String, websocketToken: String) {
        self.authToken = authToken
        self.nodeId = nodeId
        self.websocketToken = websocketToken
    }

    public var description: String {
        "BastionSessionTokens(authToken: \(Redact.secret(authToken)), nodeId: \(nodeId), websocketToken: \(Redact.secret(websocketToken)))"
    }
}

public enum DeleteOutcome: Sendable, Equatable {
    case deleted(status: Int)
    /// 404: la sesión ya no existía (`tunnel.py` L225‑228).
    case alreadyGone
}

public struct BastionDataPlane: Sendable {
    public let dnsName: String
    private let transport: any HTTPTransport
    private let log: SpikeLog

    public init(dnsName: String, transport: any HTTPTransport, log: SpikeLog = .shared) {
        self.dnsName = dnsName
        self.transport = transport
        self.log = log
    }

    /// Conjunto de `urllib.parse.quote_plus` (lo que usa `requests` para el form):
    /// alfanuméricos y `_.-~`; el resto, percent-encoding.
    static let formAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")
        return set
    }()

    static func formEncode(_ fields: [(String, String)]) -> Data {
        let body = fields.map { name, value in
            let encode = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? "" }
            return "\(encode(name))=\(encode(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// Campos en el orden de `tunnel.py` L84‑92. `token` solo si hay sesión previa.
    static func tokenFields(
        resourceID: String, port: Int, azToken: String, previous: BastionSessionTokens?
    ) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("resourceId", resourceID),
            ("protocol", "tcptunnel"),
            ("workloadHostPort", String(port)),
            ("aztoken", azToken),
        ]
        if let previous { fields.append(("token", previous.authToken)) }
        return fields
    }

    func tokenRequest(resourceID: String, port: Int, azToken: String, previous: BastionSessionTokens?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(dnsName)/api/tokens")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let previous { request.setValue(previous.nodeId, forHTTPHeaderField: "X-Node-Id") }
        request.httpBody = Self.formEncode(Self.tokenFields(resourceID: resourceID, port: port, azToken: azToken, previous: previous))
        return request
    }

    func deleteRequest(_ tokens: BastionSessionTokens) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(dnsName)/api/tokens/\(tokens.authToken)")!)
        request.httpMethod = "DELETE"
        request.setValue(tokens.nodeId, forHTTPHeaderField: "X-Node-Id")
        return request
    }

    public func requestTokens(
        resourceID: String, port: Int, azToken: String, previous: BastionSessionTokens?
    ) async throws -> BastionSessionTokens {
        let fields = Self.tokenFields(resourceID: resourceID, port: port, azToken: azToken, previous: previous)
        log.info("POST https://\(dnsName)/api/tokens " + Redact.form(fields)
            + (previous.map { " X-Node-Id: \($0.nodeId)" } ?? ""))
        let response = try await transport.send(tokenRequest(resourceID: resourceID, port: port, azToken: azToken, previous: previous))
        guard response.status == 200 else {
            log.warn("POST /api/tokens → HTTP \(response.status) headers: \(response.headers.keys.sorted())")
            throw BastionError.http(operation: "POST /api/tokens", status: response.status, message: BastionError.message(in: response.body))
        }
        guard let tokens = try? JSONDecoder().decode(BastionSessionTokens.self, from: response.body) else {
            throw BastionError.invalidJSON("POST /api/tokens")
        }
        log.register(secret: tokens.authToken)
        log.register(secret: tokens.websocketToken)
        log.info("POST /api/tokens → 200 \(tokens)")
        return tokens
    }

    public func deleteTokens(_ tokens: BastionSessionTokens) async throws -> DeleteOutcome {
        log.info("DELETE https://\(dnsName)/api/tokens/\(Redact.secret(tokens.authToken)) X-Node-Id: \(tokens.nodeId)")
        let response = try await transport.send(deleteRequest(tokens))
        log.info("DELETE /api/tokens → HTTP \(response.status)")
        switch response.status {
        case 200, 204: return .deleted(status: response.status)
        case 404: return .alreadyGone
        default:
            throw BastionError.http(operation: "DELETE /api/tokens", status: response.status, message: BastionError.message(in: response.body))
        }
    }
}

// MARK: - Sesión compartida entre conexiones

/// Igual que el CLI: cada conexión TCP hace su `POST` (encadenando `token` +
/// `X-Node-Id` de la anterior) y, cuando no queda ninguna activa, un único
/// `DELETE` (`tunnel.py` L155‑159, L210‑230).
public actor BastionSessionManager {
    private let dataPlane: BastionDataPlane
    private let resourceID: String
    private let port: Int
    private let azToken: @Sendable () async throws -> String
    private let log: SpikeLog
    private var current: BastionSessionTokens?
    private var active = 0
    /// Última sesión borrada; solo para repetir el DELETE en A0.4 (debe dar 404).
    public private(set) var lastDeleted: BastionSessionTokens?

    public init(
        dataPlane: BastionDataPlane, resourceID: String, port: Int, log: SpikeLog = .shared,
        azToken: @escaping @Sendable () async throws -> String
    ) {
        self.dataPlane = dataPlane
        self.resourceID = resourceID
        self.port = port
        self.log = log
        self.azToken = azToken
    }

    public var activeConnections: Int { active }

    /// Pide tokens para una conexión nueva. Cada `open` exitoso exige un `release`.
    public func open() async throws -> BastionSessionTokens {
        active += 1
        do {
            // Token fresco por conexión: el proveedor renueva antes de `expires_on`.
            let token = try await azToken()
            let tokens = try await dataPlane.requestTokens(resourceID: resourceID, port: port, azToken: token, previous: current)
            current = tokens
            return tokens
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

    /// Ctrl+C: borra la sesión aunque queden conexiones (el CLI hace igual).
    @discardableResult
    public func shutdown() async -> DeleteOutcome? {
        active = 0
        return await deleteIfIdle()
    }

    @discardableResult
    private func deleteIfIdle() async -> DeleteOutcome? {
        guard active == 0, let tokens = current else { return nil }
        current = nil  // antes del await: un único DELETE por authToken
        lastDeleted = tokens
        do {
            return try await dataPlane.deleteTokens(tokens)
        } catch {
            log.warn("DELETE /api/tokens falló: \(error)")
            return nil
        }
    }
}
