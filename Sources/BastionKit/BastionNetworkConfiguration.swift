import AuthKit
import Foundation
import TunnelKit

/// GH-95 (T-AZ-11, REQ-AZ-9): proxy del sistema para el túnel Bastion con el
/// mismo `ProxyResolver` que IAP (PAC incluido, fail-open a directo):
///
/// - `POST`/`DELETE /api/tokens`: `URLSession` con `connectionProxyDictionary`.
/// - WebSocket: `HTTP CONNECT {dnsName}:443` vía `ProxyConfig`
///   (`NIOBastionWebSocketTransport.proxy`).
///
/// Se resuelve contra `https://{dnsName}`, que es el único host del plano de datos.
public struct BastionNetworkConfiguration: Sendable {
    public let proxy: ProxyConfig?
    /// `URLSession` con el proxy resuelto para `/api/tokens`.
    public let transport: URLSessionBastionTransport
    public let sockets: NIOBastionWebSocketTransport

    public var sessions: BastionSessionClient { BastionSessionClient(transport: transport) }

    public static func resolve(
        for target: BastionTarget,
        resolver: ProxyResolver = ProxyResolver(),
        sockets base: NIOBastionWebSocketTransport = NIOBastionWebSocketTransport()
    ) async -> BastionNetworkConfiguration {
        var components = URLComponents()
        components.scheme = "https"
        components.host = target.dnsName
        guard let url = components.url else {
            return BastionNetworkConfiguration(proxy: nil, transport: URLSessionBastionTransport(), sockets: base)
        }
        let resolved = await resolver.resolve(for: url)
        let configuration = URLSessionConfiguration.ephemeral
        let dictionary = resolved.connectionProxyDictionary
        if !dictionary.isEmpty { configuration.connectionProxyDictionary = dictionary }
        configuration.timeoutIntervalForRequest = BastionSessionClient.requestTimeout
        var sockets = base
        sockets.proxy = resolved.relayProxyConfig
        return BastionNetworkConfiguration(
            proxy: sockets.proxy,
            transport: URLSessionBastionTransport(session: URLSession(configuration: configuration)),
            sockets: sockets)
    }
}

extension BastionTunnelFactory {
    /// Fábrica de producción: proxy del sistema resuelto para `target`,
    /// renovación con `retry` y telemetría OSLog. `invalidateArmToken` debe
    /// olvidar el token cacheado (p. ej. `AzCliTokenSource.clearCache()`).
    public static func systemConfigured(
        target: BastionTarget,
        resolver: ProxyResolver = ProxyResolver(),
        retry: BastionRetryPolicy = .default,
        telemetry: BastionTelemetry = .oslog,
        invalidateArmToken: @escaping BastionSessionPool.ArmTokenInvalidator = {},
        armToken: @escaping BastionSessionPool.ArmTokenProvider
    ) async -> BastionTunnelFactory {
        let network = await BastionNetworkConfiguration.resolve(for: target, resolver: resolver)
        return BastionTunnelFactory(
            target: target, sessions: network.sessions, sockets: network.sockets, retry: retry,
            telemetry: telemetry, invalidateArmToken: invalidateArmToken, armToken: armToken)
    }
}
