import Foundation
import Testing
@testable import GCPClient

private final class VmControlStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, json) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var all: [URLRequest] { lock.withLock { requests } }

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private func vmClient(_ handler: @escaping VmControlStubProtocol.Handler) -> GCPClient {
    VmControlStubProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VmControlStubProtocol.self]
    return GCPClient(session: URLSession(configuration: configuration)) { "test-token" }
}

@Suite("Control de VMs", .serialized)
struct VmControlTests {
    @Test func everyActionPostsToItsComputeEndpoint() async throws {
        let requests = RequestLog()
        let client = vmClient { request in
            requests.append(request)
            return (200, #"{"name":"op-1","status":"DONE"}"#)
        }

        try await client.start(project: "demo project", zone: "us-central1-a", instance: "vm/one")
        try await client.stop(project: "demo project", zone: "us-central1-a", instance: "vm/one")
        try await client.reset(project: "demo project", zone: "us-central1-a", instance: "vm/one")
        try await client.suspend(project: "demo project", zone: "us-central1-a", instance: "vm/one")
        try await client.resume(project: "demo project", zone: "us-central1-a", instance: "vm/one")

        #expect(requests.all.map(\.httpMethod) == Array(repeating: "POST", count: 5))
        #expect(requests.all.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
        } == [
            "/compute/v1/projects/demo%20project/zones/us-central1-a/instances/vm%2Fone/start",
            "/compute/v1/projects/demo%20project/zones/us-central1-a/instances/vm%2Fone/stop",
            "/compute/v1/projects/demo%20project/zones/us-central1-a/instances/vm%2Fone/reset",
            "/compute/v1/projects/demo%20project/zones/us-central1-a/instances/vm%2Fone/suspend",
            "/compute/v1/projects/demo%20project/zones/us-central1-a/instances/vm%2Fone/resume",
        ])
        #expect(requests.all.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        })
    }

    @Test func pollsPendingOperationUntilDone() async throws {
        let requests = RequestLog()
        let polls = PollCounter()
        let client = vmClient { request in
            requests.append(request)
            if request.httpMethod == "POST" {
                return (200, #"{"name":"operation-42","status":"PENDING"}"#)
            }
            let status = polls.next() == 1 ? "PENDING" : "DONE"
            return (200, "{\"name\":\"operation-42\",\"status\":\"\(status)\"}")
        }

        try await client.stop(project: "p", zone: "z", instance: "i")

        #expect(requests.all.map(\.httpMethod) == ["POST", "GET", "GET"])
        #expect(requests.all.dropFirst().allSatisfy {
            $0.url?.path == "/compute/v1/projects/p/zones/z/operations/operation-42"
        })
    }

    @Test func forbiddenActionSurfacesTypedStatus() async {
        let client = vmClient { _ in (403, #"{"error":{"code":403}}"#) }

        await #expect(throws: GCPClientError.httpStatus(403)) {
            try await client.reset(project: "p", zone: "z", instance: "i")
        }
    }
}
