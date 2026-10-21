import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import WebSocketKit

// MARK: - Abstracción del WebSocket (fake en tests)

public enum TunnelInbound: Sendable, Equatable {
    case binary(Data)
    case text(String)
}

public protocol TunnelSocket: Sendable {
    /// Un frame binario (opcode 0x2) por llamada.
    func send(_ bytes: Data) async throws
    /// Termina cuando el servidor o nosotros cerramos.
    var inbound: AsyncStream<TunnelInbound> { get }
    /// Close 1000.
    func close() async
}

public protocol TunnelSocketConnector: Sendable {
    func connect(_ request: WebSocketRequest) async throws -> any TunnelSocket
}

public struct HeaderField: Sendable, Equatable {
    public let name: String
    public let value: String
}

/// (e) Upgrade del túnel tal como lo genera `websocket-client` 1.8.0 en el CLI
/// (research §3.3 (2)): `Origin` y nada más; sin subprotocolo, sin
/// `Authorization` ni cookies. Host, Upgrade, Connection y Sec-WebSocket-* los
/// añade la librería.
public struct WebSocketRequest: Sendable, Equatable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int
    /// Sin percent-encoding: el CLI interpola el token tal cual (`tunnel.py` L136).
    public let path: String
    public let query: String?
    public let headers: [HeaderField]

    public static func bastion(dnsName: String, tokens: BastionSessionTokens) -> WebSocketRequest {
        WebSocketRequest(
            scheme: "wss",
            host: dnsName,
            port: 443,
            path: "/webtunnelv2/\(tokens.websocketToken)",
            query: "X-Node-Id=\(tokens.nodeId)",
            headers: [HeaderField(name: "Origin", value: "https://\(dnsName)")]
        )
    }

    public var description: String {
        let redactedPath = path.hasPrefix("/webtunnelv2/") ? "/webtunnelv2/<redacted>" : path
        return "\(scheme)://\(host)\(redactedPath)" + (query.map { "?\($0)" } ?? "")
            + " headers: " + headers.map { "\($0.name): \($0.value)" }.joined(separator: ", ")
    }
}

public enum TunnelSocketError: Error, Equatable, CustomStringConvertible {
    case connectTimeout
    case handshakeRejected(status: Int)
    case handshakeFailed(String)

    public var description: String {
        switch self {
        case .connectTimeout: return "Timeout abriendo el WebSocket del Bastion."
        case .handshakeRejected(let status): return "El Bastion rechazó el upgrade WebSocket (HTTP \(status))."
        case .handshakeFailed(let what): return "Falló el upgrade WebSocket (\(what))."
        }
    }
}

// MARK: - Implementación con WebSocketKit (SwiftNIO)

public final class WebSocketKitConnector: TunnelSocketConnector {
    private let group: MultiThreadedEventLoopGroup
    private let connectTimeout: Duration

    public init(group: MultiThreadedEventLoopGroup = .singleton, connectTimeout: Duration = .seconds(15)) {
        self.group = group
        self.connectTimeout = connectTimeout
    }

    public func connect(_ request: WebSocketRequest) async throws -> any TunnelSocket {
        var headers = HTTPHeaders()
        for field in request.headers { headers.add(name: field.name, value: field.value) }
        // RDP manda ráfagas grandes: el límite por defecto (16 KiB) cerraría el WS.
        let configuration = WebSocketClient.Configuration(maxFrameSize: 1 << 24)
        let (stream, continuation) = AsyncStream<TunnelInbound>.makeStream()
        let once = ResumeOnce()
        let nanos = Int64(connectTimeout.components.seconds) * 1_000_000_000 + connectTimeout.components.attoseconds / 1_000_000_000

        let socket: WebSocket = try await withCheckedThrowingContinuation { resume in
            // WebSocketKit no completa `connect` si el servidor calla: timeout propio.
            let timeout = group.next().scheduleTask(in: .nanoseconds(nanos)) {
                if once.claim() { resume.resume(throwing: TunnelSocketError.connectTimeout) }
            }
            let future = WebSocket.connect(
                scheme: request.scheme,
                host: request.host,
                port: request.port,
                path: request.path,
                query: request.query,
                headers: headers,
                configuration: configuration,
                on: group
            ) { ws in
                ws.onBinary { _, buffer in
                    continuation.yield(.binary(Data(buffer.readableBytesView)))
                }
                ws.onText { _, text in
                    continuation.yield(.text(text))
                }
                ws.onClose.whenComplete { _ in continuation.finish() }
                timeout.cancel()
                if once.claim() { resume.resume(returning: ws) } else { _ = ws.close() }
            }
            future.whenFailure { error in
                timeout.cancel()
                if once.claim() { resume.resume(throwing: Self.map(error)) }
            }
        }
        return WebSocketKitTunnelSocket(socket: socket, inbound: stream)
    }

    static func map(_ error: any Error) -> TunnelSocketError {
        if case WebSocketClient.Error.invalidResponseStatus(let head) = error {
            return .handshakeRejected(status: Int(head.status.code))
        }
        return .handshakeFailed(String(describing: type(of: error)))
    }
}

final class WebSocketKitTunnelSocket: TunnelSocket {
    private let socket: WebSocket
    let inbound: AsyncStream<TunnelInbound>

    init(socket: WebSocket, inbound: AsyncStream<TunnelInbound>) {
        self.socket = socket
        self.inbound = inbound
    }

    func send(_ bytes: Data) async throws {
        let promise = socket.eventLoop.makePromise(of: Void.self)
        socket.send(raw: bytes, opcode: .binary, fin: true, promise: promise)
        try await promise.futureResult.get()
    }

    func close() async {
        guard !socket.isClosed else { return }
        try? await socket.close(code: .normalClosure).get()
    }
}

/// Garantiza un único `resume` entre timeout, éxito y fallo.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
