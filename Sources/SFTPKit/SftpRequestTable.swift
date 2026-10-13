import Foundation

/// Pipelining por `request-id`: cada petición reserva un id, se envía, y
/// espera su respuesta; las respuestas pueden llegar en cualquier orden.
///
/// Una respuesta que llega antes de que su emisor llame a `wait` se guarda
/// (no hay carrera entre `write` y `wait`). Clase con `lock` en vez de actor:
/// `resolve` se llama desde el lector del canal sin saltos de aislamiento.
/// `@unchecked Sendable`: todo el estado bajo `lock`.
final class SftpRequestTable: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var waiting: [UInt32: CheckedContinuation<SftpResponse, any Error>] = [:]
    private var early: [UInt32: SftpResponse] = [:]
    private var reserved: Set<UInt32> = []
    private var failure: SftpError?

    /// Reserva el siguiente id (salta los que aún estén en uso al dar la vuelta).
    func reserve() throws(SftpError) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        var id = nextID
        while reserved.contains(id) { id &+= 1 }
        nextID = id &+ 1
        reserved.insert(id)
        return id
    }

    /// Respuesta de `id` (la ya llegada o la siguiente).
    func wait(_ id: UInt32) async throws -> SftpResponse {
        try await withCheckedThrowingContinuation { continuation in
            let outcome: Result<SftpResponse, SftpError>? = lock.withLock {
                if let response = early.removeValue(forKey: id) {
                    reserved.remove(id)
                    return .success(response)
                }
                guard reserved.contains(id) else { return .failure(failure ?? .channelClosed) }
                if let failure {
                    reserved.remove(id)
                    return .failure(failure)
                }
                waiting[id] = continuation
                return nil
            }
            switch outcome {
            case .success(let response): continuation.resume(returning: response)
            case .failure(let error): continuation.resume(throwing: error)
            case nil: break
            }
        }
    }

    /// Entrega la respuesta de `id`. `false` si nadie la reservó (se descarta).
    @discardableResult
    func resolve(_ id: UInt32, with response: SftpResponse) -> Bool {
        let continuation: CheckedContinuation<SftpResponse, any Error>?? = lock.withLock {
            guard reserved.contains(id) else { return .none }
            if let continuation = waiting.removeValue(forKey: id) {
                reserved.remove(id)
                return .some(continuation)
            }
            early[id] = response
            return .some(nil)
        }
        switch continuation {
        case .none: return false
        case .some(let waiter):
            waiter?.resume(returning: response)
            return true
        }
    }

    /// Libera un id cuyo envío falló (nadie esperará su respuesta).
    func cancel(_ id: UInt32) {
        let continuation = lock.withLock { () -> CheckedContinuation<SftpResponse, any Error>? in
            reserved.remove(id)
            early.removeValue(forKey: id)
            return waiting.removeValue(forKey: id)
        }
        continuation?.resume(throwing: SftpError.transferCancelled)
    }

    /// Falla todas las esperas (presentes y futuras) con `error`.
    func failAll(_ error: SftpError) {
        let pending = lock.withLock { () -> [CheckedContinuation<SftpResponse, any Error>] in
            if failure == nil { failure = error }
            let pending = Array(waiting.values)
            for id in waiting.keys { reserved.remove(id) }
            waiting.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(throwing: error) }
    }

    var pendingCount: Int { lock.withLock { reserved.count } }
}
