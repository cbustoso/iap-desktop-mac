// GH-65 (specs/diagnostics T-DIAG-1/2/3/5): tipos, IAM, firewall y runner con stubs.
import Foundation
import Testing
@testable import GCPClient

/// Stub con un handler por `URLSession` (cabecera `X-Stub-ID`): las suites
/// corren en paralelo y no pueden compartir un handler estático.
private final class DiagStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(_ handler: @escaping Handler) -> String {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        return id
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let handler = request.value(forHTTPHeaderField: "X-Stub-ID").flatMap { id in Self.lock.withLock { Self.handlers[id] } }
        let (status, json) = handler?(request, body) ?? (500, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Peticiones vistas por el stub. `@unchecked`: bajo `lock`.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(path: String, query: String?, body: Data?)] = []
    func add(_ request: URLRequest, _ body: Data?) { lock.withLock { items.append((request.url!.path, request.url!.query, body)) } }
    var all: [(path: String, query: String?, body: Data?)] { lock.withLock { items } }
}

private func client(_ handler: @escaping DiagStubURLProtocol.Handler) -> GCPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DiagStubURLProtocol.self]
    configuration.httpAdditionalHeaders = ["X-Stub-ID": DiagStubURLProtocol.register(handler)]
    return GCPClient(session: URLSession(configuration: configuration)) { "test-token" }
}

private let network = "https://www.googleapis.com/compute/v1/projects/p/global/networks/default"
private let instance = GCPClient.InstanceNetworkInfo(network: network, tags: ["ssh", "web"], serviceAccounts: ["vm@p.iam.gserviceaccount.com"])
private let target = DiagnosticsTarget.ssh(project: "p", zone: "z", instance: "vm-1")

private func rule(
    _ name: String, ranges: [String]? = ["35.235.240.0/20"], network: String? = network, priority: Int = 1000,
    tags: [String]? = nil, accounts: [String]? = nil, allowed: [GCPClient.FirewallRule.Permission]? = [.init(IPProtocol: "tcp", ports: ["22"])],
    denied: [GCPClient.FirewallRule.Permission]? = nil, direction: String = "INGRESS", disabled: Bool? = nil
) -> GCPClient.FirewallRule {
    GCPClient.FirewallRule(
        name: name, network: network, direction: direction, priority: priority, disabled: disabled, sourceRanges: ranges,
        targetTags: tags, targetServiceAccounts: accounts, allowed: denied == nil ? allowed : nil, denied: denied)
}

@Suite("Diagnóstico: tipos (T-DIAG-1)")
struct DiagnosticsTypesTests {
    private func report(_ results: [DiagnosticStepResult]) -> DiagnosticsReport {
        DiagnosticsReport(
            target: target,
            steps: zip(DiagnosticStepKind.allCases, results).map { DiagnosticsStep(kind: $0, result: $1) },
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1))
    }

    @Test func fullyPassedOnlyWhenEveryStepPassed() {
        #expect(report([.passed(info: nil), .passed(info: "x"), .passed(info: nil)]).isFullyPassed)
        #expect(!report([.passed(info: nil), .skipped(because: "x"), .passed(info: nil)]).isFullyPassed)
        #expect(!report([.passed(info: nil), .notApplicable, .passed(info: nil)]).isFullyPassed)
        #expect(!report([.failed(reason: .authRejected, help: nil), .passed(info: nil), .passed(info: nil)]).isFullyPassed)
        #expect(!report([]).isFullyPassed)  // sin pasos no hay éxito
    }

    @Test func targetsUseProtocolPorts() {
        #expect(DiagnosticsTarget.ssh(project: "p", zone: "z", instance: "i").port == 22)
        #expect(DiagnosticsTarget.rdp(project: "p", zone: "z", instance: "i").port == 3389)
        #expect(DiagnosticStepKind.allCases == [.iam, .firewall, .websocket])
    }
}

@Suite("Diagnóstico: IAM (T-DIAG-2)", .serialized)
struct DiagnosticsIamTests {
    private func check(status: Int, json: String) async -> (IapPermissionsCheck, Recorder) {
        let recorder = Recorder()
        let result = await client { request, body in
            recorder.add(request, body)
            return (status, json)
        }.testIapTunnelPermissions(project: "p", zone: "z", instance: "vm-1")
        return (result, recorder)
    }

    @Test func allPermissionsGranted() async throws {
        let (result, recorder) = await check(status: 200, json: #"{"permissions":["iap.tunnelInstances.accessViaIAP","compute.instances.get"]}"#)
        #expect(result == .evaluated(["iap.tunnelInstances.accessViaIAP": true, "compute.instances.get": true]))
        let request = try #require(recorder.all.first)
        #expect(request.path == "/compute/v1/projects/p/zones/z/instances/vm-1/testIamPermissions")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: [String]]
        #expect(sent?["permissions"] == ["iap.tunnelInstances.accessViaIAP", "compute.instances.get"])
        #expect(DiagnosticsRunner.iamResult(result).isPassed)
    }

    @Test func partialPermissionIsFailClosed() async {
        let (result, _) = await check(status: 200, json: #"{"permissions":["compute.instances.get"]}"#)
        #expect(result == .evaluated(["iap.tunnelInstances.accessViaIAP": false, "compute.instances.get": true]))
        #expect(DiagnosticsRunner.iamResult(result)
            == .failed(reason: .missingPermission("iap.tunnelInstances.accessViaIAP"), help: .grantAccess))
    }

    @Test func emptyResponseMeansNothingGranted() async {
        let (result, _) = await check(status: 200, json: "{}")  // GCE omite la clave si no hay ninguno
        #expect(DiagnosticsRunner.iamResult(result)
            == .failed(reason: .missingPermission("compute.instances.get"), help: .grantAccess))
    }

    @Test func forbiddenMeansNothingGranted() async {
        let (result, _) = await check(status: 403, json: #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#)
        #expect(result == .evaluated(["iap.tunnelInstances.accessViaIAP": false, "compute.instances.get": false]))
        #expect(!DiagnosticsRunner.iamResult(result).isPassed)
    }

    @Test func notFoundAndServerErrorAreDistinctFromDenied() async {
        let (missing, _) = await check(status: 404, json: "{}")
        #expect(missing == .instanceNotFound)
        let (broken, _) = await check(status: 500, json: #"{"error":{"code":500,"status":"INTERNAL"}}"#)
        #expect(broken == .httpError(status: 500, message: "INTERNAL"))
        #expect(DiagnosticsRunner.iamResult(broken) == .failed(reason: .httpError(status: 500, message: "INTERNAL"), help: nil))
    }

    @Test func messagesNameTheRequiredRole() {
        #expect(DiagnosticFailureReason.missingPermission(GCPClient.iapTunnelPermission).message.contains("roles/iap.tunnelResourceAccessor"))
        #expect(DiagnosticFailureReason.missingPermission(GCPClient.instanceGetPermission).message.contains("compute.instances.get"))
    }
}

@Suite("Diagnóstico: firewall (T-DIAG-3)", .serialized)
struct DiagnosticsFirewallTests {
    private func evaluate(_ rules: [GCPClient.FirewallRule], port: UInt16 = 22) -> GCPClient.FirewallCheck {
        GCPClient.evaluateFirewall(rules, instance: instance, port: port)
    }

    @Test func exactAndWiderRangesCover() {
        #expect(evaluate([rule("iap")]) == .covered(rule: "iap"))
        #expect(evaluate([rule("any", ranges: ["0.0.0.0/0"])]) == .covered(rule: "any"))
        #expect(evaluate([rule("wide", ranges: ["35.235.0.0/16"])]) == .covered(rule: "wide"))
        #expect(evaluate([rule("multi", ranges: ["10.0.0.0/8", "35.235.240.0/20"])]) == .covered(rule: "multi"))
    }

    @Test func cidrComparisonIsNotStringEquality() {
        // Un subconjunto del rango IAP NO lo cubre entero; otro bloque tampoco.
        #expect(evaluate([rule("part", ranges: ["35.235.240.0/24"])]) == .notCovered)
        #expect(evaluate([rule("near", ranges: ["35.235.224.0/20"])]) == .notCovered)
        #expect(evaluate([rule("bits", ranges: ["35.235.241.7/20"])]) == .covered(rule: "bits"))  // host bits ignorados
        #expect(CIDR("35.235.240.0/33") == nil)
        #expect(CIDR("300.1.1.1/8") == nil)
        #expect(CIDR("not-a-range") == nil)
        #expect(CIDR("10.0.0.1")?.prefix == 32)
    }

    @Test func otherNetworkOrTagsDoNotCount() {
        #expect(evaluate([rule("vpc2", network: "https://www.googleapis.com/compute/v1/projects/p/global/networks/other")]) == .notCovered)
        #expect(evaluate([rule("tag", tags: ["rdp-only"])]) == .notCovered)
        #expect(evaluate([rule("tag-ok", tags: ["web"])]) == .covered(rule: "tag-ok"))
        #expect(evaluate([rule("sa", accounts: ["other@p.iam.gserviceaccount.com"])]) == .notCovered)
        #expect(evaluate([rule("sa-ok", accounts: ["vm@p.iam.gserviceaccount.com"])]) == .covered(rule: "sa-ok"))
        // Misma red con URL relativa (sin host).
        #expect(evaluate([rule("rel", network: "projects/p/global/networks/default")]) == .covered(rule: "rel"))
    }

    @Test func portsProtocolsDirectionAndDisabled() {
        #expect(evaluate([rule("range", allowed: [.init(IPProtocol: "tcp", ports: ["20-30"])])]) == .covered(rule: "range"))
        #expect(evaluate([rule("rdp", allowed: [.init(IPProtocol: "tcp", ports: ["3389"])])]) == .notCovered)
        #expect(evaluate([rule("rdp", allowed: [.init(IPProtocol: "tcp", ports: ["3389"])])], port: 3389) == .covered(rule: "rdp"))
        #expect(evaluate([rule("allports", allowed: [.init(IPProtocol: "tcp")])]) == .covered(rule: "allports"))
        #expect(evaluate([rule("all", allowed: [.init(IPProtocol: "all")])]) == .covered(rule: "all"))
        #expect(evaluate([rule("udp", allowed: [.init(IPProtocol: "udp", ports: ["22"])])]) == .notCovered)
        #expect(evaluate([rule("egress", direction: "EGRESS")]) == .notCovered)
        #expect(evaluate([rule("off", disabled: true)]) == .notCovered)
        #expect(evaluate([rule("tagsonly", ranges: nil)]) == .notCovered)
    }

    @Test func denyRulesFollowGcePrecedence() {
        let allow = rule("allow-iap", priority: 1000)
        let denyFirst = rule("deny-all", ranges: ["0.0.0.0/0"], priority: 500, denied: [.init(IPProtocol: "all")])
        #expect(evaluate([allow, denyFirst]) == .blocked(byDenyRule: "deny-all"))
        let denyLater = rule("deny-all", ranges: ["0.0.0.0/0"], priority: 65534, denied: [.init(IPProtocol: "all")])
        #expect(evaluate([allow, denyLater]) == .covered(rule: "allow-iap"))
        let denyTie = rule("deny-tie", priority: 1000, denied: [.init(IPProtocol: "tcp", ports: ["22"])])
        #expect(evaluate([allow, denyTie]) == .blocked(byDenyRule: "deny-tie"))  // a igualdad, DENY gana
        let denyOtherPort = rule("deny-rdp", priority: 1, denied: [.init(IPProtocol: "tcp", ports: ["3389"])])
        #expect(evaluate([allow, denyOtherPort]) == .covered(rule: "allow-iap"))
        // Gana la ALLOW de mayor prioridad (menor número).
        #expect(evaluate([rule("b", priority: 900), rule("a", priority: 100)]) == .covered(rule: "a"))
    }

    @Test func listsAllPagesAndForbiddenIsSkipped() async throws {
        let recorder = Recorder()
        let paged = client { request, body in
            recorder.add(request, body)
            if request.url?.query?.contains("pageToken=next") == true {
                return (200, #"{"items":[{"name":"iap","network":"\#(network)","sourceRanges":["35.235.240.0/20"],"allowed":[{"IPProtocol":"tcp","ports":["22"]}]}]}"#)
            }
            return (200, #"{"items":[{"name":"web","network":"\#(network)","sourceRanges":["0.0.0.0/0"],"allowed":[{"IPProtocol":"tcp","ports":["443"]}]}],"nextPageToken":"next"}"#)
        }
        #expect(await paged.firewallRulesCoveringIapRange(project: "p", instance: instance, port: 22) == .covered(rule: "iap"))
        #expect(recorder.all.map(\.path) == ["/compute/v1/projects/p/global/firewalls", "/compute/v1/projects/p/global/firewalls"])

        let denied = client { _, _ in (403, #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#) }
        let check = await denied.firewallRulesCoveringIapRange(project: "p", instance: instance, port: 22)
        #expect(check == .listDenied)
        #expect(DiagnosticsRunner.firewallResult(check, target: target, info: instance)
            == .skipped(because: "Sin permiso compute.firewalls.list: no se pudo verificar."))
    }

    @Test func missingRuleOffersCopyableGcloudCommand() throws {
        guard case .failed(let reason, let help) = DiagnosticsRunner.firewallResult(.notCovered, target: target, info: instance) else {
            Issue.record("se esperaba .failed")
            return
        }
        #expect(reason == .noMatchingFirewallRule(expectedRange: "35.235.240.0/20", port: 22))
        let command = try #require(help?.command)
        #expect(command.hasPrefix("gcloud compute firewall-rules create"))
        #expect(command.contains("--project=p"))
        #expect(command.contains("--network=default"))
        #expect(command.contains("--rules=tcp:22"))
        #expect(command.contains("--source-ranges=35.235.240.0/20"))
        #expect(help?.url == DiagnosticHelp.createFirewallRule.url)
    }

    @Test func instanceNetworkInfoUsesNic0() async throws {
        let info = try await client { _, _ in
            (200, #"{"networkInterfaces":[{"name":"nic1","network":"x"},{"name":"nic0","network":"\#(network)"}],"tags":{"items":["ssh"]},"serviceAccounts":[{"email":"vm@p.iam.gserviceaccount.com"}]}"#)
        }.instanceNetworkInfo(project: "p", zone: "z", instance: "vm-1")
        #expect(info == GCPClient.InstanceNetworkInfo(network: network, tags: ["ssh"], serviceAccounts: ["vm@p.iam.gserviceaccount.com"]))
    }
}

/// Contadores de llamadas del runner. `@unchecked`: bajo `lock`.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func hit(_ name: String) { lock.withLock { names.append(name) } }
    var all: [String] { lock.withLock { names } }
}

@Suite("Diagnóstico: runner (T-DIAG-5)")
struct DiagnosticsRunnerTests {
    private func runner(
        iam: IapPermissionsCheck = .evaluated([GCPClient.iapTunnelPermission: true, GCPClient.instanceGetPermission: true]),
        networkFails: Bool = false, firewall: GCPClient.FirewallCheck = .covered(rule: "iap"),
        probe: WebSocketProbeOutcome = .connected(latency: .milliseconds(42)), calls: Calls
    ) -> DiagnosticsRunner {
        DiagnosticsRunner(
            permissions: { _ in calls.hit("iam"); return iam },
            networkInfo: { _ in
                calls.hit("network")
                if networkFails { throw GCPClientError.apiError(status: 500, reason: nil) }
                return instance
            },
            firewall: { _, _ in calls.hit("firewall"); return firewall },
            probe: { _ in calls.hit("probe"); return probe })
    }

    @Test func allPassReportsThreeSteps() async {
        let calls = Calls()
        let report = await runner(calls: calls).run(target)
        #expect(report.isFullyPassed)
        #expect(report.steps.map(\.kind) == [.iam, .firewall, .websocket])
        #expect(report.steps.last?.result == .passed(info: "Túnel abierto y cerrado en 42 ms."))
        #expect(calls.all == ["iam", "network", "firewall", "probe"])
        #expect(report.finishedAt >= report.startedAt)
    }

    @Test func blockingIamStopsAndSkipsTheRest() async {
        let calls = Calls()
        let report = await runner(iam: .evaluated([GCPClient.iapTunnelPermission: false, GCPClient.instanceGetPermission: true]), calls: calls).run(target)
        #expect(calls.all == ["iam"])  // ni firewall ni probe
        #expect(report.steps.map(\.kind) == [.iam, .firewall, .websocket])
        #expect(report.steps[0].result == .failed(reason: .missingPermission(GCPClient.iapTunnelPermission), help: .grantAccess))
        #expect(report.steps[1].result == .skipped(because: "No se evalúa sin los permisos IAM."))
        #expect(report.steps[2].result == .skipped(because: "No se evalúa sin los permisos IAM."))
        #expect(!report.isFullyPassed)
    }

    @Test func iamHttpErrorIsAlsoBlocking() async {
        let calls = Calls()
        _ = await runner(iam: .httpError(status: 503, message: "UNAVAILABLE"), calls: calls).run(target)
        #expect(calls.all == ["iam"])
    }

    @Test func firewallFailureIsInformativeAndProbeStillRuns() async {
        let calls = Calls()
        let report = await runner(firewall: .notCovered, probe: .backendUnreachable, calls: calls).run(target)
        #expect(calls.all == ["iam", "network", "firewall", "probe"])
        #expect(report.steps[1].result.isPassed == false)
        #expect(report.steps[2].result == .failed(reason: .backendUnreachable, help: .createFirewallRule))
    }

    @Test func unreadableNetworkSkipsFirewallOnly() async {
        let calls = Calls()
        let report = await runner(networkFails: true, calls: calls).run(target)
        #expect(calls.all == ["iam", "network", "probe"])
        #expect(report.steps[1].result == .skipped(because: "No se pudo leer la red de la instancia."))
        #expect(report.steps[2].result.isPassed)
    }

    @Test func probeOutcomesMapToReasonsAndHelp() {
        #expect(DiagnosticsRunner.probeResult(.authRejected) == .failed(reason: .authRejected, help: .grantAccess))
        #expect(DiagnosticsRunner.probeResult(.networkUnreachable("timeout")) == .failed(reason: .networkUnreachable, help: .proxyConfiguration))
        #expect(DiagnosticsRunner.probeResult(.protocolError("4047")) == .failed(reason: .protocolError("4047"), help: .tcpForwarding))
        #expect(DiagnosticsRunner.probeResult(.connected(latency: .milliseconds(1500))) == .passed(info: "Túnel abierto y cerrado en 1500 ms."))
    }

    @Test func endToEndOverStubbedComputeAPI() async {
        let calls = Calls()
        let api = client { request, _ in
            let path = request.url!.path
            if path.hasSuffix("/testIamPermissions") {
                return (200, #"{"permissions":["iap.tunnelInstances.accessViaIAP","compute.instances.get"]}"#)
            }
            if path.hasSuffix("/global/firewalls") {
                return (200, #"{"items":[{"name":"default-allow-ssh","network":"\#(network)","sourceRanges":["0.0.0.0/0"],"allowed":[{"IPProtocol":"tcp","ports":["22"]}]}]}"#)
            }
            return (200, #"{"networkInterfaces":[{"name":"nic0","network":"\#(network)"}]}"#)
        }
        let report = await DiagnosticsRunner(client: api) { _ in calls.hit("probe"); return .connected(latency: .milliseconds(80)) }.run(target)
        #expect(report.isFullyPassed)
        #expect(report.steps[1].result == .passed(info: "La regla default-allow-ssh permite 35.235.240.0/20 → tcp:22."))
        #expect(calls.all == ["probe"])
    }
}
