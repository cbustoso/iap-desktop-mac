import Foundation
import Security
import Testing
@testable import GCPClient

// CBU-52 (T-RDP-8): reset de credenciales Windows contra un agente GCE
// simulado: lee la llave pública publicada en `windows-keys`, cifra la
// contraseña con OAEP y la "escribe" en el puerto serie 4.

/// Stub propio (handler estático separado del de GCPClientTests).
private final class WindowsStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, String)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, json) = Self.handler?(request, Self.body(of: request)) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Agente GCE simulado + registro de peticiones. `@unchecked`: bajo `lock`.
private final class FakeAgent: @unchecked Sendable {
    enum Reply { case password(String, hash: String), error(String), silent }

    private let lock = NSLock()
    private var serial = ""
    private(set) var requests: [(method: String, path: String, query: String?)] = []
    private(set) var publishedPayload: [String: Any]?
    private(set) var publishedMetadata: [String: Any]?
    var grantsSetMetadata = true
    var reply = Reply.password("S3cr3t!pw", hash: "sha256")
    /// Respuestas 4xx forzadas para `setMetadata` (en orden).
    var setMetadataFailures: [(Int, String)] = []
    /// Trocea la respuesta del agente en dos lecturas (línea incompleta).
    var splitResponse = true

    func handle(_ request: URLRequest, _ body: Data?) -> (Int, String) {
        lock.withLock {
            let url = request.url!
            requests.append((request.httpMethod ?? "GET", url.path, url.query))
            if url.path.hasSuffix("/testIamPermissions") {
                return (200, grantsSetMetadata ? #"{"permissions":["compute.instances.setMetadata"]}"# : "{}")
            }
            if url.path.hasSuffix("/setMetadata") {
                if !setMetadataFailures.isEmpty {
                    let (status, json) = setMetadataFailures.removeFirst()
                    return (status, json)
                }
                let metadata = try! JSONSerialization.jsonObject(with: body!) as! [String: Any]
                publishedMetadata = metadata
                let items = metadata["items"] as! [[String: Any]]
                let value = items.first { $0["key"] as? String == "windows-keys" }!["value"] as! String
                let payload = try! JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
                publishedPayload = payload
                serial += "noise: booting\n"
                serial += agentLine(for: payload)
                return (200, #"{"name":"op-1"}"#)
            }
            if url.path.hasSuffix("/serialPort") {
                let start = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "start" }?.value.flatMap(Int.init) ?? 0
                let available = Array(serial.utf8)
                // Lecturas en trozos de 40 bytes para forzar líneas partidas.
                let chunkEnd = splitResponse ? min(available.count, start + 40) : available.count
                let chunk = start < chunkEnd ? String(decoding: available[start..<chunkEnd], as: UTF8.self) : ""
                let output = ["contents": chunk, "start": String(start), "next": String(max(start, chunkEnd))]
                return (200, String(decoding: try! JSONSerialization.data(withJSONObject: output), as: UTF8.self))
            }
            // GET instancia: metadata existente con fingerprint y otra clave.
            return (200, #"{"metadata":{"fingerprint":"fp-1","items":[{"key":"startup","value":"x"},{"key":"windows-keys","value":"old"}]}}"#)
        }
    }

    private func agentLine(for payload: [String: Any]) -> String {
        let modulus = payload["modulus"] as! String
        switch reply {
        case .silent:
            return ""
        case .error(let message):
            return #"{"modulus":"\#(modulus.replacingOccurrences(of: "/", with: "\\/"))","errorMessage":"\#(message)"}"# + "\n"
        case .password(let password, let hash):
            let key = Self.publicKey(modulus: Data(base64Encoded: modulus)!,
                                     exponent: Data(base64Encoded: payload["exponent"] as! String)!)
            let algorithm: SecKeyAlgorithm = hash == "sha256" ? .rsaEncryptionOAEPSHA256 : .rsaEncryptionOAEPSHA1
            let cipher = SecKeyCreateEncryptedData(key, algorithm, Data(password.utf8) as CFData, nil)! as Data
            // El agente escapa "/" en JSON (paridad: el original normaliza "\/").
            let escapedModulus = modulus.replacingOccurrences(of: "/", with: "\\/")
            return #"{"ready":true,"modulus":"\#(escapedModulus)","encryptedPassword":"\#(cipher.base64EncodedString())","hashFunction":"\#(hash)"}"# + "\n"
        }
    }

    /// Reconstruye la llave pública desde módulo/exponente (DER PKCS#1).
    static func publicKey(modulus: Data, exponent: Data) -> SecKey {
        func integer(_ bytes: Data) -> [UInt8] {
            var value = [UInt8](bytes)
            if let first = value.first, first & 0x80 != 0 { value.insert(0, at: 0) }
            return [0x02] + length(value.count) + value
        }
        func length(_ count: Int) -> [UInt8] {
            count < 0x80 ? [UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30] + length(body.count) + body)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048,
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)!
    }
}

private func client(_ agent: FakeAgent) -> GCPClient {
    WindowsStubURLProtocol.handler = { agent.handle($0, $1) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WindowsStubURLProtocol.self]
    return GCPClient(session: URLSession(configuration: configuration)) { "test-token" }
}

private func reset(_ agent: FakeAgent, timeout: Duration = .seconds(10)) async throws -> WindowsCredential {
    try await client(agent).resetWindowsCredentials(
        project: "p", zone: "z", instance: "win-1", username: "ada",
        timeout: timeout, pollInterval: .milliseconds(5), now: Date(timeIntervalSince1970: 1_800_000_000))
}

@Suite("Credenciales Windows (CBU-52)", .serialized)
struct WindowsCredentialsTests {
    @Test func resetPublishesKeyPollsSerialAndDecrypts() async throws {
        let agent = FakeAgent()
        let credential = try await reset(agent)
        #expect(credential == WindowsCredential(username: "ada", password: "S3cr3t!pw"))

        let payload = try #require(agent.publishedPayload)
        #expect(payload["userName"] as? String == "ada")
        #expect(payload["email"] as? String == "ada")
        #expect(payload["hashFunction"] as? String == "sha256")
        #expect(payload["addToAdministrators"] as? Bool == true)
        #expect(payload["expireOn"] as? String == "2027-01-15T08:05:00Z")  // now + 5 min
        #expect(Data(base64Encoded: payload["modulus"] as! String)?.count == 256)  // RSA-2048
        #expect(payload["exponent"] as? String == "AQAB")

        // Metadata: conserva fingerprint y otras claves; sustituye windows-keys.
        let metadata = try #require(agent.publishedMetadata)
        #expect(metadata["fingerprint"] as? String == "fp-1")
        let keys = (metadata["items"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        #expect(keys == ["startup", "windows-keys"])

        // Orden: permiso antes de nada; poll incremental del puerto 4 con `start`.
        #expect(agent.requests.first?.path.hasSuffix("/testIamPermissions") == true)
        let polls = agent.requests.filter { $0.path.hasSuffix("/serialPort") }
        #expect(polls.count > 2)  // respuesta partida en varias lecturas
        #expect(polls.allSatisfy { $0.query?.contains("port=4") == true })
        #expect(polls.dropFirst().allSatisfy { $0.query?.contains("start=") == true })
    }

    @Test func sha1ResponseIsDecrypted() async throws {
        let agent = FakeAgent()
        agent.reply = .password("Legacy-1", hash: "sha1")
        agent.splitResponse = false
        #expect(try await reset(agent).password == "Legacy-1")
    }

    @Test func missingPermissionFailsBeforePublishing() async {
        let agent = FakeAgent()
        agent.grantsSetMetadata = false
        await #expect(throws: WindowsCredentialError.permissionDenied) { try await reset(agent) }
        #expect(agent.requests.map(\.path).allSatisfy { $0.hasSuffix("/testIamPermissions") })
    }

    @Test func silentAgentTimesOut() async {
        let agent = FakeAgent()
        agent.reply = .silent
        await #expect(throws: WindowsCredentialError.timeout) {
            try await reset(agent, timeout: .milliseconds(200))
        }
    }

    @Test func agentErrorIsSurfaced() async {
        let agent = FakeAgent()
        agent.reply = .error("user creation failed")
        agent.splitResponse = false
        await #expect(throws: WindowsCredentialError.agentError("user creation failed")) { try await reset(agent) }
    }

    @Test func fingerprintConflictRetriesThenSucceeds() async throws {
        let agent = FakeAgent()
        agent.setMetadataFailures = [(412, #"{"error":{"code":412,"status":"FAILED_PRECONDITION"}}"#)]
        agent.splitResponse = false
        #expect(try await reset(agent).password == "S3cr3t!pw")
        #expect(agent.requests.filter { $0.path.hasSuffix("/setMetadata") }.count == 2)
    }

    @Test func serviceAccountDeniedMapsToTypedError() async {
        let agent = FakeAgent()
        agent.setMetadataFailures = [(400, #"{"error":{"code":400,"message":"SERVICE_ACCOUNT_ACCESS_DENIED"}}"#)]
        await #expect(throws: WindowsCredentialError.serviceAccountUserRequired) { try await reset(agent) }
    }

    @Test func credentialNeverPrintsPassword() {
        let credential = WindowsCredential(username: "ada", password: "S3cr3t!pw")
        var dumped = ""
        dump(credential, to: &dumped)
        for text in [String(describing: credential), String(reflecting: credential), "\(credential)", dumped] {
            #expect(!text.contains("S3cr3t"))
            #expect(text.contains("<redacted>"))
        }
    }

    @Test func agentResponseMatchesEscapedModulusOnly() {
        let log = """
            {"modulus":"other","encryptedPassword":"x"}
            garbage {"modulus":"ab\\/cd","encryptedPassword":"e1","hashFunction":"sha256"}
            """
        #expect(GCPClient.agentResponse(in: log, modulus: "ab/cd")?.encryptedPassword == "e1")
        #expect(GCPClient.agentResponse(in: log, modulus: "zz") == nil)
    }

    @Test func pkcs1ParserStripsLeadingZero() throws {
        let key = try EphemeralRsaKey()
        #expect(key.modulus.count == 256)
        #expect(key.modulus.first.map { $0 != 0 } == true)
        #expect(key.exponent == Data([0x01, 0x00, 0x01]))
    }
}
