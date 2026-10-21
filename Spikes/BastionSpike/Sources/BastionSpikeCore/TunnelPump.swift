import Foundation

/// Extremo local del túnel (una conexión TCP aceptada en 127.0.0.1).
public protocol LocalStream: Sendable {
    /// Hasta `maximum` bytes; `nil` = EOF.
    func receive(maximum: Int) async throws -> Data?
    func send(_ data: Data) async throws
    func close() async
}

public enum TunnelPumpError: Error, Equatable {
    /// El servidor mandó un frame de texto: en el CLI rompería `socket.send`.
    case unexpectedTextFrame
}

public struct PumpResult: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case localEOF
        case remoteClosed
        case failed(String)
    }

    public var reason: Reason
    public var bytesUp: Int
    public var bytesDown: Int
}

/// Bombeo bidireccional sin framing propio (research §3.3 (3)):
/// TCP → WS un frame binario por lectura de ≤ 4096 B; WS → TCP cada mensaje tal
/// cual. Cuando un sentido termina se cierran ambos extremos.
public enum TunnelPump {
    public static let readChunk = 4096

    private enum Leg: Sendable {
        case up(bytes: Int, reason: PumpResult.Reason)
        case down(bytes: Int, reason: PumpResult.Reason)
    }

    public static func run(local: any LocalStream, socket: any TunnelSocket) async -> PumpResult {
        await withTaskGroup(of: Leg.self) { group in
            group.addTask {
                var bytes = 0
                do {
                    while let chunk = try await local.receive(maximum: readChunk) {
                        guard !chunk.isEmpty else { continue }
                        try await socket.send(chunk)
                        bytes += chunk.count
                    }
                    return .up(bytes: bytes, reason: .localEOF)
                } catch {
                    return .up(bytes: bytes, reason: .failed("TCP→WS: \(error)"))
                }
            }
            group.addTask {
                var bytes = 0
                do {
                    for await message in socket.inbound {
                        switch message {
                        case .binary(let data):
                            try await local.send(data)
                            bytes += data.count
                        case .text:
                            throw TunnelPumpError.unexpectedTextFrame
                        }
                    }
                    return .down(bytes: bytes, reason: .remoteClosed)
                } catch {
                    return .down(bytes: bytes, reason: .failed("WS→TCP: \(error)"))
                }
            }

            var result = PumpResult(reason: .localEOF, bytesUp: 0, bytesDown: 0)
            var first = true
            while let leg = await group.next() {
                let reason: PumpResult.Reason
                switch leg {
                case .up(let bytes, let why):
                    result.bytesUp = bytes
                    reason = why
                case .down(let bytes, let why):
                    result.bytesDown = bytes
                    reason = why
                }
                if first {
                    // El primero que termina decide; cerrar ambos desbloquea al otro.
                    first = false
                    result.reason = reason
                    await socket.close()
                    await local.close()
                }
            }
            return result
        }
    }
}
