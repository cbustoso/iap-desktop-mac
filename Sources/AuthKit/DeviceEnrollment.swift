// GH-68 (REQ-AUTH-5, docs/feature-parity.md "mTLS / BeyondCorp"): identidad de
// dispositivo para mTLS. Paridad `DeviceEnrollment.cs` (Windows busca el
// certificado emitido por "Google Endpoint Verification" en el store del
// usuario). macOS no tiene Endpoint Verification nativo: se busca un
// `SecIdentity` equivalente en el Keychain (desplegado p. ej. por MDM) y, si no
// hay ninguno válido, se DEGRADA a endpoint público con motivo explícito —
// nunca falla la conexión por no tener certificado.
//
// La llave privada no se exporta: solo se usa para firmar (`SecKeyCreateSignature`),
// así funciona también con llaves no extraíbles o del Secure Enclave.
import CryptoKit
import Foundation
import OSLog
import Security

/// Resumen no sensible de un certificado de dispositivo.
public struct DeviceCertificate: Sendable, Equatable, CustomStringConvertible {
    public let derBytes: Data
    /// Identificador del dispositivo en el CN: no va a logs ni a `description`.
    public let subjectCommonName: String?
    public let issuerCommonName: String?
    public let notAfter: Date?
    /// SHA-256 del DER en hex.
    public let sha256Fingerprint: String

    public init?(der: Data) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        self.init(certificate: certificate)
    }

    public init?(certificate: SecCertificate) {
        let der = SecCertificateCopyData(certificate) as Data
        guard !der.isEmpty else { return nil }
        derBytes = der
        var commonName: CFString?
        subjectCommonName = SecCertificateCopyCommonName(certificate, &commonName) == errSecSuccess
            ? commonName as String? : nil
        let values = SecCertificateCopyValues(
            certificate, [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any]
        issuerCommonName = Self.issuerCommonName(values?[kSecOIDX509V1IssuerName])
        notAfter = Self.date(values?[kSecOIDX509V1ValidityNotAfter])
        sha256Fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func isValid(at date: Date) -> Bool {
        guard let notAfter else { return false }
        return date < notAfter
    }

    /// Sin el CN del sujeto (identifica el equipo): emisor, caducidad y huella corta.
    public var description: String {
        "DeviceCertificate(issuer: \(issuerCommonName ?? "?"), notAfter: \(notAfter.map { "\($0)" } ?? "?"), "
            + "sha256: \(sha256Fingerprint.prefix(12))…)"
    }

    private static func issuerCommonName(_ property: Any?) -> String? {
        guard let entries = (property as? [CFString: Any])?[kSecPropertyKeyValue] as? [[CFString: Any]] else { return nil }
        let cn = kSecOIDCommonName as String
        return entries.first { ($0[kSecPropertyKeyLabel] as? String) == cn }?[kSecPropertyKeyValue] as? String
    }

    private static func date(_ property: Any?) -> Date? {
        guard let value = (property as? [CFString: Any])?[kSecPropertyKeyValue] else { return nil }
        if let number = value as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)  // CFAbsoluteTime
        }
        return value as? Date
    }
}

/// Certificado (+ cadena) y llave de firma de un dispositivo enrolado.
/// `@unchecked Sendable`: `SecKey` es inmutable y thread-safe.
public struct DeviceIdentity: @unchecked Sendable, Equatable, CustomStringConvertible {
    public enum KeyKind: Sendable, Equatable {
        case ecP256, ecP384, rsa(bits: Int)
    }

    public let certificate: DeviceCertificate
    /// DER de la cadena a presentar, hoja primero.
    public let chain: [Data]
    public let keyKind: KeyKind
    private let privateKey: SecKey

    public init?(certificate: DeviceCertificate, privateKey: SecKey, intermediates: [Data] = []) {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
              let type = attributes[kSecAttrKeyType] as? String,
              let bits = (attributes[kSecAttrKeySizeInBits] as? NSNumber)?.intValue
        else { return nil }
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        let rsa = kSecAttrKeyTypeRSA as String
        if type == ec, bits == 256 {
            keyKind = .ecP256
        } else if type == ec, bits == 384 {
            keyKind = .ecP384
        } else if type == rsa, bits >= 2048 {
            keyKind = .rsa(bits: bits)
        } else {
            return nil  // tipo/tamaño no apto para TLS cliente
        }
        self.certificate = certificate
        self.privateKey = privateKey
        chain = [certificate.derBytes] + intermediates
    }

    /// Desde un `SecIdentity` del Keychain (la llave se queda en el Keychain).
    public init?(identity: SecIdentity) {
        var certificateRef: SecCertificate?
        var keyRef: SecKey?
        guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess,
              SecIdentityCopyPrivateKey(identity, &keyRef) == errSecSuccess,
              let certificateRef, let keyRef,
              let certificate = DeviceCertificate(certificate: certificateRef)
        else { return nil }
        self.init(certificate: certificate, privateKey: keyRef)
    }

    /// Firma `data` sin exportar la llave.
    public func sign(_ data: Data, algorithm: SecKeyAlgorithm) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            throw DeviceEnrollmentError.signingFailed
        }
        return signature
    }

    public func supports(_ algorithm: SecKeyAlgorithm) -> Bool {
        SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm)
    }

    public static func == (lhs: DeviceIdentity, rhs: DeviceIdentity) -> Bool {
        lhs.certificate == rhs.certificate && lhs.chain == rhs.chain
    }

    public var description: String { "DeviceIdentity(\(certificate), key: \(keyKind), privateKey: <keychain>)" }
}

public enum DeviceEnrollmentError: Error, Sendable, Equatable {
    case signingFailed
    case keychainQueryFailed(OSStatus)
}

/// Paridad `DeviceEnrollmentState`: por qué no hay mTLS, sin datos del equipo.
public enum DeviceEnrollmentState: Sendable, Equatable {
    case enrolled
    case notEnrolled(Reason)

    public enum Reason: String, Sendable, Equatable {
        /// Ningún certificado del emisor esperado (lo normal en macOS).
        case noCertificate = "no-certificate"
        case expired
        /// No se pudo consultar el Keychain: se degrada, nunca se bloquea.
        case keychainUnavailable = "keychain-unavailable"
    }
}

/// Busca la identidad de dispositivo y decide si hay enrolamiento.
public struct DeviceEnrollment: Sendable {
    /// Emisor de los certificados de Endpoint Verification (paridad Windows).
    public static let endpointVerificationIssuer = "Google Endpoint Verification"
    public typealias IdentitySource = @Sendable () throws -> [DeviceIdentity]

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    private let source: IdentitySource
    private let issuerCommonName: String

    public init(source: @escaping IdentitySource = DeviceEnrollment.keychainIdentities,
                issuerCommonName: String = DeviceEnrollment.endpointVerificationIssuer) {
        self.source = source
        self.issuerCommonName = issuerCommonName
    }

    /// Estado + identidad elegida (la vigente que caduca más tarde).
    public func resolve(now: Date = Date()) -> (state: DeviceEnrollmentState, identity: DeviceIdentity?) {
        let candidates: [DeviceIdentity]
        do {
            candidates = try source().filter { $0.certificate.issuerCommonName == issuerCommonName }
        } catch {
            Self.log.notice("device enrollment unavailable reason=keychain-unavailable")
            return (.notEnrolled(.keychainUnavailable), nil)
        }
        guard !candidates.isEmpty else { return (.notEnrolled(.noCertificate), nil) }
        let valid = candidates.filter { $0.certificate.isValid(at: now) }
        guard let best = valid.max(by: { ($0.certificate.notAfter ?? .distantPast) < ($1.certificate.notAfter ?? .distantPast) })
        else { return (.notEnrolled(.expired), nil) }
        return (.enrolled, best)
    }

    /// Identidades del Keychain del usuario (solo referencias: la llave no sale).
    public static let keychainIdentities: IdentitySource = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let array = items as? [Any] else {
            throw DeviceEnrollmentError.keychainQueryFailed(status)
        }
        return array.compactMap { item in
            guard CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
            return DeviceIdentity(identity: item as! SecIdentity)  // tipo comprobado arriba
        }
    }
}
