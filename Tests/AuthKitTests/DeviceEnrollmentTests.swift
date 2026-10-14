// GH-68: identidad de dispositivo, selección por emisor/caducidad, firma sin
// exportar la llave y ServiceEndpointDirections con degradación a público.
import Foundation
import Security
import Testing
@testable import AuthKit

private let identity = MtlsFixtures.deviceIdentity
private let year2030 = Date(timeIntervalSince1970: 1_893_456_000)
private let year2040 = Date(timeIntervalSince1970: 2_208_988_800)

@Suite("DeviceEnrollment (GH-68)")
struct DeviceEnrollmentTests {
    @Test func parsesDeviceCertificate() throws {
        let certificate = try #require(DeviceCertificate(der: MtlsFixtures.der(MtlsFixtures.devicePEM)))
        #expect(certificate.subjectCommonName == "test-device-0001")
        #expect(certificate.issuerCommonName == DeviceEnrollment.endpointVerificationIssuer)
        #expect(certificate.sha256Fingerprint.count == 64)
        #expect(certificate.isValid(at: year2030))
        #expect(!certificate.isValid(at: year2040))
        #expect(DeviceCertificate(der: Data("not a cert".utf8)) == nil)
        // Sin el CN del sujeto (identifica el equipo) ni la huella completa.
        let text = String(describing: certificate)
        #expect(!text.contains("test-device-0001"))
        #expect(!text.contains(certificate.sha256Fingerprint))
        #expect(text.contains("Google Endpoint Verification"))
    }

    @Test func identityExposesKindAndChainButNotTheKey() {
        #expect(identity.keyKind == .ecP256)
        #expect(identity.chain == [MtlsFixtures.der(MtlsFixtures.devicePEM)])
        #expect(String(describing: identity).contains("privateKey: <keychain>"))
        #expect(!String(describing: identity).contains("test-device-0001"))
    }

    @Test func signsWithoutExportingAndVerifiesWithPublicKey() throws {
        let message = Data("tls 1.3 certificate verify".utf8)
        let signature = try identity.sign(message, algorithm: .ecdsaSignatureMessageX962SHA256)
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificate.derBytes as CFData))
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, nil))
        #expect(throws: DeviceEnrollmentError.signingFailed) {
            try identity.sign(message, algorithm: .rsaSignatureMessagePSSSHA256)  // no aplica a una llave EC
        }
    }

    @Test func enrolledWhenAValidEndpointVerificationIdentityExists() {
        let result = DeviceEnrollment(source: { [identity] }).resolve(now: year2030)
        #expect(result.state == .enrolled)
        #expect(result.identity == identity)
    }

    @Test func degradesWithReasonInsteadOfFailing() {
        #expect(DeviceEnrollment(source: { [] }).resolve(now: year2030).state == .notEnrolled(.noCertificate))
        // Otro emisor (p. ej. un certificado corporativo cualquiera): no cuenta.
        #expect(DeviceEnrollment(source: { [identity] }, issuerCommonName: "Other CA").resolve(now: year2030).state
            == .notEnrolled(.noCertificate))
        #expect(DeviceEnrollment(source: { [identity] }).resolve(now: year2040).state == .notEnrolled(.expired))
        struct Locked: Error {}
        let broken = DeviceEnrollment(source: { throw Locked() }).resolve(now: year2030)
        #expect(broken.state == .notEnrolled(.keychainUnavailable))
        #expect(broken.identity == nil)
    }

    @Test func liveKeychainQueryIsReadOnlyAndNeverThrowsForMissingItems() throws {
        // Solo referencias (sin datos ni llaves); en esta máquina puede haber 0..N.
        let identities = try DeviceEnrollment.keychainIdentities()
        #expect(identities.allSatisfy { !$0.chain.isEmpty })
    }
}

@Suite("ServiceEndpointDirections (GH-68)")
struct ServiceEndpointDirectionsTests {
    private let enrolled: (state: DeviceEnrollmentState, identity: DeviceIdentity?) = (.enrolled, identity)

    @Test func iapTunnelHosts() {
        let endpoint = ServiceEndpoint.iapTunnel
        #expect(endpoint.host(for: .publicEndpoint) == "tunnel.cloudproxy.app")
        #expect(endpoint.host(for: .mtls) == "mtls.tunnel.cloudproxy.app")
        #expect(endpoint.host(for: .privateServiceConnect(host: "tunnel-psc.p.googleapis.com")) == "tunnel-psc.p.googleapis.com")
        #expect(ServiceEndpoint(publicHost: "a.example", mtlsHost: nil).host(for: .mtls) == "a.example")
    }

    @Test func enrolledDeviceUsesMtls() {
        let selection = ServiceEndpointResolver.select(for: .iapTunnel, enrollment: enrolled)
        #expect(selection.directions == .mtls)
        #expect(selection.host == "mtls.tunnel.cloudproxy.app")
        #expect(selection.clientIdentity == identity)
        #expect(selection.degradation == nil)
        #expect(selection.proxyDestination == .publicEndpoint)
    }

    @Test func pscAlwaysWinsAndBypassesProxy() {
        let selection = ServiceEndpointResolver.select(for: .iapTunnel, pscHost: "tunnel-psc.p.googleapis.com", enrollment: enrolled)
        #expect(selection.directions == .privateServiceConnect(host: "tunnel-psc.p.googleapis.com"))
        #expect(selection.clientIdentity == nil)
        #expect(selection.proxyDestination == .privateServiceConnect)
    }

    @Test func withoutDeviceIdentityDegradesToPublicWithReason() {
        for reason in [DeviceEnrollmentState.Reason.noCertificate, .expired, .keychainUnavailable] {
            let selection = ServiceEndpointResolver.select(for: .iapTunnel, enrollment: (.notEnrolled(reason), nil))
            #expect(selection.directions == .publicEndpoint)
            #expect(selection.host == "tunnel.cloudproxy.app")
            #expect(selection.clientIdentity == nil)
            #expect(selection.degradation == reason)
            #expect(String(describing: selection).contains("degraded: \(reason.rawValue)"))
        }
        // Servicio sin variante mTLS: público aunque haya identidad.
        let noMtls = ServiceEndpointResolver.select(for: ServiceEndpoint(publicHost: "x.example", mtlsHost: nil), enrollment: enrolled)
        #expect(noMtls.directions == .publicEndpoint)
        #expect(noMtls.clientIdentity == nil)
    }
}
