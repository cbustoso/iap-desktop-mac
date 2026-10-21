import Foundation
@testable import BastionKit

/// Secretos falsos: los tests comprueban que nunca aparecen en descripciones.
enum Secrets {
    static let armToken = "eyJ0eXAi.fake-arm-token"
    static func authToken(_ n: Int) -> String { "auth-token-secret-\(n)" }
    static func websocketToken(_ n: Int) -> String { "ws-token-secret-\(n)" }
}

let vmID = "/subscriptions/sub-1/resourceGroups/rg-1/providers/Microsoft.Compute/virtualMachines/vm-linux"
let target = BastionTarget(dnsName: "bst-123.bastion.azure.com", vmResourceID: vmID, port: 22)

/// `/api/tokens` en memoria: cada POST devuelve una sesión nueva (n = 1, 2…)
/// y registra lo enviado. Nada sale a la red.
final class StubBastionHTTP: BastionHTTPTransport, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let form: [String: String]
        let formKeys: [String]
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var posts = 0
    var postStatus: Int
    var postBody: Data?
    var deleteStatus: Int
    let nodeID: String

    init(postStatus: Int = 200, postBody: Data? = nil, deleteStatus: Int = 200, nodeID: String = "node-7") {
        self.postStatus = postStatus
        self.postBody = postBody
        self.deleteStatus = deleteStatus
        self.nodeID = nodeID
    }

    var requests: [Recorded] { lock.withLock { recorded } }
    var postRequests: [Recorded] { requests.filter { $0.method == "POST" } }
    var deleteRequests: [Recorded] { requests.filter { $0.method == "DELETE" } }

    func send(_ request: URLRequest) async throws -> BastionHTTPResponse {
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let pairs = body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        let entry = Recorded(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            form: Dictionary(pairs, uniquingKeysWith: { $1 }),
            formKeys: pairs.map(\.0))
        let n = lock.withLock { () -> Int in
            recorded.append(entry)
            if entry.method == "POST" { posts += 1 }
            return posts
        }
        if entry.method == "DELETE" { return BastionHTTPResponse(status: deleteStatus) }
        guard postStatus == 200 else {
            return BastionHTTPResponse(status: postStatus, body: postBody ?? Data())
        }
        let json = postBody ?? Data("""
            {"authToken":"\(Secrets.authToken(n))","nodeId":"\(nodeID)","websocketToken":"\(Secrets.websocketToken(n))"}
            """.utf8)
        return BastionHTTPResponse(status: 200, body: json)
    }
}

/// Espera activa acotada (estado que cambia en otra tarea / event loop).
func eventually(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Fábrica contra el servidor falso (`ws://127.0.0.1`), con el `/api/tokens` en memoria.
func makeFactory(
    server: FakeBastionServer, http: StubBastionHTTP, target: BastionTarget = target
) -> BastionTunnelFactory {
    BastionTunnelFactory(
        target: target,
        sessions: BastionSessionClient(transport: http),
        sockets: NIOBastionWebSocketTransport(
            connectTimeout: .seconds(5),
            endpointOverride: .init(scheme: "ws", host: "127.0.0.1", port: server.port)),
        armToken: { Secrets.armToken })
}
