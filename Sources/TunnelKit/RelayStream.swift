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
            reconnectURL: { sid, ack in IapEndpoint.reconnectURL(sid: sid, ack: ack, zone: iap.zone, host: iap.serviceHost) })
    }
}

/// Reintentos ante un corte recuperable del túnel (CBU-42): backoff
/// exponencial y plazo total acotado para no colgar la sesión indefinidamente.
public struct ReconnectPolicy: Sendable, Equatable {
    /// Intentos de reanudación (`reconnect?sid&ack`) por corte.
    public var maxAttempts: Int
    /// Espera antes del 2.º intento (el 1.º es inmediato); luego se multiplica.
    public var initialDelay: Duration
    public var multiplier: Double
    public var maxDelay: Duration
    /// Tiempo máximo desde el corte hasta dar la sesión por perdida.
    public var totalTimeout: Duration
    /// Timeout de cada handshake de reconexión.
    public var handshakeTimeout: Duration

    public init(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(500),
        multiplier: Double = 2,
        maxDelay: Duration = .seconds(4),
        totalTimeout: Duration = .seconds(30),
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.totalTimeout = totalTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    public static let `default` = ReconnectPolicy()

    /// Espera antes del intento `attempt` (1-based): 0, d, d·m, d·m², … ≤ maxDelay.
    public func delay(beforeAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }
        let factor = pow(multiplier, Double(attempt - 2))
        return min(initialDelay * factor, maxDelay)
    }
}

/// Estado del enlace con el relay, observable por SSH/UI.
public enum RelayState: Sendable, Equatable {
    case connected
    /// Corte recuperable: reanudando con `sid&ack` (intento n de `maxAttempts`).
    case reconnecting(attempt: Int)
    /// Perdido definitivamente (reintentos agotados o cierre de política).
    case lost(TunnelError)
    /// Cerrado de forma normal (cliente o destino).
    case closed
}

/// Apertura de canales del relay: connect inicial y reconnect con `sid` +
/// `ack` (paridad `SshRelaySession`; token fresco en cada intento, de modo que
/// un `splice` de credenciales solo afecta a reconexiones futuras). El SID y el
/// token nunca aparecen en descripciones. Los reintentos los gobierna
/// `ReconnectPolicy` en `RelayStream`.
public actor RelaySession: CustomStringConvertible {
    /// Compatibilidad: intentos por defecto de `ReconnectPolicy`.
    public static let maxReconnects = ReconnectPolicy.default.maxAttempts

    public nonisolated let endpoint: RelayEndpoint
    private let opener: any RelayChannelOpening
    private let accessToken: @Sendable () async throws -> String
    public private(set) var sid: String?

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

    /// Reabre la sesión `sid` informando de los bytes ya recibidos.
    func openReconnect(bytesReceived: UInt64) async throws -> any RelayChannel {
        guard let sid else { throw TunnelError.reconnectExhausted }
        guard let url = endpoint.reconnectURL(sid, bytesReceived) else { throw TunnelError.invalidURL }
        return try await opener.open(url, accessToken: try await accessToken())
    }

    func didConnect(sid: String) {
        self.sid = sid
    }
}

/// Flujo de bytes fiable sobre el relay IAP (paridad `SshRelayStream`):
/// - envía DATA de ≤ 16 KiB y guarda cada uno en la cola *unacked* hasta su ACK;
/// - adjunta el ACK de lo recibido a cada escritura y lo fuerza si se acumula
///   más de 1 MiB sin confirmar (`MaxReadDataPerAck`);
/// - ante un cierre recuperable reanuda con `sid&ack` según `ReconnectPolicy`
///   (backoff + plazo total) y reenvía lo no confirmado; publica `RelayState`;
/// - los cierres de política (4033, 4047, 4003…) terminan con error tipado.
///
/// Forma `send` / `incoming` / `close`, igual que `SSHKit.SshByteStream`.
public actor RelayStream: CustomStringConvertible {
    static let maxReadDataPerAck: UInt64 = 1024 * 1024

    public nonisolated let session: RelaySession
    public nonisolated let policy: ReconnectPolicy
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

    /// Estado actual del enlace.
    public private(set) var state: RelayState = .connected
    private var stateSubscribers: [UUID: AsyncStream<RelayState>.Continuation] = [:]

    private enum Handshake { case connect, reconnect }

    public init(session: RelaySession, policy: ReconnectPolicy = .default) {
        self.session = session
        self.policy = policy
        (output, outputContinuation) = AsyncStream<Data>.makeStream()
    }

    /// Cambios de estado (empieza con el actual). Varios suscriptores; termina
    /// cuando el enlace se pierde o se cierra.
    public func stateUpdates() -> AsyncStream<RelayState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RelayState>.makeStream(bufferingPolicy: .bufferingNewest(16))
        continuation.yield(state)
        switch state {
        case .lost, .closed:
            continuation.finish()
        default:
            stateSubscribers[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    private func publish(_ next: RelayState) {
        // `.lost` es definitivo: un `close()` posterior no lo convierte en `.closed`.
        if case .lost = state { return }
        guard next != state else { return }
        state = next
        for continuation in stateSubscribers.values {
            continuation.yield(next)
            if case .lost = next { continuation.finish() }
            if next == .closed { continuation.finish() }
        }
        if case .lost = next { stateSubscribers.removeAll() }
        if next == .closed { stateSubscribers.removeAll() }
    }

    public nonisolated var description: String {
        "RelayStream(sid: <redacted>)"
    }

    /// Abre el túnel y espera `CONNECT_SUCCESS_SID`.
    public static func connect(
        endpoint: RelayEndpoint,
        opener: any RelayChannelOpening,
        accessToken: @escaping @Sendable () async throws -> String,
        timeout: Duration = .seconds(30),
        reconnectPolicy: ReconnectPolicy = .default
    ) async throws -> RelayStream {
        let stream = RelayStream(
            session: RelaySession(endpoint: endpoint, opener: opener, accessToken: accessToken),
            policy: reconnectPolicy)
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
        publish(.closed)
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

    /// Reanuda la sesión: hasta `policy.maxAttempts` intentos con backoff,
    /// sin superar `policy.totalTimeout` desde el corte. Lo enviado mientras
    /// tanto queda en la cola *unacked* y se reenvía al reconectar.
    private func reconnect(after lastError: TunnelError?) async {
        reconnecting = true
        channel = nil
        let deadline = ContinuousClock.now + policy.totalTimeout
        var attempt = 0
        while !closed {
            attempt += 1
            let remaining = deadline - ContinuousClock.now
            guard attempt <= policy.maxAttempts, remaining > .zero else {
                finish(with: .reconnectExhausted)
                return
            }
            publish(.reconnecting(attempt: attempt))
            let wait = min(policy.delay(beforeAttempt: attempt), remaining)
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !closed else { return }
            let budget = deadline - ContinuousClock.now
            guard budget > .zero else {
                finish(with: .reconnectExhausted)
                return
            }
            do {
                let next = try await session.openReconnect(bytesReceived: bytesReceived)
                // `reconnecting` sigue activo durante el handshake: nada se envía
                // hasta `RECONNECT_SUCCESS_ACK`, que lo desactiva y reenvía.
                try await attach(next, awaiting: .reconnect, timeout: min(policy.handshakeTimeout, budget))
                reconnecting = false
                publish(.connected)
                return
            } catch let error as TunnelError where error == .reconnectExhausted {
                finish(with: .reconnectExhausted)
                return
            } catch let error as TunnelError where error != .timeout && TunnelError.isPolicy(error) {
                finish(with: error)
                return
            } catch {
                reconnecting = true  // siguiente intento (backoff)
            }
        }
    }

    private func finish(with error: TunnelError?) {
        terminationError = error
        reconnecting = false
        channel = nil
        outputContinuation.finish()
        publish(error.map(RelayState.lost) ?? .closed)
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
