import Foundation

/// Fichero remoto abierto (paridad `SftpFileStream`). SFTP v3 no tiene "seek":
/// cada READ/WRITE lleva su offset, así que `seek(to:)` solo mueve el puntero
/// local y reanudar es `seek(to: bytesYaTransferidos)` + seguir.
///
/// `read`/`write` trocean en bloques de `chunkSize` con hasta `window`
/// peticiones en vuelo. Las respuestas se consumen en orden de offset: el
/// puntero solo avanza sobre bytes contiguos confirmados, de modo que tras un
/// corte `offset` es un punto de reanudación seguro (sin huecos ni duplicados).
public actor SftpFileHandle {
    /// Bloque por petición (el de OpenSSH `sftp`).
    public static let chunkSize = 32 * 1024
    /// Peticiones simultáneas por operación.
    public static let window = 8

    public nonisolated let remotePath: String
    public private(set) var offset: UInt64 = 0
    private let channel: SftpChannel
    private let handle: Data
    private var closed = false

    init(channel: SftpChannel, handle: Data, remotePath: String) {
        self.channel = channel
        self.handle = handle
        self.remotePath = remotePath
    }

    /// Solo el puntero local: no genera tráfico de red.
    public func seek(to offset: UInt64) {
        self.offset = offset
    }

    /// Hasta `maxLength` bytes desde `offset`; vacío = EOF. Puede devolver
    /// menos si el servidor acorta una lectura (el resto, en la siguiente).
    /// Si falla tras leer algo, entrega lo leído y el error sale en la siguiente.
    public func read(upTo maxLength: Int) async throws -> Data {
        guard !closed else { throw SftpError.channelClosed }
        guard maxLength > 0 else { return Data() }
        let start = offset
        let end = start + UInt64(maxLength)
        var next = start
        var pending: [(length: Int, id: UInt32)] = []
        var result = Data()
        var contiguous = true
        var failure: (any Error)?

        while true {
            // Rellena la ventana mientras todo vaya bien.
            while contiguous, failure == nil, pending.count < Self.window, next < end {
                let length = Int(min(UInt64(Self.chunkSize), end - next))
                var body = SftpWriter()
                body.string(handle)
                body.uint64(next)
                body.uint32(UInt32(length))
                do {
                    pending.append((length, try await channel.submit(.read, payload: body.data)))
                    next += UInt64(length)
                } catch {
                    failure = error
                }
            }
            guard !pending.isEmpty else { break }
            let chunk = pending.removeFirst()
            do {
                switch try await channel.response(for: chunk.id) {
                case .data(let data):
                    guard contiguous else { break }
                    result.append(data)
                    // Lectura corta: lo posterior dejaría un hueco; se descarta.
                    if data.count < chunk.length { contiguous = false }
                case .status(let status) where status.code == SftpStatus.eof:
                    contiguous = false
                case .status(let status):
                    if contiguous { failure = failure ?? status.error ?? SftpError.malformedPacket }
                    contiguous = false
                default:
                    if contiguous { failure = failure ?? SftpError.unexpectedResponse(.read) }
                    contiguous = false
                }
            } catch {
                if contiguous { failure = failure ?? error }
                contiguous = false
            }
        }
        offset = start + UInt64(result.count)
        if let failure, result.isEmpty { throw failure }
        return result
    }

    /// Escribe todo `data` desde `offset`. Si falla a mitad, `offset` queda en
    /// el final del último bloque contiguo confirmado y se lanza el error.
    public func write(_ data: Data) async throws {
        guard !closed else { throw SftpError.channelClosed }
        let base = offset
        var position = 0
        var confirmed = 0
        var pending: [(end: Int, id: UInt32)] = []
        var failure: (any Error)?
        // Un ACK fallido corta la contigüidad; un envío fallido no anula los
        // bloques ya enviados, cuyos ACK se siguen contando en orden.
        var contiguous = true

        while true {
            while failure == nil, pending.count < Self.window, position < data.count {
                let chunkEnd = min(position + Self.chunkSize, data.count)
                var body = SftpWriter()
                body.string(handle)
                body.uint64(base + UInt64(position))
                body.string(Data(data[data.startIndex + position..<data.startIndex + chunkEnd]))
                do {
                    pending.append((chunkEnd, try await channel.submit(.write, payload: body.data)))
                    position = chunkEnd
                } catch {
                    failure = error
                }
            }
            guard !pending.isEmpty else { break }
            let chunk = pending.removeFirst()
            do {
                switch try await channel.response(for: chunk.id) {
                case .status(let status) where status.code == SftpStatus.ok:
                    if contiguous { confirmed = chunk.end }
                case .status(let status):
                    contiguous = false
                    failure = failure ?? status.error ?? SftpError.malformedPacket
                default:
                    contiguous = false
                    failure = failure ?? SftpError.unexpectedResponse(.write)
                }
            } catch {
                contiguous = false
                failure = failure ?? error
            }
        }
        offset = base + UInt64(confirmed)
        if let failure { throw failure }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await channel.closeHandle(handle)
    }
}
