// SSHKit T-SSH-3 tests: validación/derivación de usuario POSIX (paridad LinuxUser).
import Testing
@testable import SSHKit

@Suite("PosixUsername")
struct PosixUsernameTests {
    @Test func validUsernamesAcceptedAndInvalidRejected() {
        #expect(PosixUsername.isValid("alice"))
        #expect(PosixUsername.isValid("a.b_c-9"))
        #expect(PosixUsername.isValid(String(repeating: "a", count: 32)))
        #expect(!PosixUsername.isValid(""))
        #expect(!PosixUsername.isValid("-bad"))
        #expect(!PosixUsername.isValid(String(repeating: "a", count: 33)))
        #expect(!PosixUsername.isValid("bad user"))
    }

    @Test func suggestDerivesFromEmailLocalPart() {
        #expect(PosixUsername.suggest(fromEmail: "Alice@example.com") == "alice")
        #expect(PosixUsername.suggest(fromEmail: "Bob.Smith@example.com") == "bob_smith")
    }

    @Test func suggestPrependsGWhenNotStartingWithLetter() {
        #expect(PosixUsername.suggest(fromEmail: "007@example.com") == "g007")
    }

    @Test func suggestTruncatesToMaxLength() {
        let longLocal = String(repeating: "a", count: 40)
        let suggested = PosixUsername.suggest(fromEmail: "\(longLocal)@example.com")
        #expect(suggested.count == 32)
    }
}
