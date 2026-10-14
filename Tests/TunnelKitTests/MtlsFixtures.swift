// GH-68: fixtures SOLO DE TEST. CA y certificado de dispositivo desechables
// generados con LibreSSL para estos tests (EC P-256); la CA imita el emisor
// "Google Endpoint Verification" para ejercitar la selección por emisor. Las
// llaves no protegen nada real.
import CryptoKit
import Foundation
import Security
import AuthKit

enum MtlsFixtures {
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

    static let devicePEM = """
-----BEGIN CERTIFICATE-----
MIIBeDCCAR+gAwIBAgIJAMAhNt5ZaXdqMAoGCCqGSM49BAMCMDgxDzANBgNVBAoM
Bkdvb2dsZTElMCMGA1UEAwwcR29vZ2xlIEVuZHBvaW50IFZlcmlmaWNhdGlvbjAe
Fw0yNjEwMTQwMjI3MTBaFw0zNjEwMTEwMjI3MTBaMBsxGTAXBgNVBAMMEHRlc3Qt
ZGV2aWNlLTAwMDEwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATb5dsF/fLfajmP
Rce0eh+clVYEy8SnvrCGtB5v158rHP3zhMH3IDuVA4hnQr4S5MoVdpYDStDfp3+O
+R3P4jNsoy8wLTAJBgNVHRMEAjAAMAsGA1UdDwQEAwIHgDATBgNVHSUEDDAKBggr
BgEFBQcDAjAKBggqhkjOPQQDAgNHADBEAiAyg5PnYeYdGlO88SBP112DDVGMIH1b
rd6vUrJPz4pmmAIgGsWXKXzC8KJRr6ZggllUW1HLkMPT/L5BOWzmC0WRnlU=
-----END CERTIFICATE-----
"""

    static let deviceKeyPKCS8 = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg5IvTgE9766XFvSMO
j0YLcblPzyYD+ntqw2a541FZGMKhRANCAATb5dsF/fLfajmPRce0eh+clVYEy8Sn
vrCGtB5v158rHP3zhMH3IDuVA4hnQr4S5MoVdpYDStDfp3+O+R3P4jNs
-----END PRIVATE KEY-----
"""

    static func der(_ pem: String) -> Data {
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64)!
    }

    /// `SecKey` en memoria (sin Keychain) a partir del PKCS#8.
    static func secKey(_ pkcs8: String) -> SecKey {
        let key = try! P256.Signing.PrivateKey(pemRepresentation: pkcs8)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ]
        return SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil)!
    }

    static var deviceIdentity: DeviceIdentity {
        DeviceIdentity(certificate: DeviceCertificate(der: der(devicePEM))!, privateKey: secKey(deviceKeyPKCS8))!
    }
}
