import Foundation

public enum GCPClientError: Error, Equatable, Sendable {
    case invalidResponse
    /// Error HTTP de una API de Google. `reason` es el motivo de la API
    /// (`details[].reason` o `status`, p. ej. `SERVICE_DISABLED`), si el
    /// cuerpo lo traía. Permite distinguir "API sin habilitar" de "sin permiso".
    case apiError(status: Int, reason: String?)
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

    public func listProjects() async throws -> [GCPProject] {
        var projects: [GCPProject] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(
                string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
            if let pageToken {
                components.queryItems = [URLQueryItem(name: "pageToken", value: pageToken)]
            }

            let response: ProjectListResponse = try await get(components.url!)
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
            throw GCPClientError.apiError(
                status: httpResponse.statusCode, reason: Self.denyReason(from: data))
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
