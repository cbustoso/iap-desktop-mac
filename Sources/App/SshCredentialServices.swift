import Foundation
import GCPClient
import SSHKit

/// Implementación GCP de los puertos de `CredentialResolver` (SSHKit):
/// OS Login (REST) y publicación de la llave efímera en metadata.
/// Paridad `PlatformCredentialFactory` + `MetadataAuthorizedPublicKeyProcessor`.
struct GCPSshCredentialServices: InstanceOsLoginStatusProviding, OsLoginKeyAuthorizing, MetadataKeyPublishing {
    enum ServiceError: Error {
        case notSignedIn
        case projectKeysBlocked
    }

    let client: GCPClient
    let email: @Sendable () async -> String?
    /// Igual que la validez de `KeyProvisioner` (30 min).
    var keyValidity: TimeInterval = 30 * 60

    func osLoginStatus(project: String, zone: String, instance: String) async throws -> InstanceOsLoginStatus {
        let instanceMetadata = try await client.instanceMetadata(project: project, zone: zone, instance: instance)
        // Sin permiso de lectura del proyecto, solo cuenta la instancia.
        let projectMetadata = (try? await client.projectMetadata(project: project)) ?? ComputeMetadata()
        let policy = OsLoginPolicy(instance: instanceMetadata, project: projectMetadata)
        return InstanceOsLoginStatus(isEnabled: policy.enabled, requiresSecurityKey: policy.requiresSecurityKey)
    }

    func authorizeViaOsLogin(
        project: String, zone: String, instance: String, publicKeyOpenSSH: String
    ) async throws -> AuthorizedCredential {
        guard let email = await email() else { throw ServiceError.notSignedIn }
        let username = try await client.importOsLoginKey(
            email: email, project: project, publicKeyOpenSSH: publicKeyOpenSSH,
            expiresAt: Date().addingTimeInterval(keyValidity))
        return AuthorizedCredential(username: username, method: .osLogin)
    }

    func publishToMetadata(
        project: String, zone: String, instance: String,
        publicKeyOpenSSH: String, username: String, allowedMethods: KeyAuthorizationMethods
    ) async throws -> AuthorizedCredential {
        guard let email = await email() else { throw ServiceError.notSignedIn }
        let expiresAt = Date().addingTimeInterval(keyValidity)

        var blockedProjectKeys = false
        if allowedMethods.contains(.instanceMetadata) {
            do {
                try await updateWithRetry {
                    let current = try await client.instanceMetadata(project: project, zone: zone, instance: instance)
                    blockedProjectKeys = current.flag("block-project-ssh-keys") ?? false
                    try await client.setInstanceMetadata(
                        project: project, zone: zone, instance: instance,
                        current.addingEphemeralSSHKey(
                            username: username, publicKeyOpenSSH: publicKeyOpenSSH, email: email, expiresAt: expiresAt))
                }
                return AuthorizedCredential(username: username, method: .instanceMetadata)
            } catch GCPClientError.apiError(403, _) where allowedMethods.contains(.projectMetadata) {
                // Sin permiso sobre la instancia: se intenta a nivel proyecto.
            }
        }
        guard allowedMethods.contains(.projectMetadata) else { throw SshAuthError.metadataAuthorizationNotAllowed }
        guard !blockedProjectKeys else { throw ServiceError.projectKeysBlocked }
        try await updateWithRetry {
            let current = try await client.projectMetadata(project: project)
            try await client.setProjectMetadata(
                project: project,
                current.addingEphemeralSSHKey(
                    username: username, publicKeyOpenSSH: publicKeyOpenSSH, email: email, expiresAt: expiresAt))
        }
        return AuthorizedCredential(username: username, method: .projectMetadata)
    }

    /// `setMetadata` falla con 412 si otro cliente cambió la metadata entre la
    /// lectura y la escritura (fingerprint): se relee y reintenta.
    private func updateWithRetry(_ update: () async throws -> Void) async throws {
        for attempt in 1...3 {
            do {
                try await update()
                return
            } catch GCPClientError.apiError(412, _) where attempt < 3 {
                continue
            }
        }
    }
}
