import CryptoKit
import Foundation
import Security

/// Algorithms supported for ephemeral SSH credentials.
public enum SSHKeyAlgorithm: String, CaseIterable, Sendable {
    case rsa3072
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521

    public var openSSHIdentifier: String {
        switch self {
        case .rsa3072: "ssh-rsa"
        case .ecdsaP256: "ecdsa-sha2-nistp256"
        case .ecdsaP384: "ecdsa-sha2-nistp384"
        case .ecdsaP521: "ecdsa-sha2-nistp521"
        }
    }

    fileprivate var curveIdentifier: String? {
        switch self {
        case .rsa3072: nil
        case .ecdsaP256: "nistp256"
        case .ecdsaP384: "nistp384"
        case .ecdsaP521: "nistp521"
        }
    }

    fileprivate init?(openSSHIdentifier: String) {
        switch openSSHIdentifier {
        case "ssh-rsa": self = .rsa3072
        case "ecdsa-sha2-nistp256": self = .ecdsaP256
        case "ecdsa-sha2-nistp384": self = .ecdsaP384
        case "ecdsa-sha2-nistp521": self = .ecdsaP521
        default: return nil
        }
    }
}

public enum KeyProvisionerError: Error, Equatable, Sendable {
    case keyGenerationFailed(String)
    case publicKeyExportFailed(String)
    case signingFailed(String)
    case invalidValidity
    case keyExpired
    case malformedOpenSSHKey
    case unsupportedAlgorithm(String)
    case invalidPublicKey
}

/// A validated SSH public key in the wire format used by `authorized_keys`.
public struct OpenSSHPublicKey: Sendable, Hashable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let algorithm: SSHKeyAlgorithm
    public let keyBlob: Data

    public var openSSHRepresentation: String {
        "\(algorithm.openSSHIdentifier) \(keyBlob.base64EncodedString())"
    }

    public var description: String { openSSHRepresentation }
    public var debugDescription: String { openSSHRepresentation }

    public init(openSSHRepresentation: String) throws {
        let fields = openSSHRepresentation.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else {
            throw KeyProvisionerError.malformedOpenSSHKey
        }

        let textualIdentifier = String(fields[0])
        guard let algorithm = SSHKeyAlgorithm(openSSHIdentifier: textualIdentifier) else {
            throw KeyProvisionerError.unsupportedAlgorithm(textualIdentifier)
        }
        guard let blob = Data(base64Encoded: String(fields[1])) else {
            throw KeyProvisionerError.malformedOpenSSHKey
        }

        var reader = SSHWireReader(data: blob)
        guard
            let encodedIdentifier = try? reader.readString(),
            String(data: encodedIdentifier, encoding: .utf8) == textualIdentifier
        else {
            throw KeyProvisionerError.malformedOpenSSHKey
        }

        switch algorithm {
        case .rsa3072:
            guard
                let exponent = try? reader.readString(), !exponent.isEmpty,
                let modulus = try? reader.readString(), !modulus.isEmpty,
                reader.isAtEnd,
                Self.makeRSAPublicKey(exponent: exponent, modulus: modulus) != nil
            else {
                throw KeyProvisionerError.invalidPublicKey
            }
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            guard
                let curveData = try? reader.readString(),
                String(data: curveData, encoding: .utf8) == algorithm.curveIdentifier,
                let point = try? reader.readString(), reader.isAtEnd,
                Self.isValidECPoint(point, algorithm: algorithm)
            else {
                throw KeyProvisionerError.invalidPublicKey
            }
        }

        self.algorithm = algorithm
        self.keyBlob = blob
    }

    fileprivate init(algorithm: SSHKeyAlgorithm, keyBlob: Data) {
        self.algorithm = algorithm
        self.keyBlob = keyBlob
    }

    /// Verifies a signature returned by ``KeyProvisioner/sign(challenge:)``.
    public func verify(signature: Data, challenge: Data) -> Bool {
        guard var reader = try? parsedReader() else { return false }

        switch algorithm {
        case .rsa3072:
            guard
                let exponent = try? reader.readString(),
                let modulus = try? reader.readString(),
                let key = Self.makeRSAPublicKey(exponent: exponent, modulus: modulus)
            else { return false }
            return SecKeyVerifySignature(
                key,
                .rsaSignatureMessagePKCS1v15SHA256,
                challenge as CFData,
                signature as CFData,
                nil
            )
        case .ecdsaP256:
            guard
                (try? reader.readString()) != nil,
                let point = try? reader.readString(),
                let key = try? P256.Signing.PublicKey(x963Representation: point),
                let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature)
            else { return false }
            return key.isValidSignature(ecdsaSignature, for: challenge)
        case .ecdsaP384:
            guard
                (try? reader.readString()) != nil,
                let point = try? reader.readString(),
                let key = try? P384.Signing.PublicKey(x963Representation: point),
                let ecdsaSignature = try? P384.Signing.ECDSASignature(derRepresentation: signature)
            else { return false }
            return key.isValidSignature(ecdsaSignature, for: challenge)
        case .ecdsaP521:
            guard
                (try? reader.readString()) != nil,
                let point = try? reader.readString(),
                let key = try? P521.Signing.PublicKey(x963Representation: point),
                let ecdsaSignature = try? P521.Signing.ECDSASignature(derRepresentation: signature)
            else { return false }
            return key.isValidSignature(ecdsaSignature, for: challenge)
        }
    }

    private func parsedReader() throws -> SSHWireReader {
        var reader = SSHWireReader(data: keyBlob)
        _ = try reader.readString()
        return reader
    }

    private static func isValidECPoint(_ point: Data, algorithm: SSHKeyAlgorithm) -> Bool {
        switch algorithm {
        case .rsa3072: false
        case .ecdsaP256: (try? P256.Signing.PublicKey(x963Representation: point)) != nil
        case .ecdsaP384: (try? P384.Signing.PublicKey(x963Representation: point)) != nil
        case .ecdsaP521: (try? P521.Signing.PublicKey(x963Representation: point)) != nil
        }
    }

    private static func makeRSAPublicKey(exponent: Data, modulus: Data) -> SecKey? {
        let representation = DER.sequence([
            DER.positiveInteger(modulus),
            DER.positiveInteger(exponent),
        ])
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, nil)
    }
}

private final class RSAKeyBox: @unchecked Sendable {
    let key: SecKey

    init(key: SecKey) {
        self.key = key
    }
}

private enum EphemeralPrivateKey: Sendable {
    case rsa(RSAKeyBox)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)
}

/// Owns one process-local ephemeral private key and performs signing without exporting it.
public struct KeyProvisioner: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public typealias Algorithm = SSHKeyAlgorithm

    public let algorithm: Algorithm
    public let publicKey: OpenSSHPublicKey
    public let expiresAt: Date
    private let privateKey: EphemeralPrivateKey

    public init(algorithm: Algorithm, validFor validity: TimeInterval = 30 * 60) throws {
        guard validity.isFinite, validity > 0 else {
            throw KeyProvisionerError.invalidValidity
        }
        self.algorithm = algorithm
        expiresAt = Date().addingTimeInterval(validity)

        switch algorithm {
        case .rsa3072:
            var creationError: Unmanaged<CFError>?
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: 3_072,
            ]
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &creationError) else {
                throw KeyProvisionerError.keyGenerationFailed(
                    Self.securityErrorMessage(creationError?.takeRetainedValue()))
            }
            let box = RSAKeyBox(key: key)
            privateKey = .rsa(box)
            publicKey = try Self.makeRSAPublicKey(privateKey: key)
        case .ecdsaP256:
            let key = P256.Signing.PrivateKey()
            privateKey = .p256(key)
            publicKey = Self.makeECPublicKey(
                algorithm: algorithm, point: key.publicKey.x963Representation)
        case .ecdsaP384:
            let key = P384.Signing.PrivateKey()
            privateKey = .p384(key)
            publicKey = Self.makeECPublicKey(
                algorithm: algorithm, point: key.publicKey.x963Representation)
        case .ecdsaP521:
            let key = P521.Signing.PrivateKey()
            privateKey = .p521(key)
            publicKey = Self.makeECPublicKey(
                algorithm: algorithm, point: key.publicKey.x963Representation)
        }
    }

    public func sign(challenge: Data) throws -> Data {
        guard Date() < expiresAt else {
            throw KeyProvisionerError.keyExpired
        }
        switch privateKey {
        case .rsa(let box):
            var signingError: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(
                box.key,
                .rsaSignatureMessagePKCS1v15SHA256,
                challenge as CFData,
                &signingError
            ) else {
                throw KeyProvisionerError.signingFailed(
                    Self.securityErrorMessage(signingError?.takeRetainedValue()))
            }
            return signature as Data
        case .p256(let key):
            return try key.signature(for: challenge).derRepresentation
        case .p384(let key):
            return try key.signature(for: challenge).derRepresentation
        case .p521(let key):
            return try key.signature(for: challenge).derRepresentation
        }
    }

    public var description: String {
        "KeyProvisioner(algorithm: \(algorithm.rawValue), privateKey: <redacted>)"
    }

    public var debugDescription: String { description }

    private static func makeECPublicKey(
        algorithm: Algorithm,
        point: Data
    ) -> OpenSSHPublicKey {
        var blob = Data()
        blob.appendSSHString(Data(algorithm.openSSHIdentifier.utf8))
        blob.appendSSHString(Data(algorithm.curveIdentifier!.utf8))
        blob.appendSSHString(point)
        return OpenSSHPublicKey(algorithm: algorithm, keyBlob: blob)
    }

    private static func makeRSAPublicKey(privateKey: SecKey) throws -> OpenSSHPublicKey {
        guard let key = SecKeyCopyPublicKey(privateKey) else {
            throw KeyProvisionerError.publicKeyExportFailed("Security did not return a public key")
        }
        var exportError: Unmanaged<CFError>?
        guard
            let external = SecKeyCopyExternalRepresentation(key, &exportError) as Data?,
            let components = DER.rsaPublicKeyComponents(external)
        else {
            throw KeyProvisionerError.publicKeyExportFailed(
                securityErrorMessage(exportError?.takeRetainedValue()))
        }

        var blob = Data()
        blob.appendSSHString(Data(Algorithm.rsa3072.openSSHIdentifier.utf8))
        blob.appendSSHString(SSHMPInteger.encode(components.exponent))
        blob.appendSSHString(SSHMPInteger.encode(components.modulus))
        return OpenSSHPublicKey(algorithm: .rsa3072, keyBlob: blob)
    }

    private static func securityErrorMessage(_ error: CFError?) -> String {
        error.map { CFErrorCopyDescription($0) as String } ?? "Unknown Security.framework error"
    }
}

private struct SSHWireReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readString() throws -> Data {
        guard offset <= data.count - 4 else {
            throw KeyProvisionerError.malformedOpenSSHKey
        }
        let length = data[offset..<(offset + 4)].reduce(UInt32.zero) {
            ($0 << 8) | UInt32($1)
        }
        offset += 4
        guard length <= UInt32(data.count - offset) else {
            throw KeyProvisionerError.malformedOpenSSHKey
        }
        let end = offset + Int(length)
        defer { offset = end }
        return data[offset..<end]
    }
}

private extension Data {
    mutating func appendSSHString(_ value: Data) {
        let length = UInt32(value.count)
        append(UInt8((length >> 24) & 0xff))
        append(UInt8((length >> 16) & 0xff))
        append(UInt8((length >> 8) & 0xff))
        append(UInt8(length & 0xff))
        append(value)
    }
}

private enum SSHMPInteger {
    static func encode(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.first.map({ $0 & 0x80 != 0 }) == true {
            value.insert(0, at: value.startIndex)
        }
        return value
    }
}

private enum DER {
    static func rsaPublicKeyComponents(_ data: Data) -> (modulus: Data, exponent: Data)? {
        var reader = DERReader(data: data)
        guard
            let sequence = try? reader.read(tag: 0x30), reader.isAtEnd,
            var sequenceReader = Optional(DERReader(data: sequence)),
            let modulus = try? sequenceReader.read(tag: 0x02),
            let exponent = try? sequenceReader.read(tag: 0x02),
            sequenceReader.isAtEnd
        else { return nil }
        return (SSHMPInteger.encode(modulus), SSHMPInteger.encode(exponent))
    }

    static func positiveInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first.map({ $0 & 0x80 != 0 }) == true {
            value.insert(0, at: value.startIndex)
        }
        return tagged(0x02, value)
    }

    static func sequence(_ values: [Data]) -> Data {
        tagged(0x30, values.reduce(into: Data()) { $0.append($1) })
    }

    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag])
        result.append(contentsOf: encodedLength(value.count))
        result.append(value)
        return result
    }

    private static func encodedLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var value = length
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}

private struct DERReader {
    let data: Data
    private(set) var offset = 0

    init(data: Data) {
        // Los slices de Data conservan los índices base: data[0] sobre un
        // slice 6..<12 hace trap aunque el guard compare contra count.
        // Se rebasan a cero al entrar (buffers de llaves, coste despreciable).
        self.data = Data(data)
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func read(tag expectedTag: UInt8) throws -> Data {
        guard offset < data.count, data[offset] == expectedTag else {
            throw KeyProvisionerError.invalidPublicKey
        }
        offset += 1
        let length = try readLength()
        guard length <= data.count - offset else {
            throw KeyProvisionerError.invalidPublicKey
        }
        let end = offset + length
        defer { offset = end }
        return data[offset..<end]
    }

    private mutating func readLength() throws -> Int {
        guard offset < data.count else { throw KeyProvisionerError.invalidPublicKey }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 { return Int(first) }

        let byteCount = Int(first & 0x7f)
        guard byteCount > 0, byteCount <= MemoryLayout<Int>.size, byteCount <= data.count - offset
        else { throw KeyProvisionerError.invalidPublicKey }

        var length = 0
        for byte in data[offset..<(offset + byteCount)] {
            guard length <= (Int.max - Int(byte)) / 256 else {
                throw KeyProvisionerError.invalidPublicKey
            }
            length = length * 256 + Int(byte)
        }
        offset += byteCount
        return length
    }
}
