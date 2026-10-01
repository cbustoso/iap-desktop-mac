import Foundation

public enum GCPClientError: Error, Equatable, Sendable {
    case invalidResponse
    /// Error HTTP de una API de Google. `reason` es el motivo de la API
    /// (`details[].reason` o `status`, p. ej. `SERVICE_DISABLED`), si el
    /// cuerpo lo traía. Permite distinguir "API sin habilitar" de "sin permiso".
    case apiError(status: Int, reason: String?)
}

/// Error HTTP de una API de Google con el detalle que da el cuerpo, para
/// diagnosticar el discovery (CBU-47b). Lo lanza `listProjects`; el resto de
/// llamadas siguen lanzando `GCPClientError.apiError`. Sin datos de cuenta:
/// `message` se sanea (sin emails, una línea, acotado).
public struct GoogleAPIFailure: Error, Equatable, Sendable {
    public enum Cause: String, Sendable {
        /// API apagada en el proyecto que paga la cuota (el del cliente OAuth).
        case serviceDisabled = "api-disabled"
        /// El token no lleva el scope que pide la API.
        case scopeInsufficient = "scope"
        /// Bloqueado por un perímetro de VPC Service Controls.
        case vpcServiceControls = "vpc-sc"
        /// 403 por IAM / política de organización.
        case permissionDenied = "iam"
        /// 401: credenciales rechazadas.
        case unauthenticated = "unauthorized"
        case other = "http"
    }

    public let status: Int
    /// `details[].reason` o `error.status` (p. ej. `SERVICE_DISABLED`).
    public let reason: String?
    /// `error.message` saneado.
    public let message: String?
    /// `details[].metadata.activationUrl` (solo con `SERVICE_DISABLED`).
    public let activationURL: URL?

    public init(status: Int, reason: String?, message: String? = nil, activationURL: URL? = nil) {
        self.status = status
        self.reason = reason
        self.message = message
        self.activationURL = activationURL
    }

    /// Lee `{"error":{"message":…,"status":…,"details":[{"reason":…,"metadata":{…}}]}}`.
    public init(status: Int, body: Data) {
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]] ?? []
        let activation = details
            .compactMap { ($0["metadata"] as? [String: Any])?["activationUrl"] as? String }
            .first
            .flatMap(URL.init(string:))
        self.init(
            status: status,
            reason: GCPClient.denyReason(from: body),
            message: (error?["message"] as? String).flatMap(Self.sanitized),
            activationURL: activation?.scheme == "https" ? activation : nil)
    }

    public var cause: Cause {
        switch (status, reason) {
        case (401, _): return .unauthenticated
        case (403, "SERVICE_DISABLED"), (403, "API_DISABLED"): return .serviceDisabled
        case (403, "ACCESS_TOKEN_SCOPE_INSUFFICIENT"): return .scopeInsufficient
        case (403, "SECURITY_POLICY_VIOLATED"), (403, "VPC_SERVICE_CONTROLS"): return .vpcServiceControls
        case (403, _): return .permissionDenied
        default: return .other
        }
    }

    /// Fragmento público para OSLog.
    public var logDescription: String {
        "cause=\(cause.rawValue) http=\(status) reason=\(reason ?? "-") message=\"\(message ?? "-")\""
    }

    /// Una línea, sin emails (REQ-AUTH-6) y como mucho 300 caracteres.
    static func sanitized(_ message: String) -> String? {
        let line = message
            .replacingOccurrences(of: #"[^\s@"'<>()]+@([A-Za-z0-9.-]+)"#, with: "…@$1", options: .regularExpression)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}

/// Minimal client for the Resource Manager and Compute APIs used by Explorer.
public struct GCPClient: Sendable {
    private let session: URLSession
    private let tokenProvider: @Sendable () async throws -> String

    public init(
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    /// Proyectos visibles (v1 `projects.list`, todas las páginas). Un error
    /// HTTP se lanza como `GoogleAPIFailure`, con el detalle del cuerpo.
    public func listProjects() async throws -> [GCPProject] {
        var projects: [GCPProject] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
            if let pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
            }

            let response = try JSONDecoder().decode(
                ProjectListResponse.self, from: try await fetch("GET", components.url!, body: nil))
            projects.append(contentsOf: response.projects ?? [])
            pageToken = response.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while pageToken != nil

        return projects
    }

    public func aggregatedListInstances(project: String) async throws -> [ComputeInstance] {
        let escapedProject = project.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? project
        var components = URLComponents(
            string: "https://compute.googleapis.com/compute/v1/projects/\(escapedProject)/aggregated/instances")!
        components.queryItems = [
            URLQueryItem(name: "returnPartialSuccess", value: "true"),
            URLQueryItem(name: "includeAllScopes", value: "false"),
        ]

        do {
            let response: AggregatedInstanceListResponse = try await get(components.url!)
            return (response.items ?? [:])
                .sorted { $0.key < $1.key }
                .flatMap { _, scopedList in scopedList.instances ?? [] }
        } catch GCPClientError.apiError(let status, _) where status == 403 || status == 404 {
            return []
        }
    }

    func get<Response: Decodable>(_ url: URL) async throws -> Response {
        try await send("GET", url, body: Optional<Data>.none)
    }

    /// Petición autenticada con cuerpo JSON opcional. El token nunca se registra.
    func send<Response: Decodable>(_ method: String, _ url: URL, body: Data?) async throws -> Response {
        let data: Data
        do {
            data = try await fetch(method, url, body: body)
        } catch let failure as GoogleAPIFailure {
            throw GCPClientError.apiError(status: failure.status, reason: failure.reason)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// Cuerpo de una respuesta 2xx; si no, `GoogleAPIFailure`.
    func fetch(_ method: String, _ url: URL, body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GCPClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GoogleAPIFailure(status: httpResponse.statusCode, body: data)
        }
        return data
    }

    /// Motivo de un error de API de Google (`{"error":{"status":…,
    /// `"details":[{"reason":…}]}}`), o `nil` si el cuerpo no lo dice.
    static func denyReason(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return nil }
        if let details = error["details"] as? [[String: Any]],
           let reason = details.compactMap({ $0["reason"] as? String }).first,
           !reason.isEmpty {
            return reason
        }
        if let status = error["status"] as? String, !status.isEmpty { return status }
        return nil
    }
}
