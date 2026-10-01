import Foundation
import Testing
@testable import GCPClient

final class GCPStubURLProtocol: URLProtocol, @unchecked Sendable {
    // @Sendable obligatorio: CFNetwork ejecuta el handler fuera del actor
    // que lo creó; sin esto, trap SE-0423 (ver fix T-EXP-2 en ExplorerUITests).
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    nonisolated(unsafe) static var handler: Handler?

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
    handler: @Sendable @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
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
        // El handler es @Sendable (fix SE-0423): la recolección usa lock.
        // Lectura posterior al await: sincronizada por el propio await.
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var tokens: [String?] = []
            func append(_ token: String?) {
                lock.withLock { tokens.append(token) }
            }
        }
        let requestedPageTokens = Collector()
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
        #expect(requestedPageTokens.tokens.count == 2)
        #expect(requestedPageTokens.tokens[0] == nil)
        #expect(requestedPageTokens.tokens[1] == "page-2")
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

    @Test func denyReasonReadsDetailsFirst() {
        #expect(GCPClient.denyReason(from: Data("""
            {"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"@type":"t","reason":"SERVICE_DISABLED"}]}}
            """.utf8)) == "SERVICE_DISABLED")
        #expect(GCPClient.denyReason(from: Data("""
            {"error":{"code":403,"status":"PERMISSION_DENIED"}}
            """.utf8)) == "PERMISSION_DENIED")
        #expect(GCPClient.denyReason(from: Data("{}".utf8)) == nil)
        #expect(GCPClient.denyReason(from: Data("no-json".utf8)) == nil)
    }

    @Test func forbiddenCarriesReason() async throws {
        let session = stubbedSession { request in
            response(for: request, status: 403, json: """
                {"error":{"code":403,"details":[{"reason":"SERVICE_DISABLED"}]}}
                """)
        }
        await #expect(throws: GoogleAPIFailure(status: 403, reason: "SERVICE_DISABLED")) {
            try await client(session: session).listProjects()
        }
    }

    // CBU-47b: cuerpo real de Google cuando Resource Manager está apagado en
    // el proyecto del cliente OAuth (la cuota de projects.list se le cobra a él).
    @Test func listProjectsServiceDisabledKeepsMessageAndActivationURL() async throws {
        let session = stubbedSession { request in
            response(for: request, status: 403, json: serviceDisabledBody)
        }
        do {
            _ = try await client(session: session).listProjects()
            Issue.record("se esperaba GoogleAPIFailure")
        } catch let failure as GoogleAPIFailure {
            #expect(failure.status == 403)
            #expect(failure.reason == "SERVICE_DISABLED")
            #expect(failure.cause == .serviceDisabled)
            #expect(failure.message?.hasPrefix("Cloud Resource Manager API has not been used in project 123") == true)
            #expect(failure.activationURL?.absoluteString
                == "https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=123")
            #expect(failure.logDescription.hasPrefix("cause=api-disabled http=403 reason=SERVICE_DISABLED message=\""))
        }
    }

    @Test func listProjectsSendsBearerToken() async throws {
        let session = stubbedSession { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.url?.absoluteString == "https://cloudresourcemanager.googleapis.com/v1/projects")
            return response(for: request, json: #"{"projects":[]}"#)
        }
        #expect(try await client(session: session).listProjects().isEmpty)
    }

    @Test func failureCauses() {
        func cause(_ status: Int, _ json: String) -> GoogleAPIFailure.Cause {
            GoogleAPIFailure(status: status, body: Data(json.utf8)).cause
        }
        #expect(cause(403, #"{"error":{"details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#) == .scopeInsufficient)
        #expect(cause(403, #"{"error":{"details":[{"reason":"SECURITY_POLICY_VIOLATED"}]}}"#) == .vpcServiceControls)
        #expect(cause(403, #"{"error":{"status":"PERMISSION_DENIED"}}"#) == .permissionDenied)
        #expect(cause(403, "no-json") == .permissionDenied)
        #expect(cause(401, "{}") == .unauthenticated)
        #expect(cause(500, "{}") == .other)
    }

    @Test func failureMessageIsSanitized() {
        let failure = GoogleAPIFailure(status: 403, body: Data("""
            {"error":{"message":"Caller ada.lovelace@example.com lacks\\npermission","details":[{"metadata":{"activationUrl":"javascript:alert(1)"}}]}}
            """.utf8))
        #expect(failure.message == "Caller …@example.com lacks permission")
        #expect(failure.activationURL == nil)  // solo https
        #expect(!failure.logDescription.contains("ada.lovelace"))
        #expect(GoogleAPIFailure.sanitized(String(repeating: "x", count: 400))?.count == 301)
        #expect(GoogleAPIFailure.sanitized(" \n ") == nil)
    }

    @Test func otherCallsStillThrowAPIError() async throws {
        let session = stubbedSession { request in
            response(for: request, status: 500, json: #"{"error":{"status":"INTERNAL","message":"boom"}}"#)
        }
        await #expect(throws: GCPClientError.apiError(status: 500, reason: "INTERNAL")) {
            try await client(session: session).aggregatedListInstances(project: "p")
        }
    }
}

private let serviceDisabledBody = """
    {"error":{"code":403,"message":"Cloud Resource Manager API has not been used in project 123 before or it is disabled. \
    Enable it by visiting https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=123 \
    then retry.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo",\
    "reason":"SERVICE_DISABLED","domain":"googleapis.com","metadata":{"consumer":"projects/123",\
    "service":"cloudresourcemanager.googleapis.com",\
    "activationUrl":"https://console.developers.google.com/apis/api/cloudresourcemanager.googleapis.com/overview?project=123"}}]}}
    """
