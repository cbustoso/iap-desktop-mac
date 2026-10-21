// GH-90 (specs/azure/azure-bastion-research.md §2, §9.2): cliente REST de Azure
// Resource Manager. El token por tenant llega como closure (en la App,
// `AzureCredentialFacade.accessToken(tenantID:)`, es decir, el de `az`).
import Foundation
import OSLog

public enum AzureARMError: Error, Sendable, Equatable {
    /// Respuesta de error ARM (`{"error":{"code","message"}}`).
    case http(status: Int, code: String?, message: String?)
    /// 429/503 tras agotar los reintentos.
    case throttled(status: Int)
    case malformedResponse
    /// `nextLink` fuera del endpoint ARM: no se le manda el bearer.
    case invalidNextLink
    case invalidResourceID
    case network(String)
}

public struct AzureARMClient: Sendable {
    public typealias TokenProvider = @Sendable (_ tenantID: String) async throws -> String
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public static let defaultEndpoint = URL(string: "https://management.azure.com")!

    /// api-version por proveedor. Tenants/Subscriptions no publican una
    /// versión posterior a 2022-12-01 (la única en la referencia REST).
    public enum APIVersion {
        public static let tenants = "2022-12-01"
        public static let subscriptions = "2022-12-01"
        public static let resourceGroups = "2024-11-01"
        public static let compute = "2026-04-01"
        public static let network = "2026-01-01"
    }

    /// Tope de páginas por listado (defensa ante un `nextLink` que no acaba).
    static let maxPages = 1000

    private let endpoint: URL
    private let session: URLSession
    private let token: TokenProvider
    private let maxRetries: Int
    private let maxRetryDelay: Duration
    private let sleep: Sleeper
    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "azure.arm")

    public init(
        endpoint: URL = Self.defaultEndpoint,
        session: URLSession = .shared,
        maxRetries: Int = 3,
        maxRetryDelay: Duration = .seconds(30),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        token: @escaping TokenProvider
    ) {
        self.endpoint = endpoint
        self.session = session
        self.maxRetries = maxRetries
        self.maxRetryDelay = maxRetryDelay
        self.sleep = sleep
        self.token = token
    }

    // MARK: - Operaciones (§2)

    /// Tenants de la cuenta (`GET /tenants`). Vale cualquier token de la cuenta.
    public func tenants(homeTenantID: String) async throws -> [AzureTenant] {
        try await list("/tenants", apiVersion: APIVersion.tenants, tenantID: homeTenantID)
    }

    /// Suscripciones visibles con el token de `tenantID`.
    public func subscriptions(tenantID: String) async throws -> [AzureSubscription] {
        try await list("/subscriptions", apiVersion: APIVersion.subscriptions, tenantID: tenantID)
    }

    public func resourceGroups(subscriptionID: String, tenantID: String) async throws -> [AzureResourceGroup] {
        try await list("\(try Self.subscriptionPath(subscriptionID))/resourcegroups", apiVersion: APIVersion.resourceGroups, tenantID: tenantID)
    }

    /// Todas las VMs de la suscripción (una sola llamada paginada, no una por RG).
    public func virtualMachines(subscriptionID: String, tenantID: String) async throws -> [AzureVM] {
        try await list("\(try Self.subscriptionPath(subscriptionID))/providers/Microsoft.Compute/virtualMachines",
                       apiVersion: APIVersion.compute, tenantID: tenantID)
    }

    /// Estado de encendido de todas las VMs de la suscripción (`statusOnly=true`:
    /// una sola llamada paginada con el `instanceView` de cada VM).
    public func virtualMachineStatuses(subscriptionID: String, tenantID: String) async throws -> [AzureVMStatus] {
        try await list("\(try Self.subscriptionPath(subscriptionID))/providers/Microsoft.Compute/virtualMachines",
                       apiVersion: APIVersion.compute, tenantID: tenantID,
                       query: [URLQueryItem(name: "statusOnly", value: "true")])
    }

    /// Todas las NICs de la suscripción (IP privada + subnet de cada VM).
    public func networkInterfaces(subscriptionID: String, tenantID: String) async throws -> [AzureNIC] {
        try await list("\(try Self.subscriptionPath(subscriptionID))/providers/Microsoft.Network/networkInterfaces",
                       apiVersion: APIVersion.network, tenantID: tenantID)
    }

    public func bastionHosts(subscriptionID: String, tenantID: String) async throws -> [AzureBastion] {
        try await list("\(try Self.subscriptionPath(subscriptionID))/providers/Microsoft.Network/bastionHosts",
                       apiVersion: APIVersion.network, tenantID: tenantID)
    }

    /// Un Bastion por ID (equivale a `az network bastion show`).
    public func bastionHost(id: String, tenantID: String) async throws -> AzureBastion {
        guard ARMResourceID.isValidPath(id) else { throw AzureARMError.invalidResourceID }
        let data = try await get(url(path: id, apiVersion: APIVersion.network), tenantID: tenantID)
        guard let bastion = try? JSONDecoder().decode(AzureBastion.self, from: data) else { throw AzureARMError.malformedResponse }
        return bastion
    }

    // MARK: - Paginación

    private struct Page<T: Decodable>: Decodable {
        let value: [T]
        let nextLink: String?
    }

    /// Sigue `nextLink` tal cual (ya trae `api-version` y `$skiptoken`) mientras
    /// apunte al mismo endpoint ARM.
    func list<T: Decodable>(_ path: String, apiVersion: String, tenantID: String, query: [URLQueryItem] = []) async throws -> [T] {
        var next: URL? = url(path: path, apiVersion: apiVersion, query: query)
        var items: [T] = []
        var seen = Set<String>()
        var pages = 0
        while let current = next {
            guard seen.insert(current.absoluteString).inserted, pages < Self.maxPages else { throw AzureARMError.invalidNextLink }
            pages += 1
            let data = try await get(current, tenantID: tenantID)
            guard let page = try? JSONDecoder().decode(Page<T>.self, from: data) else { throw AzureARMError.malformedResponse }
            items += page.value
            next = try page.nextLink.flatMap { $0.isEmpty ? nil : try validatedNextLink($0) }
        }
        return items
    }

    func validatedNextLink(_ link: String) throws -> URL {
        guard let url = URL(string: link), url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port
        else { throw AzureARMError.invalidNextLink }
        return url
    }

    private func url(path: String, apiVersion: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = [URLQueryItem(name: "api-version", value: apiVersion)] + query
        return components.url!
    }

    static func subscriptionPath(_ subscriptionID: String) throws -> String {
        guard UUID(uuidString: subscriptionID) != nil else { throw AzureARMError.invalidResourceID }
        return "/subscriptions/\(subscriptionID)"
    }

    // MARK: - Transporte con throttling

    private func get(_ url: URL, tenantID: String) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(try await token(tenantID))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw AzureARMError.network((error as? URLError).map { "URLError \($0.code.rawValue)" } ?? String(describing: type(of: error)))
            }
            guard let http = response as? HTTPURLResponse else { throw AzureARMError.malformedResponse }
            if http.statusCode == 200 { return data }
            if [429, 503].contains(http.statusCode) {
                guard attempt < maxRetries else { throw AzureARMError.throttled(status: http.statusCode) }
                let delay = retryDelay(http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)
                Self.log.notice("arm throttled http=\(http.statusCode, privacy: .public) retry=\(attempt + 1, privacy: .public)")
                attempt += 1
                try await sleep(delay)
                continue
            }
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            Self.log.error("arm error http=\(http.statusCode, privacy: .public) code=\(body?.error?.code ?? "-", privacy: .public)")
            throw AzureARMError.http(status: http.statusCode, code: body?.error?.code, message: body?.error?.message)
        }
    }

    /// `Retry-After` en segundos (ARM no manda fechas HTTP); sin cabecera,
    /// backoff exponencial 1, 2, 4 s. Siempre acotado a `maxRetryDelay`.
    func retryDelay(_ header: String?, attempt: Int) -> Duration {
        let requested = header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { Duration.seconds(max(0, $0)) }
        return min(requested ?? .seconds(1 << min(attempt, 5)), maxRetryDelay)
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String?
            let message: String?
        }
        let error: Detail?
    }
}
