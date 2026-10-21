// Servidor `/webtunnelv2` falso para BastionKit (research §9.5 (2)), portado
// del spike `Spikes/BastionSpike`. Solo tests: `ws://127.0.0.1:{efímero}`
// (o `wss://` con la CA de test), sin credenciales reales.
//
// GH-95: con `Options.contract` también sirve `POST`/`DELETE /api/tokens`
// como el Bastion (research §3.3): emite `{authToken, nodeId, websocketToken}`,
// exige `token` + `X-Node-Id` coherentes al encadenar, acepta cada
// `websocketToken` una sola vez y permite inyectar fallos (401/503 en el
// POST, upgrades rechazados, sesiones caducadas).
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket

final class FakeBastionServer: Sendable {
    enum Behavior: Sendable, Equatable {
        /// Eco de cada frame binario.
        case echo
        /// Reenvía los bytes a un TCP local (p. ej. `MockSSHServer`).
        case forward(port: Int)
        /// Responde al primer frame con un frame de texto.
        case textOnFirstFrame
        /// Responde al primer frame con Close `code`.
        case closeOnFirstFrame(code: UInt16)
        /// Corta el TCP al recibir el primer frame (sin Close).
        case dropOnFirstFrame
        /// Rechaza el upgrade con este status HTTP.
        case reject(status: Int)
        /// GH-95: eco, y corta el TCP (sin Close) `after` tras el upgrade.
        case dropAfter(Duration)
        /// GH-95: eco, pero nunca contesta a los pings (enlace medio muerto).
        case ignorePings
    }

    /// GH-95: plano de datos `/api/tokens` simulado.
    struct Contract: Sendable, Equatable {
        /// Status de los primeros POST (uno por POST) antes de contestar 200.
        var postFailures: [Int] = []
        /// Upgrades válidos que se rechazan con 401 antes de aceptar (token caducado).
        var rejectedUpgrades = 0
        var nodeID = "node-fake-1"
    }

    struct Options: Sendable {
        var behavior: Behavior = .echo
        /// `nil` = sin `/api/tokens` (el POST va a `StubBastionHTTP`) y sin validar el token del WS.
        var contract: Contract?
        /// TLS con la CA de test (para el `CONNECT` del proxy, que solo se usa con `wss`).
        var tls = false
    }

    struct APIRequest: Sendable, Equatable {
        var method: String
        var path: String
        var nodeIDHeader: String?
        var form: [String: String]
        var formKeys: [String]
        var status: Int
    }

    struct Handshake: Sendable, Equatable {
        var path: String
        var query: String?
        var origin: String?
        var hasSubprotocol: Bool
        var hasAuthorization: Bool
    }

    struct Observed: Sendable, Equatable {
        var handshakes: [Handshake] = []
        /// GH-95: peticiones a `/api/tokens` con el status respondido.
        var api: [APIRequest] = []
        /// Status de cada upgrade (101 aceptado, 401/404 rechazado).
        var upgradeStatuses: [Int] = []
        /// Infracciones del contrato (encadenado incoherente, token reutilizado…).
        var violations: [String] = []
        /// Tamaño de cada frame binario recibido del cliente.
        var frameSizes: [Int] = []
        /// Códigos de los Close recibidos del cliente.
        var clientCloseCodes: [UInt16] = []
    }

    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let recorder: Recorder

    var observed: Observed { recorder.value }

    var posts: [APIRequest] { observed.api.filter { $0.method == "POST" } }
    var deletes: [APIRequest] { observed.api.filter { $0.method == "DELETE" } }

    /// `http://127.0.0.1:{puerto}` para `BastionSessionClient(endpointOverride:)`.
    var apiBaseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Olvida todas las sesiones emitidas (caducidad en el servidor).
    func expireSessions() { contractState.expireAll() }

    /// Status para los próximos POST (uno por POST) antes de volver a 200.
    func injectPostFailures(_ statuses: [Int]) { contractState.injectPostFailures(statuses) }

    /// Sesiones vivas (emitidas y sin DELETE).
    var liveSessions: Int { contractState.liveCount }

    private let contractState: ContractState

    private init(
        port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel, recorder: Recorder, contractState: ContractState
    ) {
        self.port = port
        self.group = group
        self.channel = channel
        self.recorder = recorder
        self.contractState = contractState
    }

    static func start(_ behavior: Behavior = .echo) async throws -> FakeBastionServer {
        try await start(Options(behavior: behavior))
    }

    static func start(_ options: Options) async throws -> FakeBastionServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = Recorder()
        let contract = ContractState(options.contract)
        do {
            let tls = try options.tls ? NIOSSLContext(configuration: TestTLS.serverConfiguration()) : nil
            let behavior = options.behavior
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .childChannelInitializer { channel in
                    if let tls {
                        do {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }
                    return configure(channel: channel, behavior: behavior, recorder: recorder, contract: contract)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            guard let port = channel.localAddress?.port else { throw FakeServerError.noPort }
            return FakeBastionServer(port: port, group: group, channel: channel, recorder: recorder, contractState: contract)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func shutdown() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }

    private enum FakeServerError: Error { case noPort }

    private static func configure(
        channel: any Channel, behavior: Behavior, recorder: Recorder, contract: ContractState
    ) -> EventLoopFuture<Void> {
        let rejection = RejectionStatus()
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 24,
            shouldUpgrade: { channel, head in
                let handshake = handshake(from: head)
                recorder.update { $0.handshakes.append(handshake) }
                var status: Int?
                if case .reject(let code) = behavior { status = code }
                if status == nil, let refusal = contract.upgrade(handshake, recorder: recorder) { status = refusal }
                recorder.update { $0.upgradeStatuses.append(status ?? 101) }
                if let status {
                    rejection.set(status)
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                // Sin subprotocolo: no se devuelve Sec-WebSocket-Protocol.
                return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    let rejection = try pipeline.handler(type: RejectionHandler.self)
                    pipeline.removeHandler(rejection, promise: nil)
                    try pipeline.addHandlers(
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: 64,
                            maxAccumulatedFrameSize: 1 << 24),
                        TunnelHandler(behavior: behavior, recorder: recorder))
                }
            })
        return channel.eventLoop.makeCompletedFuture {
            let pipeline = channel.pipeline.syncOperations
            try pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
            try pipeline.addHandler(RejectionHandler(rejection: rejection, contract: contract, recorder: recorder))
        }
    }

    private static func handshake(from head: HTTPRequestHead) -> Handshake {
        let parts = head.uri.split(separator: "?", maxSplits: 1).map(String.init)
        return Handshake(
            path: parts.first ?? head.uri,
            query: parts.count > 1 ? parts[1] : nil,
            origin: head.headers.first(name: "Origin"),
            hasSubprotocol: head.headers.contains(name: "Sec-WebSocket-Protocol"),
            hasAuthorization: head.headers.contains(name: "Authorization"))
    }
}

/// `@unchecked Sendable`: todo acceso pasa por `lock`.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = FakeBastionServer.Observed()

    var value: FakeBastionServer.Observed { lock.withLock { storage } }

    func update(_ body: (inout FakeBastionServer.Observed) -> Void) {
        lock.withLock { body(&storage) }
    }
}

/// Status con que se rechazó el último upgrade de esta conexión.
/// `@unchecked Sendable`: acceso bajo `lock`.
private final class RejectionStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int?
    func set(_ value: Int) { lock.withLock { status = value } }
    func take() -> Int? { lock.withLock { defer { status = nil }; return status } }
}

/// Estado del contrato `/api/tokens`. `@unchecked Sendable`: acceso bajo `lock`.
private final class ContractState: @unchecked Sendable {
    private struct Issued { let nodeID: String; let websocketToken: String }

    private let lock = NSLock()
    private let contract: FakeBastionServer.Contract?
    private var postFailures: [Int]
    private var rejectedUpgrades: Int
    private var serial = 0
    private var issued: [String: Issued] = [:]  // authToken → sesión
    private var unusedWebSocketTokens: Set<String> = []

    init(_ contract: FakeBastionServer.Contract?) {
        self.contract = contract
        postFailures = contract?.postFailures ?? []
        rejectedUpgrades = contract?.rejectedUpgrades ?? 0
    }

    var enabled: Bool { contract != nil }
    var liveCount: Int { lock.withLock { issued.count } }

    func injectPostFailures(_ statuses: [Int]) {
        lock.withLock { postFailures.append(contentsOf: statuses) }
    }

    func expireAll() {
        lock.withLock {
            issued.removeAll()
            unusedWebSocketTokens.removeAll()
        }
    }

    /// `POST /api/tokens`: status + cuerpo JSON.
    func post(form: [String: String], nodeIDHeader: String?, recorder: Recorder) -> (Int, String) {
        lock.withLock {
            guard let contract else { return (404, "") }
            for key in ["resourceId", "protocol", "workloadHostPort", "aztoken"] where form[key] == nil {
                recorder.update { $0.violations.append("POST sin \(key)") }
                return (400, #"{"message":"missing \#(key)"}"#)
            }
            if !postFailures.isEmpty {
                let status = postFailures.removeFirst()
                return (status, #"{"message":"injected \#(status)"}"#)
            }
            if let previous = form["token"] {
                guard let session = issued[previous] else {
                    return (404, #"{"message":"session not found"}"#)
                }
                if nodeIDHeader != session.nodeID {
                    recorder.update { $0.violations.append("POST encadenado sin X-Node-Id coherente") }
                    return (400, #"{"message":"node mismatch"}"#)
                }
            } else if nodeIDHeader != nil {
                recorder.update { $0.violations.append("X-Node-Id sin token") }
            }
            // El POST encadenado sustituye a la sesión anterior: basta un DELETE de la última.
            if let previous = form["token"] { issued.removeValue(forKey: previous) }
            serial += 1
            let session = Issued(nodeID: contract.nodeID, websocketToken: "ws-\(serial)-secret")
            let authToken = "auth-\(serial)-secret"
            issued[authToken] = session
            unusedWebSocketTokens.insert(session.websocketToken)
            return (200, #"{"authToken":"\#(authToken)","nodeId":"\#(session.nodeID)","websocketToken":"\#(session.websocketToken)"}"#)
        }
    }

    /// `DELETE /api/tokens/{authToken}`.
    func delete(authToken: String, nodeIDHeader: String?, recorder: Recorder) -> Int {
        lock.withLock {
            guard let session = issued.removeValue(forKey: authToken) else { return 404 }
            if nodeIDHeader != session.nodeID {
                recorder.update { $0.violations.append("DELETE sin X-Node-Id coherente") }
            }
            return 200
        }
    }

    /// `nil` = aceptar el upgrade; si no, el status del rechazo.
    func upgrade(_ handshake: FakeBastionServer.Handshake, recorder: Recorder) -> Int? {
        lock.withLock {
            guard contract != nil else { return nil }
            let token = String(handshake.path.dropFirst("/webtunnelv2/".count))
            guard handshake.path.hasPrefix("/webtunnelv2/"), unusedWebSocketTokens.remove(token) != nil else {
                recorder.update { $0.violations.append("websocketToken desconocido o reutilizado") }
                return 404
            }
            if rejectedUpgrades > 0 {
                rejectedUpgrades -= 1
                return 401
            }
            return nil
        }
    }
}

/// Responde a lo que no se convirtió en WebSocket: `/api/tokens` (contrato)
/// o el rechazo del upgrade.
private final class RejectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let rejection: RejectionStatus
    private let contract: ContractState
    private let recorder: Recorder
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(rejection: RejectionStatus, contract: ContractState, recorder: Recorder) {
        self.rejection = rejection
        self.contract = contract
        self.recorder = recorder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let request = head else { return }
            head = nil
            respond(to: request, context: context)
        }
    }

    private func respond(to request: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = String(request.uri.split(separator: "?").first ?? "")
        let nodeID = request.headers.first(name: "X-Node-Id")
        if contract.enabled, path == "/api/tokens", request.method == .POST {
            let pairs = Self.form(String(buffer: body))
            let (status, json) = contract.post(form: Dictionary(pairs, uniquingKeysWith: { $1 }), nodeIDHeader: nodeID, recorder: recorder)
            record(request, path: path, nodeID: nodeID, pairs: pairs, status: status)
            write(status: status, body: json, keepAlive: true, request: request, context: context)
        } else if contract.enabled, path.hasPrefix("/api/tokens/"), request.method == .DELETE {
            let status = contract.delete(authToken: String(path.dropFirst("/api/tokens/".count)), nodeIDHeader: nodeID, recorder: recorder)
            record(request, path: "/api/tokens/{authToken}", nodeID: nodeID, pairs: [], status: status)
            write(status: status, body: "", keepAlive: true, request: request, context: context)
        } else {
            write(status: rejection.take() ?? 400, body: "", keepAlive: false, request: request, context: context)
        }
    }

    private func record(_ request: HTTPRequestHead, path: String, nodeID: String?, pairs: [(String, String)], status: Int) {
        let entry = FakeBastionServer.APIRequest(
            method: request.method.rawValue, path: path, nodeIDHeader: nodeID,
            form: Dictionary(pairs, uniquingKeysWith: { $1 }), formKeys: pairs.map(\.0), status: status)
        recorder.update { $0.api.append(entry) }
    }

    private func write(status: Int, body text: String, keepAlive: Bool, request: HTTPRequestHead, context: ChannelHandlerContext) {
        var head = HTTPResponseHead(version: request.version, status: HTTPResponseStatus(statusCode: status))
        head.headers.add(name: "Content-Length", value: String(text.utf8.count))
        if !text.isEmpty { head.headers.add(name: "Content-Type", value: "application/json") }
        if !keepAlive { head.headers.add(name: "Connection", value: "close") }
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if !text.isEmpty {
            context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    /// `application/x-www-form-urlencoded` (`quote_plus`).
    static func form(_ body: String) -> [(String, String)] {
        body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // Tras `shouldUpgrade` → nil, NIO reenvía la petición: no cerrar aquí.
        if let upgradeError = error as? NIOWebSocketUpgradeError, upgradeError == .unsupportedWebSocketTarget {
            return
        }
        context.close(promise: nil)
    }
}

private final class TunnelHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let behavior: FakeBastionServer.Behavior
    private let recorder: Recorder
    private var sentClose = false
    private var backend: (any Channel)?
    private var pendingToBackend: [ByteBuffer] = []

    init(behavior: FakeBastionServer.Behavior, recorder: Recorder) {
        self.behavior = behavior
        self.recorder = recorder
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if case .dropAfter(let delay) = behavior {
            let channel = context.channel
            context.eventLoop.scheduleTask(in: .nanoseconds(delay.testNanoseconds)) { channel.close(promise: nil) }
            return
        }
        guard case .forward(let port) = behavior else { return }
        let wsChannel = context.channel
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(BackendHandler(tunnel: wsChannel))
                }
            }
            .connect(host: "127.0.0.1", port: port)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    handler.value.backend = channel
                    for buffer in handler.value.pendingToBackend { channel.write(buffer, promise: nil) }
                    handler.value.pendingToBackend.removeAll()
                    channel.flush()
                case .failure:
                    wsChannel.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary:
            let payload = frame.unmaskedData
            let isFirst = recorder.value.frameSizes.isEmpty
            recorder.update { $0.frameSizes.append(payload.readableBytes) }
            handleBinary(payload, isFirst: isFirst, context: context)
        case .connectionClose:
            var data = frame.unmaskedData
            if let code = data.readInteger(as: UInt16.self) {
                recorder.update { $0.clientCloseCodes.append(code) }
            }
            if sentClose {
                context.close(promise: nil)
            } else {
                sentClose = true
                let channel = context.channel
                context.writeAndFlush(
                    wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData))
                ).whenComplete { _ in channel.close(promise: nil) }
            }
        case .ping:
            if case .ignorePings = behavior { return }
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)), promise: nil)
        default:
            break
        }
    }

    private func handleBinary(_ payload: ByteBuffer, isFirst: Bool, context: ChannelHandlerContext) {
        switch behavior {
        case .echo, .reject, .dropAfter, .ignorePings:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, data: payload)), promise: nil)
        case .forward:
            if let backend {
                backend.writeAndFlush(payload, promise: nil)
            } else {
                pendingToBackend.append(payload)
            }
        case .textOnFirstFrame:
            guard isFirst else { return }
            var text = context.channel.allocator.buffer(capacity: 16)
            text.writeString("{\"error\":\"nope\"}")
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: text)), promise: nil)
        case .closeOnFirstFrame(let code):
            guard isFirst, !sentClose else { return }
            sentClose = true
            var buffer = context.channel.allocator.buffer(capacity: 2)
            buffer.writeInteger(code)
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)), promise: nil)
        case .dropOnFirstFrame:
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        backend?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

/// Backend TCP → frames binarios hacia el cliente.
private final class BackendHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let tunnel: any Channel

    init(tunnel: any Channel) { self.tunnel = tunnel }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        tunnel.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buffer), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        tunnel.close(promise: nil)
        context.fireChannelInactive()
    }
}

extension Duration {
    var testNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
