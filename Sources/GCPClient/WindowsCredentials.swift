import Foundation
import Security

// CBU-52 (T-RDP-8): reset de contraseña Windows vía el agente de GCE.
// Paridad `Apis/Compute/WindowsCredentialGenerator.cs`: llave RSA-2048 efímera,
// payload en metadata `windows-keys`, respuesta cifrada (OAEP) en el puerto
// serie 4. La contraseña nunca se registra ni se escribe a disco.

/// Usuario y contraseña Windows recién generados. `description`/`dump` no
/// muestran la contraseña.
public struct WindowsCredential: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "WindowsCredential(username: \(username), password: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["username": username, "password": "<redacted>"]) }
}

public enum WindowsCredentialError: Error, Equatable, Sendable {
    /// Falta `compute.instances.setMetadata` (comprobado antes de generar la llave).
    case permissionDenied
    /// La VM usa una service account y falta el rol "Service Account User".
    case serviceAccountUserRequired
    case instanceNotFound
    /// El agente de la VM respondió con un error (texto del agente).
    case agentError(String)
    /// El agente no respondió a tiempo (¿agente parado o account manager apagado?).
    case timeout
    case keyGenerationFailed
    case decryptionFailed
    /// Otro error HTTP de Compute.
    case api(status: Int, reason: String?)

    public var message: String {
        switch self {
        case .permissionDenied:
            return "No tienes permiso para resetear la contraseña Windows: hacen falta los roles "
                + "'Compute Instance Admin' y 'Service Account User' (o equivalentes)."
        case .serviceAccountUserRequired:
            return "La VM usa una service account: además necesitas el rol 'Service Account User'."
        case .instanceNotFound:
            return "La instancia no existe."
        case .agentError(let text):
            return "El agente de la VM no pudo crear el usuario: \(text)"
        case .timeout:
            return "El agente de Compute Engine no respondió. Verifica que está en ejecución "
                + "y que el account manager está habilitado."
        case .keyGenerationFailed:
            return "No se pudo generar la llave RSA temporal."
        case .decryptionFailed:
            return "No se pudo descifrar la respuesta del agente."
        case .api(let status, let reason):
            return "Compute respondió HTTP \(status)\(reason.map { " (\($0))" } ?? "")."
        }
    }
}

extension GCPClient {
    static let windowsKeysMetadataKey = "windows-keys"
    static let windowsSerialPort = 4

    private static func instanceURL(_ project: String, _ zone: String, _ instance: String, _ suffix: String = "") -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        return URL(string: "https://compute.googleapis.com/compute/v1/projects/\(segment(project))"
            + "/zones/\(segment(zone))/instances/\(segment(instance))\(suffix)")!
    }

    /// `testIamPermissions` sobre la instancia (paridad
    /// `IsGrantedPermissionToCreateWindowsCredentialsAsync`).
    public func canResetWindowsCredentials(project: String, zone: String, instance: String) async throws -> Bool {
        struct Permissions: Codable { let permissions: [String]? }
        let permission = "compute.instances.setMetadata"
        let body = try JSONEncoder().encode(Permissions(permissions: [permission]))
        do {
            let data = try await fetch("POST", Self.instanceURL(project, zone, instance, "/testIamPermissions"), body: body)
            return try JSONDecoder().decode(Permissions.self, from: data).permissions?.contains(permission) == true
        } catch let failure as GoogleAPIFailure where failure.status == 403 {
            return false
        } catch let failure as GoogleAPIFailure where failure.status == 404 {
            throw WindowsCredentialError.instanceNotFound
        }
    }

    /// Crea o resetea `username` en la VM y devuelve su contraseña nueva.
    /// - Parameters:
    ///   - timeout: espera máxima a la respuesta del agente.
    ///   - pollInterval: pausa entre lecturas vacías del puerto serie.
    public func resetWindowsCredentials(
        project: String, zone: String, instance: String,
        username: String, addToAdministrators: Bool = true,
        timeout: Duration = .seconds(60), pollInterval: Duration = .milliseconds(500),
        now: Date = Date()
    ) async throws -> WindowsCredential {
        guard try await canResetWindowsCredentials(project: project, zone: zone, instance: instance) else {
            throw WindowsCredentialError.permissionDenied
        }
        let key = try EphemeralRsaKey()
        let request = WindowsKeyRequest(
            userName: username, email: username, expireOn: now.addingTimeInterval(5 * 60),
            modulus: key.modulus.base64EncodedString(), exponent: key.exponent.base64EncodedString(),
            addToAdministrators: addToAdministrators, hashFunction: "sha256")
        try await publishWindowsKeyRequest(request, project: project, zone: zone, instance: instance)

        let encrypted = try await awaitAgentResponse(
            modulus: request.modulus, project: project, zone: zone, instance: instance,
            timeout: timeout, pollInterval: pollInterval)
        if let error = encrypted.errorMessage, !error.isEmpty { throw WindowsCredentialError.agentError(error) }
        guard let cipher = encrypted.encryptedPassword.flatMap({ Data(base64Encoded: $0) }) else {
            throw WindowsCredentialError.agentError("respuesta vacía")
        }
        let algorithm: SecKeyAlgorithm = encrypted.hashFunction == "sha256"
            ? .rsaEncryptionOAEPSHA256 : .rsaEncryptionOAEPSHA1
        guard let plain = SecKeyCreateDecryptedData(key.privateKey, algorithm, cipher as CFData, nil) as Data?,
              let password = String(data: plain, encoding: .utf8)
        else { throw WindowsCredentialError.decryptionFailed }
        return WindowsCredential(username: username, password: password)
    }

    /// Lectura incremental del puerto serie (`next` es el offset siguiente).
    public func serialPortOutput(
        project: String, zone: String, instance: String, port: Int, start: Int64?
    ) async throws -> (contents: String, next: Int64?) {
        var components = URLComponents(
            url: Self.instanceURL(project, zone, instance, "/serialPort"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "port", value: String(port))]
            + (start.map { [URLQueryItem(name: "start", value: String($0))] } ?? [])
        let output: SerialPortOutput = try await get(components.url!)
        return (output.contents ?? "", output.next.flatMap { Int64($0.value) })
    }

    // MARK: - Pasos

    /// Lee la metadata (fingerprint), sustituye `windows-keys` y la publica;
    /// reintenta si otro cliente la cambió entretanto (HTTP 412).
    private func publishWindowsKeyRequest(
        _ request: WindowsKeyRequest, project: String, zone: String, instance: String
    ) async throws {
        let payload = String(decoding: try JSONEncoder.windowsKeys.encode(request), as: UTF8.self)
        var attempt = 0
        while true {
            do {
                struct InstanceResource: Decodable { let metadata: ComputeMetadata? }
                let data = try await fetch("GET", Self.instanceURL(project, zone, instance), body: nil)
                var metadata = try JSONDecoder().decode(InstanceResource.self, from: data).metadata ?? ComputeMetadata()
                metadata.items = (metadata.items ?? []).filter { $0.key != Self.windowsKeysMetadataKey }
                    + [ComputeMetadata.Item(key: Self.windowsKeysMetadataKey, value: payload)]
                _ = try await fetch(
                    "POST", Self.instanceURL(project, zone, instance, "/setMetadata"),
                    body: try JSONEncoder().encode(metadata))
                return
            } catch let failure as GoogleAPIFailure {
                switch failure.status {
                case 412 where attempt < 3:
                    attempt += 1
                case 404:
                    throw WindowsCredentialError.instanceNotFound
                case 403:
                    throw WindowsCredentialError.permissionDenied
                case 400 where Self.isServiceAccountAccessDenied(failure):
                    throw WindowsCredentialError.serviceAccountUserRequired
                default:
                    throw WindowsCredentialError.api(status: failure.status, reason: failure.reason)
                }
            }
        }
    }

    static func isServiceAccountAccessDenied(_ failure: GoogleAPIFailure) -> Bool {
        [failure.reason, failure.message].contains { $0?.contains("SERVICE_ACCOUNT_ACCESS_DENIED") == true }
    }

    private func awaitAgentResponse(
        modulus: String, project: String, zone: String, instance: String,
        timeout: Duration, pollInterval: Duration
    ) async throws -> WindowsKeyResponse {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var offset: Int64?
        var buffer = ""
        while clock.now < deadline {
            try Task.checkCancellation()
            let chunk = try await serialPortOutput(
                project: project, zone: zone, instance: instance, port: Self.windowsSerialPort, start: offset)
            offset = chunk.next ?? offset
            if !chunk.contents.isEmpty {
                buffer += chunk.contents
                if let response = Self.agentResponse(in: buffer, modulus: modulus) { return response }
                // Solo la última línea (quizá incompleta) puede aún contener la respuesta.
                buffer = String(buffer.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            }
            try await Task.sleep(for: min(pollInterval, max(.zero, deadline - clock.now)))
        }
        throw WindowsCredentialError.timeout
    }

    /// Respuesta del agente para `modulus` (una línea JSON del puerto serie).
    static func agentResponse(in log: String, modulus: String) -> WindowsKeyResponse? {
        for line in log.split(separator: "\n") {
            let normalized = line.replacingOccurrences(of: "\\/", with: "/")
            guard normalized.contains(modulus), let start = line.firstIndex(of: "{") else { continue }
            if let response = try? JSONDecoder().decode(WindowsKeyResponse.self, from: Data(line[start...].utf8)) {
                return response
            }
        }
        return nil
    }
}

// MARK: - Tipos del protocolo del agente

struct WindowsKeyRequest: Codable, Equatable {
    let userName: String
    let email: String
    let expireOn: Date
    let modulus: String
    let exponent: String
    let addToAdministrators: Bool
    let hashFunction: String
}

struct WindowsKeyResponse: Decodable, Equatable {
    let encryptedPassword: String?
    let errorMessage: String?
    let hashFunction: String?
}

private struct SerialPortOutput: Decodable {
    let contents: String?
    let next: FlexibleInt?
}

/// Compute serializa int64 como string; se aceptan ambos.
private struct FlexibleInt: Decodable {
    let value: String
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text } else { value = String(try container.decode(Int64.self)) }
    }
}

extension JSONEncoder {
    static var windowsKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

/// Par RSA-2048 en memoria (nunca en el llavero). `@unchecked Sendable`:
/// `SecKey` es inmutable y thread-safe.
struct EphemeralRsaKey: @unchecked Sendable {
    let privateKey: SecKey
    /// Big-endian sin ceros a la izquierda (como `RSAParameters` en .NET).
    let modulus: Data
    let exponent: Data

    init() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false,
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let (modulus, exponent) = Self.parsePkcs1(der)
        else { throw WindowsCredentialError.keyGenerationFailed }
        self.privateKey = privateKey
        self.modulus = modulus
        self.exponent = exponent
    }

    /// `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    static func parsePkcs1(_ der: Data) -> (Data, Data)? {
        var bytes = ArraySlice([UInt8](der))
        func length() -> Int? {
            guard let first = bytes.popFirst() else { return nil }
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7f)
            guard count <= 4, bytes.count >= count else { return nil }
            var value = 0
            for _ in 0..<count { value = value << 8 | Int(bytes.removeFirst()) }
            return value
        }
        func integer() -> Data? {
            guard bytes.popFirst() == 0x02, let size = length(), bytes.count >= size else { return nil }
            let value = bytes.prefix(size).drop { $0 == 0 }
            bytes = bytes.dropFirst(size)
            return Data(value)
        }
        guard bytes.popFirst() == 0x30, length() != nil, let modulus = integer(), let exponent = integer() else {
            return nil
        }
        return (modulus, exponent)
    }
}
