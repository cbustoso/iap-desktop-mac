import Foundation

/// Flujo de bytes bidireccional sobre el que corre SSH (specs/ssh/design.md):
/// SSHKit no conoce WebSocket ni el framing del relay IAP, solo bytes.
///
/// Tiene la misma forma que `TunnelKit.RelayChannel` (`send` / `incoming` /
/// `close`) para que el futuro `SshRelayStream` de TunnelKit (relay v4: SID,
/// DATA, ACK) se adapte sin capa intermedia. Mientras tanto, `SshSession`
/// también puede conectar por TCP al listener local del túnel IAP.
public protocol SshByteStream: Sendable {
    /// Envía bytes en orden. Las llamadas se serializan desde un único emisor.
    func send(_ data: Data) async throws
    /// Bytes recibidos en orden; termina cuando el transporte se cierra.
    func incoming() -> AsyncStream<Data>
    func close() async
    /// Estado del enlace (CBU-42). Por defecto: siempre conectado.
    func linkStates() async -> AsyncStream<SshLinkState>
}
