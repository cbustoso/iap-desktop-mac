import Foundation

/// URIs del relay para un destino (`IapEndpoint` en producto, mock en tests).
public struct RelayEndpoint: Sendable {
    let connectURL: @Sendable () -> URL?
    let reconnectURL: @Sendable (_ sid: String, _ ack: UInt64) -> URL?

    public init(
        connectURL: @escaping @Sendable () -> URL?,
        reconnectURL: @escaping @Sendable (_ sid: String, _ ack: UInt64) -> URL?
    ) {
        self.connectURL = connectURL
        self.reconnectURL = reconnectURL
    }

    /// Destino IAP real (`tunnel.cloudproxy.app/v4/...`).
    public init(_ iap: IapEndpoint) {
        self.init(
            connectURL: { iap.connectURL() },
            reconnectURL: { sid, ack in IapEndpoint.reconnectURL(sid: sid, ack: ack, zone: iap.zone) })
    }
}

/// Apertura de canales del relay: connect inicial y reconnect con `sid` +
/// `ack` (paridad `SshRelaySession`: `MaxReconnects = 2`, token fresco en cada
/// intento). El SID y el token nunca aparecen en descripciones.
public actor RelaySession: CustomStringConvertible {
    public static let maxReconnects = 2

    public nonisolated let endpoint: RelayEndpoint
    private let opener: any RelayChannelOpening
    private let accessToken: @Sendable () async throws -> String
    public private(set) var sid: String?
    private var reconnectAttempts = 0

    public init(
        endpoint: RelayEndpoint,
        opener: any RelayChannelOpening,
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.endpoint = endpoint
        self.opener = opener
        self.accessToken = accessToken
    }

    public nonisolated var description: String {
        "RelaySession(sid: <redacted>, token: <redacted>)"
    }

    func openInitial() async throws -> any RelayChannel {
        guard let url = endpoint.connectURL() else { throw TunnelError.invalidURL }
        return try await opener.open(url, accessToken: try await accessToken())
    }

    /// Reabre la sesión `sid` informando de los bytes ya recibidos. Lanza
    /// `reconnectExhausted` al superar `maxReconnects` intentos seguidos.
    func openReconnect(bytesReceived: UInt64) async throws -> any RelayChannel {
        guard let sid else { throw TunnelError.reconnectExhausted }
        guard reconnectAttempts < Self.maxReconnects else { throw TunnelError.reconnectExhausted }
        reconnectAttempts += 1
        guard let url = endpoint.reconnectURL(sid, bytesReceived) else { throw TunnelError.invalidURL }
        return try await opener.open(url, accessToken: try await accessToken())
    }

    func didConnect(sid: String) {
        self.sid = sid
        reconnectAttempts = 0
    }

    func didReconnect() {
        reconnectAttempts = 0
    }
}

/// Flujo de bytes fiable sobre el relay IAP (paridad `SshRelayStream`):
/// - envía DATA de ≤ 16 KiB y guarda cada uno en la cola *unacked* hasta su ACK;
/// - adjunta el ACK de lo recibido a cada escritura y lo fuerza si se acumula
///   más de 1 MiB sin confirmar (`MaxReadDataPerAck`);
/// - ante un cierre recuperable reconecta (×2) y reenvía lo no confirmado;
/// - los cierres de política (4033, 4047, 4003…) terminan con error tipado.
///
/// Forma `send` / `incoming` / `close`, igual que `SSHKit.SshByteStream`.
public actor RelayStream: CustomStringConvertible {
    static let maxReadDataPerAck: UInt64 = 1024 * 1024

    public nonisolated let session: RelaySession
    private let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    private var channel: (any RelayChannel)?
    private var generation = 0
    private var pump: Task<Void, Never>?
    private var handshake: CheckedContinuation<Void, any Error>?
    private var awaitingHandshake: Handshake?
    private var reconnecting = false
    private var closed = false

    private var bytesReceived: UInt64 = 0
    private var lastAckSent: UInt64 = 0
    private var lastAckReceived: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var unacked: [(expectedAck: UInt64, frame: Data)] = []

    /// Motivo del fin de `incoming()` si no fue un cierre normal.
    public private(set) var terminationError: TunnelError?

    private enum Handshake { case connect, reconnect }

    public init(session: RelaySession) {
        self.session = session
        (output, outputContinuation) = AsyncStream<Data>.makeStream()
    }

    public nonisolated var description: String {
        "RelayStream(sid: <redacted>)"
    }

    /// Abre el túnel y espera `CONNECT_SUCCESS_SID`.
    public static func connect(
        endpoint: RelayEndpoint,
        opener: any RelayChannelOpening,
        accessToken: @escaping @Sendable () async throws -> String,
        timeout: Duration = .seconds(30)
    ) async throws -> RelayStream {
        let stream = RelayStream(
            session: RelaySession(endpoint: endpoint, opener: opener, accessToken: accessToken))
        try await stream.open(timeout: timeout)
        return stream
    }

    /// Comprueba que el destino es alcanzable por IAP y cierra (paridad
    /// `ProbeConnectionAsync`). Lanza el error tipado si no lo es.
    public static func probe(
        endpoint: RelayEndpoint,
        opener: any RelayChannelOpening,
        accessToken: @escaping @Sendable () async throws -> String,
        timeout: Duration = .seconds(10)
    ) async throws {
        let stream = try await connect(endpoint: endpoint, opener: opener, accessToken: accessToken, timeout: timeout)
        await stream.close()
    }

    // MARK: - API de flujo

    public nonisolated func incoming() -> AsyncStream<Data> { output }

    public func send(_ data: Data) async throws {
        if let terminationError { throw terminationError }
        guard !closed else { throw TunnelError.relayClosed(code: 1000) }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + SshRelayFormat.Data.maxPayloadLength, data.endIndex)
            let frame = Data(try SshRelayFormat.Data.encode(Array(data[offset..<end])))
            bytesSent += UInt64(end - offset)
            // A la cola antes de enviar: si el canal cae, se reenvía tras reconectar.
            unacked.append((bytesSent, frame))
            await transmit(frame, includingAck: true)
            offset = end
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        generation += 1  // los mensajes del canal actual se ignoran
        pump?.cancel()
        await channel?.close()
        channel = nil
        failHandshake(TunnelError.relayClosed(code: 1000))
        outputContinuation.finish()
    }

    /// Bytes enviados aún sin ACK del servidor (para diagnóstico/tests).
    public var unacknowledgedByteCount: UInt64 { bytesSent - lastAckReceived }

    // MARK: - Conexión

    private func open(timeout: Duration) async throws {
        let channel = try await session.openInitial()
        try await attach(channel, awaiting: .connect, timeout: timeout)
    }

    private func attach(_ channel: any RelayChannel, awaiting step: Handshake, timeout: Duration) async throws {
        generation += 1
        let current = generation
        self.channel = channel
        awaitingHandshake = step
        pump = Task { [weak self] in
            for await message in channel.incoming() {
                await self?.received(message, generation: current)
            }
            await self?.channelEnded(channel, generation: current)
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.handshakeTimedOut(generation: current)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            handshake = continuation
        }
    }

    private func handshakeTimedOut(generation current: Int) async {
        guard current == generation, handshake != nil else { return }
        failHandshake(TunnelError.timeout)
        await channel?.close()
    }

    private func completeHandshake() {
        awaitingHandshake = nil
        handshake?.resume()
        handshake = nil
    }

    private func failHandshake(_ error: any Error) {
        awaitingHandshake = nil
        handshake?.resume(throwing: error)
        handshake = nil
    }

    // MARK: - Recepción

    private func received(_ message: Data, generation current: Int) async {
        guard current == generation else { return }  // canal ya sustituido
        let bytes = Array(message)
        guard let (rawTag, _) = try? SshRelayFormat.Tag.decode(bytes) else { return }
        switch SshRelayMessageTag(rawValue: rawTag) {
        case .connectSuccessSid:
            guard awaitingHandshake == .connect,
                  let (sid, _) = try? SshRelayFormat.ConnectSuccessSid.decode(bytes)
            else { return }
            await session.didConnect(sid: sid)
            completeHandshake()
        case .reconnectSuccessAck:
            guard awaitingHandshake == .reconnect,
                  let (ack, _) = try? SshRelayFormat.ReconnectAck.decode(bytes)
            else { return }
            acknowledge(ack)
            await session.didReconnect()
            // Ya reconectado: hay que desbloquear `transmit` antes del reenvío.
            reconnecting = false
            completeHandshake()
            // Reenvío de lo que el servidor no llegó a confirmar.
            for pending in unacked {
                await transmit(pending.frame, includingAck: false)
            }
        case .data:
            guard let (payload, _) = try? SshRelayFormat.Data.decode(bytes) else { return }
            bytesReceived += UInt64(payload.count)
            outputContinuation.yield(Data(payload))
            if bytesReceived - lastAckSent > Self.maxReadDataPerAck {
                await sendAckIfNeeded()
            }
        case .ack:
            guard let (ack, _) = try? SshRelayFormat.Ack.decode(bytes) else { return }
            acknowledge(ack)
        default:
            break  // LONG_CLOSE y tags desconocidos se ignoran, como en el original
        }
    }

    private func acknowledge(_ ack: UInt64) {
        guard ack > lastAckReceived else { return }
        lastAckReceived = ack
        unacked.removeAll { $0.expectedAck <= ack }
    }

    // MARK: - Envío

    private func transmit(_ frame: Data, includingAck: Bool) async {
        guard let channel, !reconnecting else { return }  // se reenviará al reconectar
        if includingAck { await sendAckIfNeeded() }
        do {
            try await channel.send(frame)
        } catch {
            // El cierre lo gestiona `channelEnded` (reconexión o error tipado).
        }
    }

    private func sendAckIfNeeded() async {
        guard let channel, !reconnecting, bytesReceived > lastAckSent else { return }
        let ack = bytesReceived
        do {
            try await channel.send(Data(SshRelayFormat.Ack.encode(ack: ack)))
            lastAckSent = ack
        } catch {}
    }

    // MARK: - Cierre y reconexión

    private func channelEnded(_ ended: any RelayChannel, generation current: Int) async {
        guard current == generation, !closed else { return }
        let code = await ended.closeCode()
        let error = code.flatMap(TunnelError.fromCloseCode)

        if handshake != nil {
            failHandshake(error ?? TunnelError.relayClosed(code: code ?? 1006))
            return
        }
        switch code {
        case nil, 1000, 4009, 4010:
            // Cierre normal o el destino cerró (DESTINATION_*_FAILED): fin limpio.
            finish(with: nil)
        default:
            if let error, error != .relayClosed(code: code ?? 0) {
                finish(with: error)  // política (4033/4047/4003/SID…): sin reintentar
            } else {
                await reconnect(after: error)
            }
        }
    }

    private func reconnect(after lastError: TunnelError?) async {
        reconnecting = true
        channel = nil
        while !closed {
            do {
                let next = try await session.openReconnect(bytesReceived: bytesReceived)
                // `reconnecting` sigue activo durante el handshake: nada se envía
                // hasta `RECONNECT_SUCCESS_ACK`, que lo desactiva y reenvía.
                try await attach(next, awaiting: .reconnect, timeout: .seconds(30))
                reconnecting = false
                return
            } catch let error as TunnelError where error == .reconnectExhausted {
                finish(with: .reconnectExhausted)
                return
            } catch let error as TunnelError where error != .timeout && TunnelError.isPolicy(error) {
                finish(with: error)
                return
            } catch {
                reconnecting = true  // otro intento hasta agotar `maxReconnects`
            }
        }
    }

    private func finish(with error: TunnelError?) {
        terminationError = error
        reconnecting = false
        channel = nil
        outputContinuation.finish()
    }
}

extension TunnelError {
    /// Errores de política o configuración: reintentar no los arregla.
    static func isPolicy(_ error: TunnelError) -> Bool {
        switch error {
        case .connectionDenied, .backendNotFound, .backendUnreachable, .invalidURL, .proxyBlocked:
            return true
        default:
            return false
        }
    }
}
