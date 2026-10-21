import AppKit
import AuthKit
import AzureClient
import Foundation
import Testing
@testable import App

// GH-91: sesión de perfil Azure ligada a la sesión `az login`. `az` es un
// runner falso en memoria (nunca el `az` real) y ARM un `URLProtocol` (sin red).

let home = "aaaaaaaa-0000-0000-0000-000000000001"
let guest = "bbbbbbbb-0000-0000-0000-000000000002"
let oid = "11111111-2222-3333-4444-555555555555"
private let subA = "5ub00000-0000-0000-0000-00000000000a"
private let subB = "5ub00000-0000-0000-0000-00000000000b"
private let subGuest = "5ub00000-0000-0000-0000-00000000000c"

/// JWT sin firma con los claims que lee `AzureAccountIdentity`.
func jwt(tenant: String, objectID: String = oid, upn: String = "ada@contoso.com") -> String {
    func encode(_ object: [String: String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(["tid": tenant, "oid": objectID, "upn": upn])).sig"
}

func account(_ id: String, tenant: String, name: String, isDefault: Bool = false) -> String {
    """
    {"id":"\(id)","name":"\(name)","state":"Enabled","tenantId":"\(tenant)","homeTenantId":"\(tenant)",\
    "isDefault":\(isDefault),"user":{"name":"ada@contoso.com","type":"user"}}
    """
}

/// `az` falso: responde según los argumentos y registra cada llamada.
final class StubAz: AzCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Bool
    private var accountList: String
    private var objectID: String
    private var log: [String] = []

    init(installed: Bool = true, accountList: String, objectID: String = oid) {
        self.installed = installed
        self.accountList = accountList
        self.objectID = objectID
    }

    var calls: [String] { lock.withLock { log } }

    func set(installed: Bool? = nil, accountList: String? = nil, objectID: String? = nil) {
        lock.withLock {
            if let installed { self.installed = installed }
            if let accountList { self.accountList = accountList }
            if let objectID { self.objectID = objectID }
        }
    }

    func locate() async -> URL? {
        lock.withLock { installed ? URL(fileURLWithPath: "/opt/homebrew/bin/az") : nil }
    }

    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> AzCommandOutput {
        let (list, objectID) = lock.withLock { () -> (String, String) in
            log.append(arguments.joined(separator: " "))
            return (accountList, self.objectID)
        }
        switch Array(arguments.prefix(2)) {
        case ["account", "list"]:
            return AzCommandOutput(exitCode: 0, stdout: Data(list.utf8))
        case ["account", "get-access-token"]:
            if list == "[]" {
                return AzCommandOutput(exitCode: 1, stdout: Data(), stderr: Data("ERROR: Please run 'az login' to setup account.".utf8))
            }
            let tenant = arguments.firstIndex(of: "--tenant").map { arguments[$0 + 1] } ?? home
            let json = #"{"accessToken":"\#(jwt(tenant: tenant, objectID: objectID))","expires_on":4000000000,"tenant":"\#(tenant)"}"#
            return AzCommandOutput(exitCode: 0, stdout: Data(json.utf8))
        default:
            return AzCommandOutput(exitCode: 2, stdout: Data())
        }
    }
}

/// ARM falso por sesión (cabecera `X-Stub-ID`).
final class ARMStub: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        var query: String? = nil
        let authorization: String?
    }

    typealias Handler = @Sendable (Request) -> (Int, String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [Request]] = [:]

    static func session(_ handler: @escaping Handler) -> (URLSession, @Sendable () -> [Request]) {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ARMStub.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        return (URLSession(configuration: configuration), { lock.withLock { seen[id] ?? [] } })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let id = request.value(forHTTPHeaderField: "X-Stub-ID") ?? ""
        let entry = Request(path: url.path, query: url.query, authorization: request.value(forHTTPHeaderField: "Authorization"))
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen[id, default: []].append(entry)
            return Self.handlers[id]
        }
        let (status, body) = handler?(entry) ?? (500, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [:])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func page(_ items: [String]) -> String { #"{"value":[\#(items.joined(separator: ","))]}"# }

private func subscriptionJSON(_ id: String, tenant: String, name: String, state: String = "Enabled") -> String {
    #"{"subscriptionId":"\#(id)","tenantId":"\#(tenant)","displayName":"\#(name)","state":"\#(state)"}"#
}

/// ARM con dos tenants: home (2 suscripciones + 1 deshabilitada) y guest (1).
private func standardARM(guestStatus: Int = 200) -> (URLSession, @Sendable () -> [ARMStub.Request]) {
    ARMStub.session { request in
        switch (request.path, request.authorization) {
        case ("/tenants", _):
            return (200, page([
                #"{"tenantId":"\#(home)","displayName":"Contoso","defaultDomain":"contoso.com"}"#,
                #"{"tenantId":"\#(guest)","displayName":"Fabrikam","defaultDomain":"fabrikam.com"}"#,
            ]))
        case ("/subscriptions", "Bearer \(jwt(tenant: home))"):
            return (200, page([
                subscriptionJSON(subB, tenant: home, name: "Prod"),
                subscriptionJSON(subA, tenant: home, name: "Dev"),
                subscriptionJSON("5ub-disabled", tenant: home, name: "Old", state: "Disabled"),
            ]))
        case ("/subscriptions", "Bearer \(jwt(tenant: guest))"):
            return guestStatus == 200
                ? (200, page([subscriptionJSON(subGuest, tenant: guest, name: "Partner")]))
                : (guestStatus, #"{"error":{"code":"AuthorizationFailed","message":"no"}}"#)
        default:
            return (404, "{}")
        }
    }
}

private let twoTenantAccounts = "[\(account(subA, tenant: home, name: "Dev")),\(account(subB, tenant: home, name: "Prod", isDefault: true)),\(account(guest, tenant: guest, name: "N/A(tenant level account)"))]"

/// Suite `explorer` propia por test (y su limpieza).
final class TestDefaults: @unchecked Sendable {
    let name = "iap.tests.azure.\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}

@MainActor
private func makeModel(
    az: StubAz, arm: URLSession, defaults: UserDefaults, bound: (String?, String?) = (nil, nil)
) -> AzureAccountModel {
    let model = AzureAccountModel(
        source: AzCliTokenSource(runner: az),
        selectionStore: AzureSelectionStore(defaults: defaults),
        makeDirectory: { facade, accounts in
            AzCliAccountDirectory(
                arm: AzureARMClient(session: arm, sleep: { _ in }) { try await facade.accessToken(tenantID: $0) },
                accounts: { accounts })
        })
    model.boundAccount = { (bound.0, bound.1) }
    return model
}

@Suite("Azure profile session (az login)")
@MainActor
struct AzureProfileTests {
    @Test func missingAzShowsInstallCTAWithoutData() async {
        let store = TestDefaults()
        let az = StubAz(installed: false, accountList: "[]")
        let (arm, seen) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults)
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }

        await model.connect()

        #expect(model.state == .requiresSignIn(.notInstalled))
        #expect(model.state.requiresSignIn && !model.state.isSignedIn)
        #expect(window.pane == .signIn)
        #expect(window.headlineLabel.stringValue == "Instala Azure CLI y ejecuta az login")
        #expect(window.commandsLabel.stringValue == "brew install azure-cli\naz login")
        #expect(window.visibleRowNames.isEmpty)
        #expect(model.selection == nil)
        #expect(az.calls.isEmpty)
        #expect(seen().isEmpty)
    }

    @Test func noAzSessionShowsLoginCTA() async {
        let store = TestDefaults()
        let az = StubAz(accountList: "[]")
        let (arm, seen) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults)
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }

        await model.connect()

        #expect(model.state == .requiresSignIn(.notLoggedIn))
        #expect(window.pane == .signIn)
        #expect(window.headlineLabel.stringValue == AzureProfileWindowController.signInTitle)
        #expect(window.commandsLabel.stringValue == "az login")
        #expect(window.visibleRowNames.isEmpty)
        #expect(seen().isEmpty)
    }

    @Test func listsTenantsAndSubscriptionsOfTheAzSession() async throws {
        let store = TestDefaults()
        let az = StubAz(accountList: twoTenantAccounts)
        let (arm, seen) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults)
        var bound: [AzureAccountIdentity?] = []
        model.onIdentityChanged = { bound.append($0) }
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }

        await model.connect()

        let identity = try #require(model.state.identity)
        #expect(identity.tenantID == home && identity.objectID == oid)
        #expect(bound == [identity])
        let tenants = model.state.tenants
        #expect(tenants.map(\.displayName) == ["Contoso", "Fabrikam"])
        #expect(tenants[0].subscriptions.map(\.displayName) == ["Dev", "Prod"])  // sin la deshabilitada
        #expect(tenants[1].subscriptions.map(\.subscriptionID) == [subGuest])
        // Por defecto, la suscripción por defecto de `az`.
        #expect(model.selection == AzureSelection(tenantID: home, subscriptionID: subB))
        #expect(window.pane == .accounts)
        #expect(window.visibleRowNames == ["Contoso", "Dev", "✓ Prod", "Fabrikam", "Partner"])
        #expect(window.activeLabel.stringValue == "Activa: Prod · tenant Contoso")
        // Cada tenant con su propio token de `az`; nunca otra cosa que ARM.
        let subscriptionCalls = seen().filter { $0.path == "/subscriptions" }
        #expect(Set(subscriptionCalls.compactMap(\.authorization)) == ["Bearer \(jwt(tenant: home))", "Bearer \(jwt(tenant: guest))"])
        #expect(az.calls.filter { $0.hasPrefix("account list") }.count == 1)
        #expect(!az.calls.contains { $0.contains("logout") })
    }

    @Test func choosingTenantAndSubscriptionPersistsPerProfile() async {
        let store = TestDefaults()
        let az = StubAz(accountList: twoTenantAccounts)
        let (arm, _) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults)
        await model.connect()

        #expect(model.select(tenantID: guest.uppercased(), subscriptionID: subGuest))
        #expect(model.selection == AzureSelection(tenantID: guest, subscriptionID: subGuest))
        #expect(store.defaults.string(forKey: AzureSelectionStore.subscriptionKey) == subGuest)
        // Solo valores de la sesión actual.
        #expect(!model.select(tenantID: home, subscriptionID: subGuest))
        #expect(!model.select(tenantID: "cccccccc-0000-0000-0000-000000000003", subscriptionID: nil))
        #expect(model.selection == AzureSelection(tenantID: guest, subscriptionID: subGuest))

        // Reabrir el perfil recupera la elección; elegir solo tenant también se guarda.
        let reopened = makeModel(az: az, arm: arm, defaults: store.defaults)
        await reopened.connect()
        #expect(reopened.selection == AzureSelection(tenantID: guest, subscriptionID: subGuest))
        #expect(reopened.select(tenantID: home, subscriptionID: nil))
        #expect(store.defaults.string(forKey: AzureSelectionStore.subscriptionKey) == nil)
    }

    @Test func windowRowSelectionBecomesActiveSubscription() async {
        let store = TestDefaults()
        let (arm, _) = standardARM()
        let model = makeModel(az: StubAz(accountList: twoTenantAccounts), arm: arm, defaults: store.defaults)
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }
        await model.connect()

        let partner = window.visibleRowNames.firstIndex(of: "Partner")!
        window.outline.selectRowIndexes([partner], byExtendingSelection: false)
        #expect(window.useSelectionButton.isEnabled)
        window.useSelection(nil)

        #expect(model.selection == AzureSelection(tenantID: guest, subscriptionID: subGuest))
        #expect(window.visibleRowNames.contains("✓ Partner"))
        #expect(window.outline.selectedRow == partner)
    }

    @Test func tenantThatFailsKeepsTheOthers() async {
        let store = TestDefaults()
        let (arm, _) = standardARM(guestStatus: 403)
        let model = makeModel(az: StubAz(accountList: twoTenantAccounts), arm: arm, defaults: store.defaults)
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }
        await model.connect()

        let tenants = model.state.tenants
        #expect(tenants[0].subscriptions.count == 2 && tenants[0].failure == nil)
        #expect(tenants[1].subscriptions.isEmpty)
        #expect(tenants[1].failure == "Sin permiso para listar las suscripciones de este tenant (HTTP 403).")
        #expect(window.visibleRowNames.last == tenants[1].failure)
    }

    @Test func profileBoundToAnotherAccountRequiresSignIn() async {
        let store = TestDefaults()
        let (arm, seen) = standardARM()
        let model = makeModel(
            az: StubAz(accountList: twoTenantAccounts, objectID: "99999999-0000-0000-0000-000000000000"),
            arm: arm, defaults: store.defaults, bound: (oid, home))
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }

        await model.connect()

        #expect(model.state == .requiresSignIn(.accountMismatch))
        #expect(window.headlineLabel.stringValue == "La sesión az usa otra cuenta que este perfil")
        #expect(model.accessToken == nil)
        #expect(seen().isEmpty)
    }

    @Test func boundProfileAsksForItsTenantFirst() async {
        let store = TestDefaults()
        let az = StubAz(accountList: twoTenantAccounts)
        let (arm, _) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults, bound: (oid, guest))
        await model.connect()
        #expect(model.state.identity?.tenantID == guest)
        #expect(az.calls.contains { $0.hasPrefix("account get-access-token") && $0.hasSuffix("--tenant \(guest)") })
    }

    @Test func signOutForgetsTheAccountButNotTheAzSession() async {
        let store = TestDefaults()
        let az = StubAz(accountList: twoTenantAccounts)
        let (arm, _) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults)
        var bound: [AzureAccountIdentity?] = []
        model.onIdentityChanged = { bound.append($0) }
        let window = AzureProfileWindowController(model: model)
        model.onChange = { window.reload() }
        await model.connect()
        #expect(model.accessToken != nil)

        await model.disconnect()

        #expect(model.state == .signedOut)
        #expect(window.pane == .signedOut)
        #expect(model.selection == nil && model.accessToken == nil)
        #expect(bound.count == 2 && bound.last == .some(nil))
        #expect(!az.calls.contains { $0.contains("logout") })
    }

    @Test func retryAfterAzLoginLoadsTheSession() async {
        let store = TestDefaults()
        let az = StubAz(installed: false, accountList: "[]")
        let (arm, _) = standardARM()
        let model = makeModel(az: az, arm: arm, defaults: store.defaults)
        await model.connect()
        #expect(model.state.requiresSignIn)

        az.set(installed: true, accountList: twoTenantAccounts)
        await model.connect()
        #expect(model.state.isSignedIn)
        #expect(model.state.tenants.count == 2)
    }

    @Test func selectionFallsBackWhenStoredOneDisappeared() {
        let tenants = [
            AzureTenantEntry(tenant: AzureTenant(tenantID: home), subscriptions: [
                AzureSubscription(subscriptionID: subA, tenantID: home, displayName: "Dev", state: "Enabled"),
            ], failure: nil),
        ]
        let stale = AzureSelection(tenantID: home, subscriptionID: "gone")
        #expect(AzureAccountModel.resolveSelection(stored: stale, tenants: tenants, accounts: [])
            == AzureSelection(tenantID: home, subscriptionID: subA))
        #expect(AzureAccountModel.resolveSelection(stored: nil, tenants: [], accounts: []) == nil)
    }
}

@Suite("Multi-provider profile coordinator", .serialized)
@MainActor
struct MultiProviderCoordinatorTests {
    @Test func azureProfileOpensAzureSessionBoundToTheAzAccount() async throws {
        let index = TestDefaults()
        let (arm, _) = standardARM()
        let dependencies = AzureProfileSession.Dependencies(
            runner: StubAz(accountList: twoTenantAccounts), armSession: arm, showsWindow: false)
        let store = ProfileStore(defaults: index.defaults)
        let coordinator = ProfileCoordinator(store: store, migrationCompleted: true, azureDependencies: dependencies)

        let created = coordinator.createProfile(named: "Cliente Azure", provider: .azure)
        let session = try #require(created as? AzureProfileSession)
        defer { UserDefaults.standard.removePersistentDomain(forName: session.environment.explorerSuite!) }
        #expect(session.provider == .azure && session.loginWindow == nil && !session.hasOpenTabs)
        #expect(coordinator.isOpen(session.id))
        await session.connectTask?.value

        // El índice guarda solo tenant + oid + UPN enmascarado.
        let descriptor = try #require(store.descriptor(for: session.id))
        #expect(descriptor.provider == .azure && descriptor.isSignedIn)
        #expect(descriptor.homeTenantID == home && descriptor.azureObjectID == oid)
        #expect(descriptor.redactedAccount == "a…@contoso.com")
        #expect(session.windowController?.accountLabel.stringValue.contains("a…@contoso.com") == true)

        // Activar de nuevo devuelve la misma sesión.
        #expect(coordinator.activate(session.id) === session)

        // Sign Out libera la cuenta del perfil.
        session.signOut(nil)
        for _ in 0..<200 where store.descriptor(for: session.id)?.isSignedIn == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.descriptor(for: session.id)?.isSignedIn == false)

        // Cerrar la ventana solo libera este perfil.
        session.window?.close()
        #expect(!coordinator.isOpen(session.id))
        #expect(coordinator.openSessions.isEmpty)
    }

    @Test func profileMenuMarksAzureProfiles() {
        let google = ProfileDescriptor(id: .generate(), displayName: "Google", redactedAccount: "g…@example.com")
        let azure = ProfileDescriptor(id: .generate(), displayName: "Azure", provider: .azure)
        let items = AppDelegate.profileItems([google, azure], open: [], front: nil, target: nil, action: #selector(NSObject.copy))
        #expect(items.map(\.title) == ["Google — g…@example.com", "Azure (Azure) — sin sesión"])
        #expect(AppDelegate.addProfileProviders.map(\.provider) == [.google, .azure])
    }
}
