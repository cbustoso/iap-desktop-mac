import Foundation

// APIs de Compute/OS Login para autorizar llaves SSH efímeras (CBU-44).
// Paridad: `ComputeMetadata`/`MetadataAuthorizedPublicKeySet` y `OsLoginProfile`.

/// Metadata de instancia (`metadata`) o de proyecto (`commonInstanceMetadata`).
public struct ComputeMetadata: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var key: String
        public var value: String?

        public init(key: String, value: String?) {
            self.key = key
            self.value = value
        }
    }

    /// Necesario en `setMetadata` (control de concurrencia optimista).
    public var fingerprint: String?
    public var items: [Item]?

    public init(fingerprint: String? = nil, items: [Item]? = nil) {
        self.fingerprint = fingerprint
        self.items = items
    }

    public func value(for key: String) -> String? {
        items?.first { $0.key == key }?.value
    }

    /// Booleano de metadata tal como lo interpreta GCE (`TRUE`/`true`/`1`).
    public func flag(_ key: String) -> Bool? {
        guard let raw = value(for: key)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        switch raw {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// Añade la llave a `ssh-keys` con el formato de llaves efímeras de Google
    /// (`usuario:tipo base64 google-ssh {"userName":…,"expireOn":…}`) y
    /// elimina las entradas `google-ssh` ya caducadas.
    public func addingEphemeralSSHKey(
        username: String, publicKeyOpenSSH: String, email: String, expiresAt: Date, now: Date = Date()
    ) -> ComputeMetadata {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let keyPart = publicKeyOpenSSH.split(separator: " ").prefix(2).joined(separator: " ")
        let annotation = #"{"userName":"\#(email)","expireOn":"\#(formatter.string(from: expiresAt))"}"#
        let line = "\(username):\(keyPart) google-ssh \(annotation)"

        let kept = (value(for: "ssh-keys") ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !Self.isExpiredGoogleKey($0, now: now) }
        var copy = self
        var newItems = (items ?? []).filter { $0.key != "ssh-keys" }
        newItems.append(Item(key: "ssh-keys", value: (kept + [line]).joined(separator: "\n")))
        copy.items = newItems
        return copy
    }

    static func isExpiredGoogleKey(_ line: String, now: Date) -> Bool {
        guard let range = line.range(of: " google-ssh "),
              let data = line[range.upperBound...].data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expireOn = json["expireOn"] as? String,
              let date = ISO8601DateFormatter().date(from: expireOn)
        else { return false }
        return date <= now
    }
}

/// OS Login efectivo de una instancia: su metadata manda sobre la del proyecto.
public struct OsLoginPolicy: Sendable, Equatable {
    public let enabled: Bool
    public let requiresSecurityKey: Bool

    public init(instance: ComputeMetadata, project: ComputeMetadata) {
        func resolve(_ key: String) -> Bool {
            instance.flag(key) ?? project.flag(key) ?? false
        }
        enabled = resolve("enable-oslogin")
        requiresSecurityKey = enabled && resolve("enable-oslogin-sk")
    }
}

extension GCPClient {
    private static let compute = "https://compute.googleapis.com/compute/v1"

    private struct InstanceResource: Decodable { let metadata: ComputeMetadata? }
    private struct ProjectResource: Decodable { let commonInstanceMetadata: ComputeMetadata? }
    private struct Operation: Decodable { let name: String? }

    public func instanceMetadata(project: String, zone: String, instance: String) async throws -> ComputeMetadata {
        let url = try Self.url("\(Self.compute)/projects/\(Self.escape(project))/zones/\(Self.escape(zone))/instances/\(Self.escape(instance))")
        let resource: InstanceResource = try await get(url)
        return resource.metadata ?? ComputeMetadata()
    }

    public func projectMetadata(project: String) async throws -> ComputeMetadata {
        let url = try Self.url("\(Self.compute)/projects/\(Self.escape(project))")
        let resource: ProjectResource = try await get(url)
        return resource.commonInstanceMetadata ?? ComputeMetadata()
    }

    /// Requiere el `fingerprint` leído antes (si cambió entretanto → HTTP 412).
    public func setInstanceMetadata(
        project: String, zone: String, instance: String, _ metadata: ComputeMetadata
    ) async throws {
        let url = try Self.url(
            "\(Self.compute)/projects/\(Self.escape(project))/zones/\(Self.escape(zone))/instances/\(Self.escape(instance))/setMetadata")
        let _: Operation = try await send("POST", url, body: try JSONEncoder().encode(metadata))
    }

    public func setProjectMetadata(project: String, _ metadata: ComputeMetadata) async throws {
        let url = try Self.url("\(Self.compute)/projects/\(Self.escape(project))/setCommonInstanceMetadata")
        let _: Operation = try await send("POST", url, body: try JSONEncoder().encode(metadata))
    }

    private struct ImportRequest: Encodable {
        let key: String
        let expirationTimeUsec: String
    }

    private struct ImportResponse: Decodable {
        struct LoginProfile: Decodable {
            struct PosixAccount: Decodable {
                let username: String?
                let primary: Bool?
            }
            let posixAccounts: [PosixAccount]?
        }
        let loginProfile: LoginProfile?
    }

    /// Importa la llave en el perfil OS Login de `email` y devuelve el usuario
    /// POSIX principal (paridad `OsLoginProfile.AuthorizeKeyAsync`).
    public func importOsLoginKey(
        email: String, project: String, publicKeyOpenSSH: String, expiresAt: Date
    ) async throws -> String {
        var components = URLComponents(
            string: "https://oslogin.googleapis.com/v1/users/\(Self.escape(email)):importSshPublicKey")!
        components.queryItems = [URLQueryItem(name: "projectId", value: project)]
        guard let url = components.url else { throw GCPClientError.invalidResponse }
        let microseconds = Int64(expiresAt.timeIntervalSince1970 * 1_000_000)
        let body = try JSONEncoder().encode(
            ImportRequest(key: publicKeyOpenSSH, expirationTimeUsec: String(microseconds)))
        let response: ImportResponse = try await send("POST", url, body: body)
        let accounts = response.loginProfile?.posixAccounts ?? []
        guard let username = (accounts.first { $0.primary == true } ?? accounts.first)?.username,
              !username.isEmpty
        else { throw GCPClientError.invalidResponse }
        return username
    }

    private static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? segment
    }

    private static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw GCPClientError.invalidResponse }
        return url
    }
}
