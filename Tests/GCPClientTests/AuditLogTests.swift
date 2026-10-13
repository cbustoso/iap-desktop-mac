import Foundation
import Testing
@testable import GCPClient

private final class AuditLogStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var requestBody: Data?
    nonisolated(unsafe) static var response = "{}"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        Self.requestBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("Cloud Audit Logs", .serialized)
struct AuditLogTests {
    private func client() -> GCPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuditLogStubProtocol.self]
        return GCPClient(session: URLSession(configuration: configuration)) { "secret-token" }
    }

    @Test func postsExpectedInstanceFilterAndDecodesEvents() async throws {
        AuditLogStubProtocol.response = #"""
        {"entries":[{
          "insertId":"abc", "timestamp":"2026-10-13T12:34:56.123Z", "severity":"NOTICE",
          "protoPayload":{"methodName":"v1.compute.instances.start",
            "authenticationInfo":{"principalEmail":"ada@example.com"}}
        }]}
        """#
        let since = try #require(ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z"))
        let events = try await client().listInstanceEvents(
            project: "demo", zone: "us-central1-a", instance: "vm-1", since: since)

        let request = try #require(AuditLogStubProtocol.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://logging.googleapis.com/v2/entries:list")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        let body = try #require(AuditLogStubProtocol.requestBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["resourceNames"] as? [String] == ["projects/demo"])
        #expect(json["pageSize"] as? Int == 1_000)
        #expect(json["orderBy"] as? String == "timestamp desc")
        let filter = try #require(json["filter"] as? String)
        #expect(filter.contains("resource.type=\"gce_instance\""))
        #expect(filter.contains("resource.type=\"gce_project\""))
        #expect(filter.contains("resource.type=\"audited_resource\""))
        #expect(filter.contains("resource.labels.zone=\"us-central1-a\""))
        #expect(filter.contains("labels.instance_id=\"vm-1\""))
        #expect(filter.contains("timestamp>\"2026-10-12T00:00:00.000Z\""))
        #expect(events.count == 1)
        #expect(events.first?.id == "abc")
        #expect(events.first?.severity == "NOTICE")
        #expect(events.first?.description == "start")
        #expect(events.first?.user == "ada@example.com")
    }

    @Test func acceptsWholeSecondTimestampsAndDefaultsMissingFields() async throws {
        AuditLogStubProtocol.response = #"{"entries":[{"timestamp":"2026-10-13T12:34:56Z"}]}"#
        let events = try await client().listInstanceEvents(
            project: "p", zone: "z", instance: "i", since: .distantPast)
        #expect(events.count == 1)
        #expect(events.first?.severity == "DEFAULT")
        #expect(events.first?.description == "Audit log event")
    }
}
