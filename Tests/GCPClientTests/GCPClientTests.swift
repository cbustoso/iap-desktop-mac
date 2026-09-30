import Foundation
import Testing
@testable import GCPClient

final class GCPStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? fallbackResponse(status: 500)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func fallbackResponse(status: Int) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
    }
}

private func stubbedSession(
    handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    GCPStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GCPStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func response(
    for request: URLRequest, status: Int = 200, json: String = "{}"
) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!,
        Data(json.utf8)
    )
}

private func client(session: URLSession) -> GCPClient {
    GCPClient(session: session) { "test-token" }
}

@Suite("GCPClient", .serialized)
struct GCPClientTests {
    @Test func listProjectsPaginates() async throws {
        var requestedPageTokens: [String?] = []
        let session = stubbedSession { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let pageToken = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageToken" })?.value
            requestedPageTokens.append(pageToken)
            if pageToken == nil {
                return response(for: request, json: """
                    {"projects":[{"projectId":"project-a","name":"Alpha"}],"nextPageToken":"page-2"}
                    """)
            }
            return response(for: request, json: """
                {"projects":[{"projectId":"project-b","displayName":"Beta"}]}
                """)
        }

        let projects = try await client(session: session).listProjects()

        #expect(projects == [
            GCPProject(projectId: "project-a", displayName: "Alpha"),
            GCPProject(projectId: "project-b", displayName: "Beta"),
        ])
        #expect(requestedPageTokens.count == 2)
        #expect(requestedPageTokens[0] == nil)
        #expect(requestedPageTokens[1] == "page-2")
    }

    @Test func aggregatedListParsesInstancesAcrossZones() async throws {
        let session = stubbedSession { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.contains(URLQueryItem(name: "returnPartialSuccess", value: "true")) == true)
            #expect(query?.contains(URLQueryItem(name: "includeAllScopes", value: "false")) == true)
            return response(for: request, json: """
                {"items":{
                  "zones/us-central1-a":{"instances":[{
                    "name":"linux-vm","zone":"https://compute.googleapis.com/compute/v1/projects/p/zones/us-central1-a",
                    "status":"RUNNING","disks":[{"licenses":["projects/debian-cloud/global/licenses/debian-12"]}],
                    "guestOsFeatures":[{"type":"GVNIC"}]
                  }]},
                  "zones/us-central1-b":{"instances":[{
                    "name":"windows-vm","zone":"zones/us-central1-b","status":"TERMINATED",
                    "disks":[{"licenses":["projects/windows-cloud/global/licenses/windows-server-2022-dc"]}],
                    "guestOsFeatures":[]
                  }]}
                }}
                """)
        }

        let instances = try await client(session: session).aggregatedListInstances(project: "p")

        #expect(instances.map(\.name) == ["linux-vm", "windows-vm"])
        #expect(instances.map(\.zone) == ["us-central1-a", "us-central1-b"])
        #expect(instances.map(\.status) == [.running, .stopped])
        #expect(instances.map(\.operatingSystem) == [.linux, .windows])
    }

    @Test(arguments: [403, 404])
    func inaccessibleProjectReturnsEmpty(status: Int) async throws {
        let session = stubbedSession { request in response(for: request, status: status) }
        let instances = try await client(session: session).aggregatedListInstances(project: "denied")
        #expect(instances.isEmpty)
    }

    @Test func warningScopeIsIgnored() async throws {
        let session = stubbedSession { request in
            response(for: request, json: """
                {"items":{
                  "zones/us-central1-a":{"warning":{"code":"NO_RESULTS_ON_PAGE","message":"No results"}},
                  "zones/us-central1-b":{"instances":[]}
                }}
                """)
        }

        let instances = try await client(session: session).aggregatedListInstances(project: "p")
        #expect(instances.isEmpty)
    }
}
