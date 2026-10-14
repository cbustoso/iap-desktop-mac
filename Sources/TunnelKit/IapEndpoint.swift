import Foundation

import AuthKit

/// Extremos IAP: `wss://tunnel.cloudproxy.app/v4/` (+ `mtls.` con device cert, GH-68).
/// Cf. `IapClient.cs` / `IapInstanceTarget.cs` (origen C#).
public struct IapEndpoint: Sendable, Equatable {
    public static let host = "tunnel.cloudproxy.app"
    public static let subprotocol = "relay.tunnel.cloudproxy.app"
    public static let origin = "bot:iap-tunneler"
    public static let keepAliveSeconds: UInt64 = 60

    public var project: String
    public var zone: String
    public var instance: String
    public var interface: String
    public var port: UInt16
    /// Host del relay según `ServiceEndpointDirections` (GH-68): público,
    /// `mtls.tunnel.cloudproxy.app` o el endpoint PSC.
    public var serviceHost: String

    public init(
        project: String, zone: String, instance: String, interface: String = "nic0", port: UInt16,
        directions: ServiceEndpointDirections = .publicEndpoint
    ) {
        self.project = project
        self.zone = zone
        self.instance = instance
        self.interface = interface
        self.port = port
        serviceHost = ServiceEndpoint.iapTunnel.host(for: directions)
    }

    /// `.../connect?project&zone&instance&interface&port&_=guid`
    public func connectURL() -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = serviceHost
        components.path = "/v4/connect"
        components.queryItems = [
            URLQueryItem(name: "project", value: project),
            URLQueryItem(name: "zone", value: zone),
            URLQueryItem(name: "instance", value: instance),
            URLQueryItem(name: "interface", value: interface),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "_", value: UUID().uuidString),
        ]
        return components.url
    }

    /// `.../reconnect?sid&ack&zone`
    public static func reconnectURL(sid: String, ack: UInt64, zone: String, host: String = Self.host) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.path = "/v4/reconnect"
        components.queryItems = [
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "ack", value: String(ack)),
            URLQueryItem(name: "zone", value: zone),
        ]
        return components.url
    }
}
