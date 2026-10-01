import Foundation
import SSHKit

/// Lo que una pestaña de terminal necesita del otro extremo (paridad
/// `IPseudoTerminal`): salida ya decodificada, escritura de teclas, resize del
/// pty y cierre. `SshChannel` (SSHKit) lo cumple; los tests usan un doble.
public protocol TerminalBackend: Sendable {
    /// Texto remoto (UTF-8 ya decodificado en streaming). Termina al cerrarse.
    var output: AsyncStream<String> { get }
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}

extension SshChannel: TerminalBackend {
    public func resize(columns: Int, rows: Int) async throws {
        try await resize(SSHTerminalSize(columns: columns, rows: rows))
    }
}
