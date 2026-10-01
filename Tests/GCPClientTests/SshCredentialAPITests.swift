// CBU-44: APIs de Compute/OS Login para llaves SSH efímeras.
import Foundation
import Testing
@testable import GCPClient

/// Stub HTTP con handler `@Sendable` (CFNetwork lo llama en su propio hilo).
private final class CredentialStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, json) = Self.handler?(request, body) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Registro de peticiones. `@unchecked Sendable`: bajo `lock`.
private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(method: String, url: URL, body: String, auth: String?)] = []
    var all: [(method: String, url: URL, body: String, auth: String?)] { lock.withLock { entries } }
    func add(_ request: URLRequest, _ body: Data?) {
        lock.withLock {
            entries.append((request.httpMethod ?? "", request.url!, String(decoding: body ?? Data(), as: UTF8.self),
                            request.value(forHTTPHeaderField: "Authorization")))
        }
    }
}

private func client(_ handler: @escaping CredentialStubProtocol.Handler) -> GCPClient {
    CredentialStubProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CredentialStubProtocol.self]
    return GCPClient(session: URLSession(configuration: configuration)) { "ya29.secret" }
}

@Suite("Credenciales SSH: Compute/OS Login", .serialized)
struct SshCredentialAPITests {
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T20:00:00Z")!

    @Test func ephemeralKeyLineFormatAndPruning() {
        let metadata = ComputeMetadata(fingerprint: "fp", items: [
            .init(key: "startup-script", value: "echo hi"),
            .init(key: "ssh-keys", value: """
                ana:ssh-ed25519 AAAAfijo ana@laptop
                old:ecdsa-sha2-nistp256 AAAAvieja google-ssh {"userName":"old@x.com","expireOn":"2026-09-30T19:00:00Z"}
                """),
        ])
        let updated = metadata.addingEphemeralSSHKey(
            username: "ada", publicKeyOpenSSH: "ecdsa-sha2-nistp256 AAAAnueva comentario",
            email: "ada@example.com", expiresAt: now.addingTimeInterval(1800), now: now)
        let lines = updated.value(for: "ssh-keys")!.split(separator: "\n").map(String.init)
        #expect(lines == [
            "ana:ssh-ed25519 AAAAfijo ana@laptop",  // llaves no efímeras se conservan
            #"ada:ecdsa-sha2-nistp256 AAAAnueva google-ssh {"userName":"ada@example.com","expireOn":"2026-09-30T20:30:00Z"}"#,
        ])
        #expect(updated.value(for: "startup-script") == "echo hi")
        #expect(updated.fingerprint == "fp")
    }

    @Test func osLoginPrecedenceInstanceOverProject() {
        func md(_ pairs: [String: String]) -> ComputeMetadata {
            ComputeMetadata(items: pairs.map { .init(key: $0.key, value: $0.value) })
        }
        #expect(OsLoginPolicy(instance: md([:]), project: md(["enable-oslogin": "TRUE"])).enabled)
        #expect(!OsLoginPolicy(instance: md(["enable-oslogin": "false"]), project: md(["enable-oslogin": "TRUE"])).enabled)
        #expect(!OsLoginPolicy(instance: md([:]), project: md([:])).enabled)
        let sk = OsLoginPolicy(instance: md(["enable-oslogin": "true", "enable-oslogin-sk": "TRUE"]), project: md([:]))
        #expect(sk.enabled && sk.requiresSecurityKey)
        let skWithoutOsLogin = OsLoginPolicy(instance: md(["enable-oslogin-sk": "TRUE"]), project: md([:]))
        #expect(!skWithoutOsLogin.requiresSecurityKey)
    }

    @Test func readAndWriteInstanceMetadata() async throws {
        let requests = Requests()
        let gcp = client { request, body in
            requests.add(request, body)
            if request.httpMethod == "GET" {
                return (200, #"{"metadata":{"fingerprint":"abc=","items":[{"key":"enable-oslogin","value":"TRUE"}]}}"#)
            }
            return (200, #"{"name":"operation-1"}"#)
        }
        let metadata = try await gcp.instanceMetadata(project: "demo-web", zone: "europe-west1-b", instance: "web-01")
        #expect(metadata.fingerprint == "abc=")
        #expect(metadata.flag("enable-oslogin") == true)

        try await gcp.setInstanceMetadata(project: "demo-web", zone: "europe-west1-b", instance: "web-01", metadata)
        let calls = requests.all
        #expect(calls.map(\.method) == ["GET", "POST"])
        #expect(calls[0].url.path == "/compute/v1/projects/demo-web/zones/europe-west1-b/instances/web-01")
        #expect(calls[1].url.path.hasSuffix("/instances/web-01/setMetadata"))
        #expect(calls[1].body.contains(#""fingerprint":"abc=""#))
        // El token solo viaja en la cabecera, nunca en URL ni cuerpo.
        #expect(calls.allSatisfy { $0.auth == "Bearer ya29.secret" })
        #expect(calls.allSatisfy { !$0.url.absoluteString.contains("ya29") && !$0.body.contains("ya29") })
    }

    @Test func importOsLoginKeyReturnsPrimaryPosixUser() async throws {
        let requests = Requests()
        let gcp = client { request, body in
            requests.add(request, body)
            return (200, #"{"loginProfile":{"posixAccounts":[{"username":"secondary","primary":false},{"username":"ext_ada_example_com","primary":true}]}}"#)
        }
        let username = try await gcp.importOsLoginKey(
            email: "ada@example.com", project: "demo-web",
            publicKeyOpenSSH: "ecdsa-sha2-nistp256 AAAAkey", expiresAt: now)
        #expect(username == "ext_ada_example_com")
        let call = try #require(requests.all.first)
        #expect(call.method == "POST")
        #expect(call.url.host == "oslogin.googleapis.com")
        #expect(call.url.path == "/v1/users/ada@example.com:importSshPublicKey")
        #expect(call.url.query == "projectId=demo-web")
        #expect(call.body.contains(#""key":"ecdsa-sha2-nistp256 AAAAkey""#))
        #expect(call.body.contains(#""expirationTimeUsec":"\#(Int64(now.timeIntervalSince1970 * 1_000_000))""#))
    }

    @Test func forbiddenSetMetadataSurfacesStatus() async {
        let gcp = client { _, _ in (403, #"{"error":{"code":403}}"#) }
        await #expect(throws: GCPClientError.apiError(status: 403, reason: nil)) {
            try await gcp.setInstanceMetadata(project: "p", zone: "z", instance: "i", ComputeMetadata())
        }
    }
}
