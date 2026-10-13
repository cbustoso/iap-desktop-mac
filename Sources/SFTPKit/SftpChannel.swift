import Foundation
import SSHKit

/// Transporte de bytes del subsistema `sftp` (en producción, el
/// `SshDataChannel` de la `SshSession` ya autenticada; en tests, uno falso).
protocol SftpTransport: Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data) async throws
    func close() async
}

extension SshDataChannel: SftpTransport {}

/// Canal SFTP v3 sobre una `SshSession` existente: no abre conexión SSH propia
/// (REQ-SFTP-1), solo el subsistema `sftp` en la misma conexión.
public actor SftpChannel {
    /// Única versión soportada (la que habla OpenSSH).
    public static let protocolVersion: UInt32 = 3

    /// Versión acordada con el servidor (siempre 3).
    public nonisolated let version: UInt32
    /// Extensiones anunciadas en VERSION (`posix-rename@openssh.com` → "1", …).
    public nonisolated let extensions: [String: String]

    private let transport: any SftpTransport
    private let table: SftpRequestTable
    private let reader: Task<Void, Never>
    private var closed = false

    private init(
        transport: any SftpTransport, table: SftpRequestTable, reader: Task<Void, Never>, version: SftpVersion
    ) {
        self.transport = transport
        self.table = table
        self.reader = reader
        self.version = version.version
        extensions = version.extensions
    }

    /// Abre el subsistema `sftp` y negocia INIT/VERSION. Si la sesión ya está
    /// perdida o cerrada falla con `.sessionLost` sin tocar la red ni reintentar
    /// (la UI ofrece reabrir la sesión, igual que SSH).
    public static func open(over session: SshSession, timeout: Duration = .seconds(30)) async throws -> SftpChannel {
        try await open(linkState: session.linkState, timeout: timeout) {
            do {
                return try await session.openSubsystem("sftp")
            } catch SshSessionError.sessionClosed {
                throw SftpError.sessionLost
            }
        }
    }

    static func open(
        linkState: SshLinkState, timeout: Duration,
        transport makeTransport: () async throws -> any SftpTransport
    ) async throws -> SftpChannel {
        switch linkState {
        case .lost, .closed:
            throw SftpError.sessionLost
        case .connected, .reconnecting:
            break
        }
        let transport = try await makeTransport()
        let table = SftpRequestTable()
        let gate = VersionGate()
        let reader = Task { await Self.read(transport.output, table: table, gate: gate) }
        do {
            try await transport.write(SftpPacket.initialize(version: protocolVersion).encoded())
            let version = try await gate.wait(timeout: timeout)
            guard version.version == protocolVersion else {
                throw SftpError.unsupportedVersion(negotiated: version.version)
            }
            return SftpChannel(transport: transport, table: table, reader: reader, version: version)
        } catch {
            reader.cancel()
            table.failAll(.channelClosed)
            await transport.close()
            throw error
        }
    }

    /// Lector único del canal: el primer paquete debe ser VERSION; el resto se
    /// entrega a su `request-id`. Al cerrarse el canal falla lo pendiente.
    private static func read(_ output: AsyncStream<Data>, table: SftpRequestTable, gate: VersionGate) async {
        var framer = SftpFramer()
        var negotiated = false
        do {
            for await chunk in output {
                framer.append(chunk)
                while let packet = try framer.next() {
                    if !negotiated {
                        gate.deliver(Result { () throws(SftpError) in try SftpVersion.parse(packet) })
                        negotiated = true
                    } else {
                        let (id, response) = try SftpResponse.parse(packet)
                        table.resolve(id, with: response)
                    }
                }
            }
            gate.deliver(.failure(.channelClosed))
            table.failAll(.channelClosed)
        } catch {
            gate.deliver(.failure(error))
            table.failAll(error)
        }
    }

    // MARK: - Peticiones (base de T-SFTP-3/4)

    /// Envía una petición y espera su respuesta, sin bloquear otras en vuelo.
    func request(_ type: SftpPacketType, _ body: (inout SftpWriter) -> Void = { _ in }) async throws -> SftpResponse {
        guard !closed else { throw SftpError.channelClosed }
        let id = try table.reserve()
        do {
            try await transport.write(SftpPacket.request(type, id: id, body).encoded())
        } catch {
            table.cancel(id)
            throw SftpError.channelClosed
        }
        return try await table.wait(id)
    }

    /// `SSH_FXP_REALPATH` (p. ej. `"."` → directorio de inicio).
    public func realPath(_ path: String) async throws -> String {
        switch try await request(.realpath, { $0.string(path) }) {
        case .name(let names):
            guard let first = names.first else { throw SftpError.malformedPacket }
            return first.filename
        case .status(let status):
            throw status.error ?? SftpError.malformedPacket
        default:
            throw SftpError.unexpectedResponse(.realpath)
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        table.failAll(.channelClosed)
        reader.cancel()
        await transport.close()
    }
}

/// Espera de VERSION con plazo. `@unchecked Sendable`: estado bajo `lock`.
private final class VersionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<SftpVersion, SftpError>?
    private var continuation: CheckedContinuation<SftpVersion, any Error>?

    func deliver(_ outcome: Result<SftpVersion, SftpError>) {
        let waiter = lock.withLock { () -> CheckedContinuation<SftpVersion, any Error>? in
            guard result == nil else { return nil }
            result = outcome
            defer { continuation = nil }
            return continuation
        }
        waiter?.resume(with: outcome.mapError { $0 as any Error })
    }

    func wait(timeout: Duration) async throws -> SftpVersion {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.deliver(.failure(.timeout)) }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<SftpVersion, SftpError>? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready.mapError { $0 as any Error }) }
        }
    }
}
