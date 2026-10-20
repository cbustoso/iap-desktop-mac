// GH-89 (auth solo `az login`): AzCliTokenSource y AzureCredentialFacade contra
// un `az` FALSO: un script /bin/sh en un directorio temporal que responde según
// sus argumentos y anota cada invocación. Se ejecuta con el runner real
// (`Process`, timeout, stdout/stderr separados); nunca el `az` real ni la red.
import Foundation
import Testing
@testable import AuthKit

/// Script `az` falso. Cada regla es un patrón de `case` de /bin/sh sobre
/// `"$*"` (los argumentos unidos por espacios) con su salida.
private final class FakeAz: @unchecked Sendable {
    struct Rule {
        var pattern: String
        var stdout = ""
        var stderr = ""
        var exit: Int32 = 0
        var delay: Double = 0
    }

    let directory: URL
    var executable: URL { directory.appendingPathComponent("az") }

    init(_ rules: [Rule]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-az-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var cases = ""
        for (index, rule) in rules.enumerated() {
            try Data(rule.stdout.utf8).write(to: directory.appendingPathComponent("out_\(index)"))
            try Data(rule.stderr.utf8).write(to: directory.appendingPathComponent("err_\(index)"))
            cases += """
              \(rule.pattern))
                sleep \(rule.delay)
                cat "$DIR/out_\(index)"; cat "$DIR/err_\(index)" >&2
                exit \(rule.exit);;

            """
        }
        let script = """
            #!/bin/sh
            DIR='\(directory.path)'
            printf '%s\\n' "$*" >> "$DIR/calls.log"
            case "$*" in
            \(cases)  *) echo "fake az: unexpected $*" >&2; exit 99;;
            esac

            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    /// Invocaciones recibidas (argumentos unidos por espacios).
    var calls: [String] {
        guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent("calls.log").path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func source(timeout: Duration = .seconds(10), now: @escaping @Sendable () -> Date = { Date() }) -> AzCliTokenSource {
        AzCliTokenSource(runner: ProcessAzCommandRunner(executable: executable), timeout: timeout, now: now)
    }

    func tearDown() { try? FileManager.default.removeItem(at: directory) }
}

private let home = "aaaaaaaa-0000-0000-0000-000000000001"
private let guest = "bbbbbbbb-0000-0000-0000-000000000002"
private let ada = "cccccccc-0000-0000-0000-000000000003"
private let bob = "dddddddd-0000-0000-0000-000000000004"

private func base64URL(_ json: String) -> String {
    Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Access token ARM v1 como los de `az` (claims `tid`, `oid`, `upn`).
private func armToken(tid: String = home, oid: String = ada, upn: String = "ada.lovelace@contoso.com", marker: String = "SECRET") -> String {
    "\(base64URL(#"{"typ":"JWT"}"#)).\(base64URL(#"{"aud":"https://management.core.windows.net/","tid":"\#(tid)","oid":"\#(oid)","upn":"\#(upn)"}"#)).\(marker)"
}

private func tokenJSON(_ token: String, tenant: String = home, expiresOn: Int = 2_000_003_600) -> String {
    #"""
    {"accessToken":"\#(token)","expiresOn":"2033-05-18 06:33:20.000000","expires_on":\#(expiresOn),
     "subscription":"00000000-0000-0000-0000-00000000000a","tenant":"\#(tenant)","tokenType":"Bearer"}
    """#
}

private let accountList = #"""
[{"cloudName":"AzureCloud","homeTenantId":"\#(home)","id":"00000000-0000-0000-0000-00000000000a","isDefault":true,
  "managedByTenants":[],"name":"Prod","state":"Enabled","tenantId":"\#(home)","user":{"name":"ada.lovelace@contoso.com","type":"user"}},
 {"cloudName":"AzureCloud","homeTenantId":"\#(guest)","id":"00000000-0000-0000-0000-00000000000b","isDefault":false,
  "managedByTenants":[],"name":"Partner","state":"Warned","tenantId":"\#(home)","user":{"name":"ada.lovelace@contoso.com","type":"user"}},
 {"cloudName":"AzureCloud","id":"\#(guest)","isDefault":false,"name":"N/A(tenant level account)","state":"Enabled",
  "tenantId":"\#(guest)","user":{"name":"ada.lovelace@contoso.com","type":"user"}}]
"""#

private let listRule = FakeAz.Rule(pattern: #""account list --output json""#, stdout: accountList, stderr: "WARNING: progress noise\n")

private func tokenRule(tenant: String? = nil, _ stdout: String, delay: Double = 0) -> FakeAz.Rule {
    FakeAz.Rule(
        pattern: "\"account get-access-token --resource https://management.core.windows.net/ --output json\(tenant.map { " --tenant \($0)" } ?? "")\"",
        stdout: stdout, delay: delay)
}

/// Reloj controlable para la caducidad.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@Suite("az: detección (GH-89)")
struct AzCliDetectionTests {
    @Test func readySessionListsAccountsFromStdoutOnly() async throws {
        let az = try FakeAz([listRule])
        defer { az.tearDown() }
        guard case .ready(let accounts) = await az.source().status() else {
            Issue.record("az con sesión no detectado")
            return
        }
        #expect(az.calls == ["account list --output json"])
        #expect(accounts.map(\.name) == ["Prod", "Partner", "N/A(tenant level account)"])
        #expect(accounts[0].isDefault && accounts[0].user?.name == "ada.lovelace@contoso.com")
        #expect(accounts[1].tenantID == home && accounts[1].homeTenantID == guest)  // Lighthouse/B2B
        #expect(accounts[2].isTenantLevel)
    }

    @Test func noSessionIsReportedWithAnActionableMessage() async throws {
        for rule in [
            FakeAz.Rule(pattern: "*", stdout: "[]", stderr: "WARNING: Please run 'az login' to access your accounts.\n"),
            FakeAz.Rule(pattern: "*", stderr: "ERROR: Please run 'az login' to setup account.\n", exit: 1),
        ] {
            let az = try FakeAz([rule])
            defer { az.tearDown() }
            let status = await az.source().status()
            #expect(status == .unavailable(.notLoggedIn))
            #expect(status.userMessage?.contains("az login") == true)
        }
    }

    @Test func missingAzIsReportedNotSilent() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-az-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let source = AzCliTokenSource(runner: ProcessAzCommandRunner(searchPaths: [empty.path]))
        let status = await source.status()
        #expect(status == .unavailable(.notInstalled))
        #expect(status.userMessage?.contains("brew install azure-cli") == true)
        await #expect(throws: AzCliError.notInstalled) { try await source.accessToken(tenantID: home) }
    }

    @Test func whichFindsAzInTheSearchPath() async throws {
        let az = try FakeAz([listRule])
        defer { az.tearDown() }
        let runner = ProcessAzCommandRunner(searchPaths: [az.directory.path, "/usr/bin", "/bin"])
        #expect(await runner.locate()?.resolvingSymlinksInPath() == az.executable.resolvingSymlinksInPath())
        #expect(await AzCliTokenSource(runner: runner).status().isReady)
    }

    @Test func unparseableStdoutIsMalformedNotACrash() async throws {
        let az = try FakeAz([FakeAz.Rule(pattern: "*", stdout: "Subscription: Prod\n")])
        defer { az.tearDown() }
        #expect(await az.source().status() == .unavailable(.malformedOutput))
    }
}

@Suite("az: tokens por tenant (GH-89)", .serialized)
struct AzCliTokenTests {
    @Test func getsAndCachesAnARMTokenPerTenant() async throws {
        let az = try FakeAz([
            tokenRule(tenant: guest, tokenJSON(armToken(tid: guest), tenant: guest)),
            tokenRule(tokenJSON(armToken())),
        ])
        defer { az.tearDown() }
        let clock = Clock()
        let source = az.source(now: { clock.now })
        let token = try await source.accessToken(tenantID: guest)
        #expect(token.accessToken == armToken(tid: guest))
        #expect(token.tenantID == guest)
        #expect(token.subscriptionID == "00000000-0000-0000-0000-00000000000a")
        #expect(token.expiresOn == Date(timeIntervalSince1970: 2_000_003_600))
        #expect(try token.identity() == AzureAccountIdentity(tenantID: guest, objectID: ada, username: "ada.lovelace@contoso.com"))
        _ = try await source.accessToken(tenantID: guest.uppercased())  // mismo tenant, caché
        _ = try await source.accessToken(tenantID: nil)  // tenant por defecto de az
        #expect(az.calls == [
            "account get-access-token --resource https://management.core.windows.net/ --output json --tenant \(guest)",
            "account get-access-token --resource https://management.core.windows.net/ --output json",
        ])
        // Caduca a la hora (menos 60 s de margen): se vuelve a pedir.
        clock.advance(3600 - 61)
        _ = try await source.accessToken(tenantID: guest)
        #expect(az.calls.count == 2)
        clock.advance(2)
        _ = try await source.accessToken(tenantID: guest)
        #expect(az.calls.count == 3)
    }

    @Test func olderAzWithLocalExpiresOnIsStillParsed() async throws {
        let old = #"{"accessToken":"\#(armToken())","expiresOn":"2033-05-18 06:33:20.000000","subscription":"s","tenant":"\#(home)","tokenType":"Bearer"}"#
        let az = try FakeAz([tokenRule(tenant: home, old)])
        defer { az.tearDown() }
        let token = try await az.source().accessToken(tenantID: home)
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2033, 5, 18, 6, 33, 20)
        #expect(token.expiresOn == Calendar.current.date(from: parts))
    }

    @Test func concurrentRequestsForOneTenantRunAzOnce() async throws {
        let az = try FakeAz([tokenRule(tenant: home, tokenJSON(armToken()), delay: 0.3)])
        defer { az.tearDown() }
        let source = az.source()
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await source.accessToken(tenantID: home).accessToken } }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(tokens) == [armToken()])
        #expect(az.calls.count == 1)
    }

    @Test func failuresAreActionableAndNeverEchoStderr() async throws {
        let mfa = "ERROR: AADSTS50076: Due to a configuration change made by your administrator ... user ada.lovelace@contoso.com\nTrace ID: x\n"
        let cases: [(FakeAz.Rule, AzCliError)] = [
            (FakeAz.Rule(pattern: "*", stderr: mfa, exit: 1), .reauthenticationRequired(tenantID: guest, codes: [50076])),
            (FakeAz.Rule(pattern: "*", stderr: "ERROR: AADSTS700082: The refresh token has expired. Please run 'az login'.\n", exit: 1),
             .reauthenticationRequired(tenantID: guest, codes: [700_082])),
            (FakeAz.Rule(pattern: "*", stderr: "ERROR: something else\n", exit: 2), .commandFailed(exitCode: 2, codes: [])),
            (FakeAz.Rule(pattern: "*", stdout: "not json"), .malformedOutput),
            (FakeAz.Rule(pattern: "*", stdout: #"{"accessToken":"","expires_on":1}"#), .malformedOutput),
        ]
        for (rule, expected) in cases {
            let az = try FakeAz([rule])
            defer { az.tearDown() }
            await #expect(throws: expected) { try await az.source().accessToken(tenantID: guest) }
            #expect(!expected.userMessage.contains("ada.lovelace"))
        }
        #expect(AzCliError.reauthenticationRequired(tenantID: guest, codes: [50076]).userMessage.contains("az login --tenant \(guest)"))
    }

    @Test func hangingAzIsKilledAtTheTimeout() async throws {
        let az = try FakeAz([tokenRule(tenant: home, tokenJSON(armToken()), delay: 10)])
        defer { az.tearDown() }
        let started = Date()
        await #expect(throws: AzCliError.timedOut) { try await az.source(timeout: .milliseconds(300)).accessToken(tenantID: home) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func tenantsThatLookLikeOptionsNeverReachAz() async throws {
        let az = try FakeAz([FakeAz.Rule(pattern: "*", stdout: tokenJSON(armToken()))])
        defer { az.tearDown() }
        for bad in ["--debug", "-x", "a b", "../x", ""] {
            await #expect(throws: AzCliError.invalidTenant) { try await az.source().accessToken(tenantID: bad) }
        }
        #expect(az.calls.isEmpty)
    }

    @Test func tokensNeverAppearInDescriptions() async throws {
        let az = try FakeAz([tokenRule(tenant: home, tokenJSON(armToken()))])
        defer { az.tearDown() }
        let token = try await az.source().accessToken(tenantID: home)
        let identity = try token.identity()
        for text in [String(describing: token), String(reflecting: token), "\(identity)"] {
            #expect(!text.contains("SECRET") && !text.contains("ada.lovelace") && !text.contains(armToken()), "\(text)")
        }
    }
}

@Suite("az: AzureCredentialFacade (GH-89)", .serialized)
struct AzureCredentialFacadeTests {
    @Test func connectBindsTheProfileToTheAzAccountAndTenant() async throws {
        let az = try FakeAz([listRule, tokenRule(tokenJSON(armToken())), tokenRule(tenant: guest, tokenJSON(armToken(tid: guest), tenant: guest))])
        defer { az.tearDown() }
        let facade = AzureCredentialFacade(source: az.source())
        var changes = await facade.reauthorized().makeAsyncIterator()
        let identity = try await facade.connect()
        #expect(identity == AzureAccountIdentity(tenantID: home, objectID: ada, username: "ada.lovelace@contoso.com"))
        #expect(await changes.next() != nil)
        #expect(await facade.accounts.count == 3)

        var profile = ProfileDescriptor(id: .generate(), displayName: "Contoso", provider: .azure)
        profile.bindAzureAccount(identity)
        #expect(profile.isSignedIn && profile.homeTenantID == home && profile.azureObjectID == ada)
        #expect(profile.redactedAccount == "a…@contoso.com")

        #expect(try await facade.accessToken(tenantID: guest) == armToken(tid: guest))
        #expect(try await facade.accessToken(tenantID: guest) == armToken(tid: guest))
        #expect(az.calls.filter { $0.contains("--tenant \(guest)") }.count == 1)
    }

    @Test func withoutAzOrSessionConnectFailsWithTheReason() async throws {
        let az = try FakeAz([FakeAz.Rule(pattern: "*", stdout: "[]")])
        defer { az.tearDown() }
        let facade = AzureCredentialFacade(source: az.source())
        await #expect(throws: AzCliError.notLoggedIn) { try await facade.connect() }
        await #expect(throws: AzCliError.notLoggedIn) { try await facade.accessToken(tenantID: home) }
        #expect(await facade.isConnected == false)
    }

    @Test func anotherAzAccountIsDetectedInsteadOfMixingIdentities() async throws {
        // El perfil se conectó como Ada; ahora `az login` es de Bob.
        let az = try FakeAz([listRule, tokenRule(tokenJSON(armToken(oid: bob, upn: "bob@contoso.com")))])
        defer { az.tearDown() }
        let facade = AzureCredentialFacade(source: az.source(), expectedObjectID: ada)
        await #expect(throws: AzCliError.accountMismatch) { try await facade.connect() }
        #expect(await facade.identity == nil)

        // Conectado como Ada y, a mitad de sesión, `az` devuelve tokens de Bob.
        let switching = try FakeAz([
            listRule,
            tokenRule(tokenJSON(armToken())),
            tokenRule(tenant: guest, tokenJSON(armToken(tid: guest, oid: bob), tenant: guest)),
        ])
        defer { switching.tearDown() }
        let session = AzureCredentialFacade(source: switching.source())
        try await session.connect()
        await #expect(throws: AzCliError.accountMismatch) { try await session.accessToken(tenantID: guest) }
    }

    @Test func disconnectForgetsTheSessionWithoutAzLogout() async throws {
        let az = try FakeAz([listRule, tokenRule(tokenJSON(armToken())), tokenRule(tenant: home, tokenJSON(armToken()))])
        defer { az.tearDown() }
        let facade = AzureCredentialFacade(source: az.source())
        try await facade.connect()
        _ = try await facade.accessToken(tenantID: home)
        await facade.disconnect()
        await #expect(throws: AzCliError.notLoggedIn) { try await facade.accessToken(tenantID: home) }
        #expect(!az.calls.contains { $0.hasPrefix("logout") || $0.hasPrefix("account clear") })
        #expect(await facade.accounts.isEmpty)
    }
}
