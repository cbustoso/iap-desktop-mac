// SSHKit T-SSH-3 tests: CredentialResolver (OS Login vs metadata ssh-keys), con
// mocks que simulan las respuestas de GCPClient (enable-oslogin, import/sign OS
// Login, publicación en metadata). Ref: specs/ssh/requirements.md REQ-SSH-3, REQ-SSH-7.
import Testing
@testable import SSHKit

private struct MockOsLoginStatusProvider: InstanceOsLoginStatusProviding {
    let status: InstanceOsLoginStatus

    func osLoginStatus(project: String, zone: String, instance: String) async throws -> InstanceOsLoginStatus {
        status
    }
}

private struct MockOsLoginAuthorizer: OsLoginKeyAuthorizing {
    func authorizeViaOsLogin(
        project: String, zone: String, instance: String, publicKeyOpenSSH: String
    ) async throws -> AuthorizedCredential {
        AuthorizedCredential(username: "oslogin-user", method: .osLogin)
    }
}

private struct FailingOsLoginAuthorizer: OsLoginKeyAuthorizing {
    func authorizeViaOsLogin(
        project: String, zone: String, instance: String, publicKeyOpenSSH: String
    ) async throws -> AuthorizedCredential {
        Issue.record("no debe llamarse cuando OS Login está deshabilitado o bloqueado")
        throw SshAuthError.osLoginRequired
    }
}

private struct MockMetadataPublisher: MetadataKeyPublishing {
    func publishToMetadata(
        project: String, zone: String, instance: String,
        publicKeyOpenSSH: String, username: String,
        allowedMethods: KeyAuthorizationMethods
    ) async throws -> AuthorizedCredential {
        AuthorizedCredential(
            username: username,
            method: allowedMethods.contains(.instanceMetadata) ? .instanceMetadata : .projectMetadata)
    }
}

private struct FailingMetadataPublisher: MetadataKeyPublishing {
    func publishToMetadata(
        project: String, zone: String, instance: String,
        publicKeyOpenSSH: String, username: String,
        allowedMethods: KeyAuthorizationMethods
    ) async throws -> AuthorizedCredential {
        Issue.record("no debe llamarse cuando OS Login está habilitado")
        throw SshAuthError.metadataAuthorizationNotAllowed
    }
}

@Suite("CredentialResolver — OS Login vs metadata")
struct CredentialResolverTests {
    @Test func osLoginEnabledUsesOsLoginAuthorizer() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: true, requiresSecurityKey: false)),
            osLoginAuthorizer: MockOsLoginAuthorizer(),
            metadataPublisher: FailingMetadataPublisher())

        let credential = try await resolver.resolve(
            project: "demo-web", zone: "europe-west1-b", instance: "web-01",
            publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: nil,
            emailHint: "alice@example.com")

        #expect(credential.method == .osLogin)
        #expect(credential.username == "oslogin-user")
    }

    @Test func osLoginDisabledUsesMetadataPublisher() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: false, requiresSecurityKey: false)),
            osLoginAuthorizer: FailingOsLoginAuthorizer(),
            metadataPublisher: MockMetadataPublisher())

        let credential = try await resolver.resolve(
            project: "demo-web", zone: "europe-west1-b", instance: "web-01",
            publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: "alice",
            emailHint: "alice@example.com")

        #expect(credential.method == .instanceMetadata || credential.method == .projectMetadata)
        #expect(credential.username == "alice")
    }

    @Test func osLoginDisabledDerivesUsernameFromEmailWhenNoPreference() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: false, requiresSecurityKey: false)),
            osLoginAuthorizer: FailingOsLoginAuthorizer(),
            metadataPublisher: MockMetadataPublisher())

        let credential = try await resolver.resolve(
            project: "demo-web", zone: "europe-west1-b", instance: "web-01",
            publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: nil,
            emailHint: "Bob.Smith@example.com")

        #expect(credential.username == "bob_smith")
    }

    @Test func invalidPreferredUsernameThrowsTyped() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: false, requiresSecurityKey: false)),
            osLoginAuthorizer: FailingOsLoginAuthorizer(),
            metadataPublisher: FailingMetadataPublisher())

        await #expect(throws: SshAuthError.invalidUsername("-bad")) {
            try await resolver.resolve(
                project: "demo-web", zone: "europe-west1-b", instance: "web-01",
                publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: "-bad",
                emailHint: "alice@example.com")
        }
    }

    @Test func securityKeyRequiredThrowsTyped() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: true, requiresSecurityKey: true)),
            osLoginAuthorizer: FailingOsLoginAuthorizer(),
            metadataPublisher: FailingMetadataPublisher())

        await #expect(throws: SshAuthError.osLoginSecurityKeyNotSupported) {
            try await resolver.resolve(
                project: "demo-web", zone: "europe-west1-b", instance: "win-bastion",
                publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: nil,
                emailHint: "alice@example.com")
        }
    }

    @Test func osLoginEnabledButNotAllowedByPolicyThrowsTyped() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: true, requiresSecurityKey: false)),
            osLoginAuthorizer: FailingOsLoginAuthorizer(),
            metadataPublisher: FailingMetadataPublisher())

        await #expect(throws: SshAuthError.osLoginRequired) {
            try await resolver.resolve(
                project: "demo-web", zone: "europe-west1-b", instance: "web-01",
                publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: nil,
                emailHint: "alice@example.com",
                allowedMethods: [.instanceMetadata, .projectMetadata])
        }
    }

    @Test func metadataNotAllowedByPolicyThrowsTyped() async throws {
        let resolver = CredentialResolver(
            osLoginStatusProvider: MockOsLoginStatusProvider(
                status: InstanceOsLoginStatus(isEnabled: false, requiresSecurityKey: false)),
            osLoginAuthorizer: FailingOsLoginAuthorizer(),
            metadataPublisher: FailingMetadataPublisher())

        await #expect(throws: SshAuthError.metadataAuthorizationNotAllowed) {
            try await resolver.resolve(
                project: "demo-web", zone: "europe-west1-b", instance: "web-01",
                publicKeyOpenSSH: "ssh-ed25519 AAAA...", preferredUsername: nil,
                emailHint: "alice@example.com",
                allowedMethods: [.osLogin])
        }
    }
}
