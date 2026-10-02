import Foundation
import Testing
@testable import GCPClient

private final class SerialPortStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SerialRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var all: [URLRequest] { lock.withLock { requests } }
    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
}

private func serialClient(_ handler: @escaping SerialPortStubProtocol.Handler) -> GCPClient {
    SerialPortStubProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SerialPortStubProtocol.self]
    return GCPClient(session: URLSession(configuration: configuration)) { "private-token" }
}

@Suite("Serial port output", .serialized)
struct SerialPortTests {
    @Test func requestsPortAndUsesNextAsFollowingStart() async throws {
        let log = SerialRequestLog()
        let client = serialClient { request in
            log.append(request)
            let count = log.all.count
            return count == 1
                ? (200, #"{"contents":"boot\n","next":"418"}"#)
                : (200, #"{"contents":"ready\n","next":"427"}"#)
        }

        let first = try await client.getSerialPortOutput(
            project: "demo project", zone: "us/central", instance: "vm one", port: 3)
        let second = try await client.getSerialPortOutput(
            project: "demo project", zone: "us/central", instance: "vm one", port: 3,
            start: first.next)

        #expect(first == SerialPortOutputChunk(contents: "boot\n", next: "418"))
        #expect(second == SerialPortOutputChunk(contents: "ready\n", next: "427"))
        #expect(log.all.count == 2)
        #expect(log.all.allSatisfy { $0.httpMethod == "GET" })
        #expect(log.all.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer private-token"
        })
        #expect(log.all.map { $0.url?.path } == [
            "/compute/v1/projects/demo project/zones/us/central/instances/vm one/serialPort",
            "/compute/v1/projects/demo project/zones/us/central/instances/vm one/serialPort",
        ])
        let queries = log.all.map { request in
            Dictionary(uniqueKeysWithValues: URLComponents(
                url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map {
                    ($0.name, $0.value ?? "")
                })
        }
        #expect(queries == [["port": "3"], ["port": "3", "start": "418"]])
    }

    @Test func absentFieldsBecomeEmptyOutputWithoutCursor() async throws {
        let client = serialClient { _ in (200, "{}") }
        let output = try await client.getSerialPortOutput(
            project: "p", zone: "z", instance: "i", port: 1)
        #expect(output == SerialPortOutputChunk(contents: "", next: nil))
    }

    @Test func rejectsPortsOutsideGoogleRangeWithoutRequest() async {
        let log = SerialRequestLog()
        let client = serialClient { request in
            log.append(request)
            return (200, "{}")
        }

        await #expect(throws: GCPClientError.invalidResponse) {
            try await client.getSerialPortOutput(project: "p", zone: "z", instance: "i", port: 0)
        }
        await #expect(throws: GCPClientError.invalidResponse) {
            try await client.getSerialPortOutput(project: "p", zone: "z", instance: "i", port: 5)
        }
        #expect(log.all.isEmpty)
    }

    @Test func apiFailureKeepsTypedStatusAndDoesNotExposeToken() async {
        let client = serialClient { request in
            #expect(request.url?.absoluteString.contains("private-token") == false)
            return (403, #"{"error":{"status":"PERMISSION_DENIED"}}"#)
        }
        await #expect(throws: GCPClientError.apiError(status: 403, reason: "PERMISSION_DENIED")) {
            try await client.getSerialPortOutput(project: "p", zone: "z", instance: "i", port: 1)
        }
    }
}
