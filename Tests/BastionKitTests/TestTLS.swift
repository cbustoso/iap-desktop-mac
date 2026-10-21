// GH-95: TLS SOLO DE TEST para el `wss://` a través del proxy CONNECT. Misma
// CA desechable (EC P-256, LibreSSL) que `Tests/TunnelKitTests/MtlsFixtures.swift`;
// la llave no protege nada real.
import Foundation
import NIOSSL

enum TestTLS {
    static let caPEM = """
-----BEGIN CERTIFICATE-----
MIIBYTCCAQYCCQDaybx7pQwyijAKBggqhkjOPQQDAjA4MQ8wDQYDVQQKDAZHb29n
bGUxJTAjBgNVBAMMHEdvb2dsZSBFbmRwb2ludCBWZXJpZmljYXRpb24wHhcNMjYx
MDE0MDIyNzEwWhcNMzYxMDExMDIyNzEwWjA4MQ8wDQYDVQQKDAZHb29nbGUxJTAj
BgNVBAMMHEdvb2dsZSBFbmRwb2ludCBWZXJpZmljYXRpb24wWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAARC03VPc+GaJBjthZmTG48DjHC2kCwNRndZog73tnnHA7T4
yboMDSwcspfLpzl5pSez7SLtufs95iFk/Df5VyvVMAoGCCqGSM49BAMCA0kAMEYC
IQD3jSiFciYE2P6bRT0AcL3RYk22cwnHJUCHVV68aZzEAAIhAIxV3tQqBeK/G33Z
QNyrjKU2GTlyj4p4y0N0T4I8HikI
-----END CERTIFICATE-----
"""

    static let caKeyPKCS8 = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgWZvPvvNWoERouCdx
grg7Af3IdyZqN75DxHIKLuxLBbmhRANCAARC03VPc+GaJBjthZmTG48DjHC2kCwN
RndZog73tnnHA7T4yboMDSwcspfLpzl5pSez7SLtufs95iFk/Df5VyvV
-----END PRIVATE KEY-----
"""

    static func certificate() throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: [UInt8](caPEM.utf8), format: .pem)
    }

    static func serverConfiguration() throws -> TLSConfiguration {
        TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try certificate())],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](caKeyPKCS8.utf8), format: .pem)))
    }

    /// Confía solo en la CA de test; sin verificar el nombre (el cert no es del dnsName).
    static func clientConfiguration() throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.trustRoots = .certificates([try certificate()])
        configuration.certificateVerification = .noHostnameVerification
        return configuration
    }
}
