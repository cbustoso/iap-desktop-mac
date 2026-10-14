// GH-68: mTLS para el relay (`wss://mtls.tunnel.cloudproxy.app`) sin
// reescribir el transporte: WebSocketKit ya acepta `tlsConfiguration`; aquí se
// construye con la cadena del dispositivo y una llave "custom" de NIOSSL que
// firma con el `SecKey` del Keychain (la llave nunca se exporta a BoringSSL).
import AuthKit
import Foundation
import NIOCore
import NIOSSL
import Security
import WebSocketKit

extension NIOWebSocketTransport {
    /// Configuración de WebSocketKit: sin identidad, la de siempre (TLS por
    /// defecto); con identidad, TLS con certificado de cliente.
    func webSocketConfiguration() throws -> WebSocketClient.Configuration {
        WebSocketClient.Configuration(
            tlsConfiguration: try clientIdentity.map(DeviceTLS.clientConfiguration(for:)),
            maxFrameSize: maxFrameSize)
    }
}

enum DeviceTLS {
    /// TLS de cliente que presenta `identity` (verificación del servidor por defecto).
    static func clientConfiguration(for identity: DeviceIdentity) throws -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateChain = try identity.chain.map {
            .certificate(try NIOSSLCertificate(bytes: [UInt8]($0), format: .der))
        }
        configuration.privateKey = .privateKey(NIOSSLPrivateKey(customPrivateKey: KeychainSigningKey(identity: identity)))
        return configuration
    }
}

/// Llave privada de NIOSSL respaldada por el `SecKey` del dispositivo.
struct KeychainSigningKey: NIOSSLCustomPrivateKey, Hashable {
    let identity: DeviceIdentity

    /// Algoritmos que se ofrecen en el handshake según el tipo de llave.
    var signatureAlgorithms: [SignatureAlgorithm] {
        switch identity.keyKind {
        case .ecP256: return [.ecdsaSecp256R1Sha256]
        case .ecP384: return [.ecdsaSecp384R1Sha384]
        case .rsa: return [.rsaPssRsaeSha256, .rsaPssRsaeSha384, .rsaPkcs1Sha256, .rsaPkcs1Sha384]
        }
    }

    static func secKeyAlgorithm(for algorithm: SignatureAlgorithm) -> SecKeyAlgorithm? {
        switch algorithm {
        case .ecdsaSecp256R1Sha256: return .ecdsaSignatureMessageX962SHA256
        case .ecdsaSecp384R1Sha384: return .ecdsaSignatureMessageX962SHA384
        case .rsaPssRsaeSha256: return .rsaSignatureMessagePSSSHA256
        case .rsaPssRsaeSha384: return .rsaSignatureMessagePSSSHA384
        case .rsaPkcs1Sha256: return .rsaSignatureMessagePKCS1v15SHA256
        case .rsaPkcs1Sha384: return .rsaSignatureMessagePKCS1v15SHA384
        default: return nil
        }
    }

    func sign(channel: Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        guard let secAlgorithm = Self.secKeyAlgorithm(for: algorithm) else {
            return channel.eventLoop.makeFailedFuture(DeviceEnrollmentError.signingFailed)
        }
        do {
            let signature = try identity.sign(Data(data.readableBytesView), algorithm: secAlgorithm)
            return channel.eventLoop.makeSucceededFuture(channel.allocator.buffer(bytes: signature))
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    /// Intercambio de claves RSA (TLS ≤ 1.2 sin ECDHE): no soportado.
    func decrypt(channel: Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        channel.eventLoop.makeFailedFuture(DeviceEnrollmentError.signingFailed)
    }

    static func == (lhs: KeychainSigningKey, rhs: KeychainSigningKey) -> Bool {
        lhs.identity.certificate.sha256Fingerprint == rhs.identity.certificate.sha256Fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity.certificate.sha256Fingerprint)
    }
}
