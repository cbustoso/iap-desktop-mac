import Foundation
import Testing
@testable import SSHKit

@Suite("KeyProvisioner ephemeral keys (REQ-SSH-2/7)")
struct KeyProvisionerTests {
    @Test(
        "Every supported algorithm signs and verifies",
        arguments: SSHKeyAlgorithm.allCases
    )
    func signatureRoundTrip(algorithm: SSHKeyAlgorithm) throws {
        let provisioner = try KeyProvisioner(algorithm: algorithm)
        let challenge = Data("iap-desktop-ssh-challenge".utf8)
        let signature = try provisioner.sign(challenge: challenge)

        #expect(provisioner.publicKey.algorithm == algorithm)
        #expect(provisioner.publicKey.openSSHRepresentation.hasPrefix(
            "\(algorithm.openSSHIdentifier) "))
        #expect(provisioner.expiresAt > Date())
        #expect(provisioner.publicKey.verify(signature: signature, challenge: challenge))
        #expect(!provisioner.publicKey.verify(
            signature: signature,
            challenge: Data("modified-challenge".utf8)))
    }

    @Test("Known OpenSSH P-256 public-key vector parses")
    func knownOpenSSHVector() throws {
        // SEC 2's P-256 generator point encoded per RFC 5656 section 3.1.
        let encoded = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU="
        let line = "ecdsa-sha2-nistp256 \(encoded) known-vector@example"

        let parsed = try OpenSSHPublicKey(openSSHRepresentation: line)

        #expect(parsed.algorithm == .ecdsaP256)
        #expect(parsed.openSSHRepresentation == "ecdsa-sha2-nistp256 \(encoded)")
    }

    @Test("Malformed and mismatched OpenSSH keys are rejected")
    func malformedKeysAreRejected() {
        #expect(throws: KeyProvisionerError.self) {
            try OpenSSHPublicKey(openSSHRepresentation: "ssh-rsa not-base64!")
        }
        #expect(throws: KeyProvisionerError.self) {
            try OpenSSHPublicKey(openSSHRepresentation:
                "ssh-rsa AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY=")
        }
    }

    @Test("Non-positive or non-finite validity is rejected")
    func invalidValidityIsRejected() {
        for validity in [0, -1, .infinity, .nan] {
            #expect(throws: KeyProvisionerError.invalidValidity) {
                try KeyProvisioner(algorithm: .ecdsaP256, validFor: validity)
            }
        }
    }

    @Test("Descriptions redact private key material", arguments: SSHKeyAlgorithm.allCases)
    func descriptionsAreRedacted(algorithm: SSHKeyAlgorithm) throws {
        let provisioner = try KeyProvisioner(algorithm: algorithm)
        let description = String(describing: provisioner)
        let debugDescription = provisioner.debugDescription
        let expected = "KeyProvisioner(algorithm: \(algorithm.rawValue), privateKey: <redacted>)"

        #expect(description == expected)
        #expect(debugDescription == expected)
        #expect(!description.contains(provisioner.publicKey.keyBlob.base64EncodedString()))
        #expect(!debugDescription.contains(provisioner.publicKey.keyBlob.base64EncodedString()))
    }
}
