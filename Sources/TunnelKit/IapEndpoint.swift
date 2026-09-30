import Foundation

/// Extremos IAP: `wss://tunnel.cloudproxy.app/v4/` (+ `mtls.` con device cert, M4).
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

    public init(project: String, zone: String, instance: String, interface: String = "nic0", port: UInt16) {
        self.project = project
        self.zone = zone
        self.instance = instance
        self.interface = interface
        self.port = port
    }

    /// `.../connect?project&zone&instance&interface&port&_=guid`
    public func connectURL() -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Self.host
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
    public static func reconnectURL(sid: String, ack: UInt64, zone: String) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = Self.host
        components.path = "/v4/reconnect"
        components.queryItems = [
            URLQueryItem(name: "sid", value: sid),
            URLQueryItem(name: "ack", value: String(ack)),
            URLQueryItem(name: "zone", value: zone),
        ]
        return components.url
    }
}
