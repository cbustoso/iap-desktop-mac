// GH-68: paridad `ServiceEndpointDirections {Public, PSC, mTLS}` y
// `PscAndMtlsAwareHttpClientFactory`: PSC manda (sin proxy ni mTLS); si no, mTLS
// cuando hay identidad de dispositivo y el servicio tiene endpoint mTLS; si no,
// público. La degradación a público se reporta con motivo (sin datos del equipo).
import Foundation
import OSLog

public enum ServiceEndpointDirections: Sendable, Equatable {
    case publicEndpoint
    /// Private Service Connect: host privado configurado por el usuario.
    case privateServiceConnect(host: String)
    case mtls
}

/// Hosts público y mTLS de un servicio.
public struct ServiceEndpoint: Sendable, Equatable {
    public let publicHost: String
    /// `nil` si el servicio no tiene variante mTLS.
    public let mtlsHost: String?

    public init(publicHost: String, mtlsHost: String?) {
        self.publicHost = publicHost
        self.mtlsHost = mtlsHost
    }

    /// Relay de IAP TCP forwarding (`wss://tunnel.cloudproxy.app/v4/`, `mtls.` con certificado).
    public static let iapTunnel = ServiceEndpoint(publicHost: "tunnel.cloudproxy.app", mtlsHost: "mtls.tunnel.cloudproxy.app")

    public func host(for directions: ServiceEndpointDirections) -> String {
        switch directions {
        case .publicEndpoint: return publicHost
        case .privateServiceConnect(let host): return host
        case .mtls: return mtlsHost ?? publicHost
        }
    }
}

/// Decisión de endpoint para una conexión.
public struct EndpointSelection: Sendable, Equatable, CustomStringConvertible {
    public let directions: ServiceEndpointDirections
    public let host: String
    /// Solo con `.mtls`.
    public let clientIdentity: DeviceIdentity?
    /// Por qué no se usó mTLS (`nil` si se usa, o si PSC lo excluye por diseño).
    public let degradation: DeviceEnrollmentState.Reason?

    /// PSC bypassa siempre el proxy del sistema (paridad `UseProxy=false si PSC`).
    public var proxyDestination: ProxyResolver.Destination {
        if case .privateServiceConnect = directions { return .privateServiceConnect }
        return .publicEndpoint
    }

    public var description: String {
        let mode: String
        switch directions {
        case .publicEndpoint: mode = "public"
        case .privateServiceConnect: mode = "psc"
        case .mtls: mode = "mtls"
        }
        return "EndpointSelection(\(mode), host: \(host)\(degradation.map { ", degraded: \($0.rawValue)" } ?? ""))"
    }
}

public enum ServiceEndpointResolver {
    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    /// - Parameters:
    ///   - pscHost: endpoint PSC configurado (gana siempre).
    ///   - enrollment: resultado de `DeviceEnrollment.resolve()`.
    public static func select(
        for endpoint: ServiceEndpoint, pscHost: String? = nil,
        enrollment: (state: DeviceEnrollmentState, identity: DeviceIdentity?)
    ) -> EndpointSelection {
        if let pscHost, !pscHost.isEmpty {
            return EndpointSelection(directions: .privateServiceConnect(host: pscHost), host: pscHost, clientIdentity: nil, degradation: nil)
        }
        if endpoint.mtlsHost != nil, case .enrolled = enrollment.state, let identity = enrollment.identity {
            return EndpointSelection(directions: .mtls, host: endpoint.host(for: .mtls), clientIdentity: identity, degradation: nil)
        }
        let reason: DeviceEnrollmentState.Reason
        switch enrollment.state {
        case .notEnrolled(let why): reason = why
        case .enrolled: reason = .noCertificate  // enrolado sin identidad utilizable, o servicio sin mTLS
        }
        log.notice("mtls degraded to public host=\(endpoint.publicHost, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        return EndpointSelection(directions: .publicEndpoint, host: endpoint.publicHost, clientIdentity: nil, degradation: reason)
    }
}
