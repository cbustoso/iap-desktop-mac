import Foundation

public enum GCPClientError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
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
        } catch GCPClientError.httpStatus(let status) where status == 403 || status == 404 {
            return []
        }
    }

    private func get<Response: Decodable>(_ url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GCPClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw GCPClientError.httpStatus(httpResponse.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
