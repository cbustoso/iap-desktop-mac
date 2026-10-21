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
/// Sin renovación (`.none`): estos tests miran el error de un único intento.
func makeFactory(
    server: FakeBastionServer, http: StubBastionHTTP, target: BastionTarget = target,
    retry: BastionRetryPolicy = .none
) -> BastionTunnelFactory {
    BastionTunnelFactory(
        target: target,
        sessions: BastionSessionClient(transport: http),
        sockets: NIOBastionWebSocketTransport(
            connectTimeout: .seconds(5),
            endpointOverride: .init(scheme: "ws", host: "127.0.0.1", port: server.port)),
        retry: retry,
        telemetry: .disabled,
        armToken: { Secrets.armToken })
}

// MARK: - GH-95: contrato e2e

/// Registra los retardos del backoff sin esperar.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []

    var delays: [Duration] { lock.withLock { recorded } }

    var sleeper: BastionRetryPolicy.Sleeper {
        { [self] delay in lock.withLock { recorded.append(delay) } }
    }
}

/// Telemetría en memoria.
final class TelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BastionTelemetryEvent] = []

    var events: [BastionTelemetryEvent] { lock.withLock { recorded } }

    var telemetry: BastionTelemetry {
        BastionTelemetry { [self] _, event in lock.withLock { recorded.append(event) } }
    }
}

/// Contador `Sendable` (p. ej. invalidaciones del token ARM).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Fábrica contra el servidor falso con `/api/tokens` por el wire (URLSession → HTTP local).
func makeContractFactory(
    server: FakeBastionServer,
    retry: BastionRetryPolicy,
    telemetry: BastionTelemetry = .disabled,
    invalidations: Counter = Counter(),
    pingInterval: Duration? = nil
) -> BastionTunnelFactory {
    BastionTunnelFactory(
        target: target,
        sessions: BastionSessionClient(
            transport: URLSessionBastionTransport(session: URLSession(configuration: .ephemeral)),
            endpointOverride: server.apiBaseURL),
        sockets: NIOBastionWebSocketTransport(
            connectTimeout: .seconds(5),
            endpointOverride: .init(scheme: "ws", host: "127.0.0.1", port: server.port),
            pingInterval: pingInterval),
        retry: retry,
        telemetry: telemetry,
        invalidateArmToken: { invalidations.increment() },
        armToken: { Secrets.armToken })
}
