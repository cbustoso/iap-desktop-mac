import Foundation
@testable import BastionSpikeCore

/// Cola async de bytes: `nil` marca EOF.
actor ByteQueue {
    private var items: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Never>?

    func push(_ item: Data?) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    func pop(maximum: Int) async -> Data? {
        let item: Data?
        if !items.isEmpty {
            item = items.removeFirst()
        } else {
            item = await withCheckedContinuation { waiter = $0 }
        }
        guard let data = item, data.count > maximum else { return item }
        items.insert(data.subdata(in: maximum..<data.count), at: 0)
        return data.subdata(in: 0..<maximum)
    }
}

/// Socket TCP local falso: el test empuja lo que "escribe ssh" y lee lo que
/// le llega del túnel. `onReceived` permite cerrar (EOF) tras recibir N bytes.
final class FakeLocal: LocalStream, @unchecked Sendable {
    let input = ByteQueue()
    private let lock = NSLock()
    private var received = Data()
    private var closed = false
    private let eofAfter: Int?

    init(eofAfterReceiving bytes: Int? = nil) {
        eofAfter = bytes
    }

    var receivedData: Data { lock.withLock { received } }
    var isClosed: Bool { lock.withLock { closed } }

    func receive(maximum: Int) async throws -> Data? {
        await input.pop(maximum: maximum)
    }

    func send(_ data: Data) async throws {
        let total = lock.withLock {
            received.append(data)
            return received.count
        }
        if let eofAfter, total >= eofAfter { await input.push(nil) }
    }

    func close() async {
        lock.withLock { closed = true }
        await input.push(nil)
    }
}

/// WebSocket falso: registra cada frame binario enviado y, en modo eco,
/// devuelve los bytes troceados de otra forma (como un servidor real).
final class FakeSocket: TunnelSocket, @unchecked Sendable {
    let inbound: AsyncStream<TunnelInbound>
    private let continuation: AsyncStream<TunnelInbound>.Continuation
    private let lock = NSLock()
    private var frames: [Data] = []
    private var closeCount = 0
    private let echoChunk: Int?

    init(echoChunk: Int? = nil) {
        (inbound, continuation) = AsyncStream<TunnelInbound>.makeStream()
        self.echoChunk = echoChunk
    }

    var sentFrames: [Data] { lock.withLock { frames } }
    var closes: Int { lock.withLock { closeCount } }

    func send(_ bytes: Data) async throws {
        lock.withLock { frames.append(bytes) }
        guard let echoChunk else { return }
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + echoChunk, bytes.count)
            continuation.yield(.binary(bytes.subdata(in: offset..<end)))
            offset = end
        }
    }

    func serverSends(_ message: TunnelInbound) {
        continuation.yield(message)
    }

    func serverCloses() {
        continuation.finish()
    }

    func close() async {
        lock.withLock { closeCount += 1 }
        continuation.finish()
    }
}

final class FakeConnector: TunnelSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [WebSocketRequest] = []
    let socket: FakeSocket

    init(socket: FakeSocket) {
        self.socket = socket
    }

    var seen: [WebSocketRequest] { lock.withLock { requests } }

    func connect(_ request: WebSocketRequest) async throws -> any TunnelSocket {
        lock.withLock { requests.append(request) }
        return socket
    }
}

/// Servidor HTTP falso para ARM y `/api/tokens`.
final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> HTTPResponse

    init(handler: @escaping @Sendable (URLRequest, Int) -> HTTPResponse) {
        self.handler = handler
    }

    var seen: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let index = lock.withLock {
            requests.append(request)
            return requests.count - 1
        }
        return handler(request, index)
    }

    /// POST → tokens numerados; DELETE → 200 la primera vez por authToken, luego 404.
    static func bastion() -> FakeHTTP {
        let deleted = DeletedSet()
        return FakeHTTP { request, index in
            switch request.httpMethod {
            case "POST":
                let body = #"{"authToken":"auth-token-\#(index)","nodeId":"node-1","websocketToken":"ws-token-secret-\#(index)"}"#
                return HTTPResponse(status: 200, body: Data(body.utf8))
            case "DELETE":
                let token = request.url!.lastPathComponent
                return HTTPResponse(status: deleted.insert(token) ? 200 : 404)
            default:
                return HTTPResponse(status: 405)
            }
        }
    }
}

final class DeletedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<String> = []

    func insert(_ token: String) -> Bool {
        lock.withLock { tokens.insert(token).inserted }
    }
}

/// `az` falso: responde según los argumentos y cuenta invocaciones.
final class FakeAz: AzCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private let respond: @Sendable ([String]) -> AzCommandOutput

    init(respond: @escaping @Sendable ([String]) -> AzCommandOutput) {
        self.respond = respond
    }

    var invocations: [[String]] { lock.withLock { calls } }

    func run(_ arguments: [String], timeout: Duration) async throws -> AzCommandOutput {
        lock.withLock { calls.append(arguments) }
        return respond(arguments)
    }
}

/// Sink de log que acumula líneas para comprobar la redacción.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var text: String { lock.withLock { lines.joined(separator: "\n") } }

    func makeLog(verbose: Bool = true) -> SpikeLog {
        let log = SpikeLog { [self] line in lock.withLock { lines.append(line) } }
        log.verbose = verbose
        return log
    }
}
