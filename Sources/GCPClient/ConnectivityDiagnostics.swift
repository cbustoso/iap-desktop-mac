// GH-65 (specs/diagnostics T-DIAG-1/2/3/5): test de conectividad IAP por pasos.
// IAM (testIamPermissions) → firewall (firewalls.list, rango 35.235.240.0/20)
// → probe WebSocket (inyectado: vive en TunnelKit, que GCPClient no importa).
// Resultados estructurados por paso, nunca un booleano único; ningún `throw`
// para resultados esperables. No registra tokens ni cuerpos de respuesta.
import Foundation

// MARK: - Tipos (T-DIAG-1)

public enum DiagnosticsProtocol: String, Sendable, Equatable, CaseIterable {
    case ssh, rdp, custom
}

public struct DiagnosticsTarget: Sendable, Equatable {
    public let project: String
    public let zone: String
    public let instance: String
    public let port: UInt16
    public let protocolKind: DiagnosticsProtocol

    public init(project: String, zone: String, instance: String, port: UInt16, protocolKind: DiagnosticsProtocol) {
        self.project = project
        self.zone = zone
        self.instance = instance
        self.port = port
        self.protocolKind = protocolKind
    }

    public static func ssh(project: String, zone: String, instance: String) -> Self {
        Self(project: project, zone: zone, instance: instance, port: 22, protocolKind: .ssh)
    }

    public static func rdp(project: String, zone: String, instance: String) -> Self {
        Self(project: project, zone: zone, instance: instance, port: 3389, protocolKind: .rdp)
    }
}

/// Acción correctiva: documentación y, si aplica, un comando copiable.
public struct DiagnosticHelp: Sendable, Equatable {
    public let title: String
    public let url: URL
    public let command: String?

    public init(title: String, url: URL, command: String? = nil) {
        self.title = title
        self.url = url
        self.command = command
    }

    public static let grantAccess = DiagnosticHelp(
        title: "Conceder acceso a las VMs (IAP-Secured Tunnel User)",
        url: URL(string: "https://googlecloudplatform.github.io/iap-desktop/setup-iap/#grant-access")!)
    public static let createFirewallRule = DiagnosticHelp(
        title: "Crear una regla de firewall para IAP",
        url: URL(string: "https://googlecloudplatform.github.io/iap-desktop/setup-iap/#create-a-firewall-rule")!)
    public static let proxyConfiguration = DiagnosticHelp(
        title: "Configuración de proxy",
        url: URL(string: "https://googlecloudplatform.github.io/iap-desktop/proxy-configuration/")!)
    public static let tcpForwarding = DiagnosticHelp(
        title: "IAP TCP forwarding",
        url: URL(string: "https://cloud.google.com/iap/docs/tcp-forwarding-overview")!)
}

public enum DiagnosticFailureReason: Sendable, Equatable {
    case missingPermission(String)
    case instanceNotFound
    case httpError(status: Int, message: String)
    case noMatchingFirewallRule(expectedRange: String, port: UInt16)
    /// Una regla DENY con más prioridad tapa la ALLOW que cubre IAP.
    case blockedByDenyRule(rule: String)
    case authRejected
    /// IAP llegó a la red pero no a la VM (firewall / puerto cerrado).
    case backendUnreachable
    /// Sin red, timeout o proxy entre el Mac e IAP.
    case networkUnreachable
    case protocolError(String)
}

public enum DiagnosticStepResult: Sendable, Equatable {
    case passed(info: String?)
    case failed(reason: DiagnosticFailureReason, help: DiagnosticHelp?)
    case skipped(because: String)
    case notApplicable

    public var isPassed: Bool {
        switch self {
        case .passed: return true
        case .failed, .skipped, .notApplicable: return false
        }
    }
}

public enum DiagnosticStepKind: String, Sendable, Equatable, CaseIterable {
    case iam, firewall, websocket

    public var title: String {
        switch self {
        case .iam: return "Permisos IAM"
        case .firewall: return "Regla de firewall para IAP"
        case .websocket: return "Conexión WebSocket con IAP"
        }
    }
}

public struct DiagnosticsStep: Sendable, Equatable {
    public let kind: DiagnosticStepKind
    public let result: DiagnosticStepResult

    public init(kind: DiagnosticStepKind, result: DiagnosticStepResult) {
        self.kind = kind
        self.result = result
    }
}

public struct DiagnosticsReport: Sendable, Equatable {
    public let target: DiagnosticsTarget
    public let steps: [DiagnosticsStep]
    public let startedAt: Date
    public let finishedAt: Date

    public init(target: DiagnosticsTarget, steps: [DiagnosticsStep], startedAt: Date, finishedAt: Date) {
        self.target = target
        self.steps = steps
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Todos los pasos pasaron (uno saltado u omitido no cuenta como éxito).
    public var isFullyPassed: Bool { !steps.isEmpty && steps.allSatisfy(\.result.isPassed) }
}

// MARK: - IAM (T-DIAG-2)

public enum IapPermissionsCheck: Sendable, Equatable {
    /// Permiso → concedido.
    case evaluated([String: Bool])
    case instanceNotFound
    case httpError(status: Int, message: String)
}

/// Resultado del probe WebSocket (lo produce la App sobre TunnelKit).
public enum WebSocketProbeOutcome: Sendable, Equatable {
    case connected(latency: Duration)
    case authRejected
    case backendUnreachable
    case networkUnreachable(String)
    case protocolError(String)
}

extension GCPClient {
    public static let iapTunnelPermission = "iap.tunnelInstances.accessViaIAP"
    public static let instanceGetPermission = "compute.instances.get"
    /// Rango origen fijo de IAP TCP forwarding.
    public static let iapSourceRange = "35.235.240.0/20"

    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    private static func computeURL(_ path: String) -> URL {
        URL(string: "https://compute.googleapis.com/compute/v1/" + path)!
    }

    /// `testIamPermissions` sobre la instancia: 403 = ningún permiso (fail-closed).
    public func testIapTunnelPermissions(project: String, zone: String, instance: String) async -> IapPermissionsCheck {
        struct Permissions: Codable { let permissions: [String]? }
        let requested = [Self.iapTunnelPermission, Self.instanceGetPermission]
        let url = Self.computeURL(
            "projects/\(Self.segment(project))/zones/\(Self.segment(zone))/instances/\(Self.segment(instance))/testIamPermissions")
        do {
            let body = try JSONEncoder().encode(Permissions(permissions: requested))
            let data = try await fetch("POST", url, body: body)
            let granted = Set(try JSONDecoder().decode(Permissions.self, from: data).permissions ?? [])
            return .evaluated(Dictionary(uniqueKeysWithValues: requested.map { ($0, granted.contains($0)) }))
        } catch let failure as GoogleAPIFailure {
            switch failure.status {
            case 403: return .evaluated(Dictionary(uniqueKeysWithValues: requested.map { ($0, false) }))
            case 404: return .instanceNotFound
            default: return .httpError(status: failure.status, message: failure.reason ?? "HTTP \(failure.status)")
            }
        } catch {
            return .httpError(status: 0, message: "sin respuesta de Compute")
        }
    }

    // MARK: - Firewall (T-DIAG-3)

    /// Red de nic0, etiquetas y service accounts de la instancia.
    public struct InstanceNetworkInfo: Sendable, Equatable {
        public let network: String
        public let tags: [String]
        public let serviceAccounts: [String]

        public init(network: String, tags: [String], serviceAccounts: [String]) {
            self.network = network
            self.tags = tags
            self.serviceAccounts = serviceAccounts
        }
    }

    public func instanceNetworkInfo(project: String, zone: String, instance: String) async throws -> InstanceNetworkInfo {
        struct Resource: Decodable {
            struct Nic: Decodable { let name: String?; let network: String? }
            struct Tags: Decodable { let items: [String]? }
            struct Account: Decodable { let email: String? }
            let networkInterfaces: [Nic]?
            let tags: Tags?
            let serviceAccounts: [Account]?
        }
        let resource: Resource = try await get(Self.computeURL(
            "projects/\(Self.segment(project))/zones/\(Self.segment(zone))/instances/\(Self.segment(instance))"))
        let nics = resource.networkInterfaces ?? []
        let nic0 = nics.first { $0.name == "nic0" } ?? nics.first
        return InstanceNetworkInfo(
            network: nic0?.network ?? "",
            tags: resource.tags?.items ?? [],
            serviceAccounts: resource.serviceAccounts?.compactMap(\.email) ?? [])
    }

    public struct FirewallRule: Codable, Sendable, Equatable {
        public struct Permission: Codable, Sendable, Equatable {
            public let IPProtocol: String
            public let ports: [String]?

            public init(IPProtocol: String, ports: [String]? = nil) {
                self.IPProtocol = IPProtocol
                self.ports = ports
            }
        }

        public let name: String
        public let network: String?
        public let direction: String?
        public let priority: Int?
        public let disabled: Bool?
        public let sourceRanges: [String]?
        public let targetTags: [String]?
        public let targetServiceAccounts: [String]?
        public let allowed: [Permission]?
        public let denied: [Permission]?

        public init(
            name: String, network: String?, direction: String? = "INGRESS", priority: Int? = 1000, disabled: Bool? = nil,
            sourceRanges: [String]?, targetTags: [String]? = nil, targetServiceAccounts: [String]? = nil,
            allowed: [Permission]? = nil, denied: [Permission]? = nil
        ) {
            self.name = name
            self.network = network
            self.direction = direction
            self.priority = priority
            self.disabled = disabled
            self.sourceRanges = sourceRanges
            self.targetTags = targetTags
            self.targetServiceAccounts = targetServiceAccounts
            self.allowed = allowed
            self.denied = denied
        }
    }

    public enum FirewallCheck: Sendable, Equatable {
        /// Regla ALLOW efectiva (la de mayor prioridad que aplica).
        case covered(rule: String)
        case blocked(byDenyRule: String)
        case notCovered
        case listDenied
        case httpError(status: Int, message: String)
    }

    /// Todas las reglas del proyecto (paginado).
    public func listFirewallRules(project: String) async throws -> [FirewallRule] {
        struct Page: Decodable { let items: [FirewallRule]?; let nextPageToken: String? }
        var rules: [FirewallRule] = []
        var token: String?
        repeat {
            var components = URLComponents(url: Self.computeURL("projects/\(Self.segment(project))/global/firewalls"),
                                           resolvingAgainstBaseURL: false)!
            if let token { components.queryItems = [URLQueryItem(name: "pageToken", value: token)] }
            let page: Page = try await get(components.url!)
            rules += page.items ?? []
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil
        return rules
    }

    /// ¿Alguna regla deja entrar desde 35.235.240.0/20 al puerto de la instancia?
    public func firewallRulesCoveringIapRange(
        project: String, instance: InstanceNetworkInfo, port: UInt16
    ) async -> FirewallCheck {
        do {
            return Self.evaluateFirewall(try await listFirewallRules(project: project), instance: instance, port: port)
        } catch GCPClientError.apiError(let status, let reason) {
            return status == 403 ? .listDenied : .httpError(status: status, message: reason ?? "HTTP \(status)")
        } catch {
            return .httpError(status: 0, message: "sin respuesta de Compute")
        }
    }

    /// Semántica de GCE: gana la regla de menor `priority`; a igual prioridad,
    /// DENY gana a ALLOW. Solo cuentan reglas INGRESS activas de la red de la
    /// instancia, con destino que la incluya y origen que contenga el rango IAP.
    public static func evaluateFirewall(_ rules: [FirewallRule], instance: InstanceNetworkInfo, port: UInt16) -> FirewallCheck {
        let iap = CIDR(iapSourceRange)!
        let applicable = rules.filter { rule in
            (rule.direction ?? "INGRESS") == "INGRESS" && rule.disabled != true
                && sameNetwork(rule.network, instance.network)
                && appliesToInstance(rule, instance)
                && (rule.sourceRanges ?? []).contains { CIDR($0)?.contains(iap) == true }
        }
        func matches(_ permissions: [FirewallRule.Permission]?) -> Bool {
            (permissions ?? []).contains { permission in
                let proto = permission.IPProtocol.lowercased()
                return (proto == "tcp" || proto == "all" || proto == "6") && portMatches(permission.ports, port)
            }
        }
        let allow = applicable.filter { matches($0.allowed) }.min { ($0.priority ?? 1000) < ($1.priority ?? 1000) }
        let deny = applicable.filter { matches($0.denied) }.min { ($0.priority ?? 1000) < ($1.priority ?? 1000) }
        if let deny, (deny.priority ?? 1000) <= (allow?.priority ?? Int.max) {
            return .blocked(byDenyRule: deny.name)
        }
        if let allow { return .covered(rule: allow.name) }
        return .notCovered
    }

    static func sameNetwork(_ ruleNetwork: String?, _ instanceNetwork: String) -> Bool {
        guard let ruleNetwork else { return false }
        func key(_ url: String) -> String {
            // `…/projects/P/global/networks/N` (con o sin host).
            guard let range = url.range(of: "projects/") else { return url }
            return String(url[range.lowerBound...])
        }
        return key(ruleNetwork) == key(instanceNetwork)
    }

    static func appliesToInstance(_ rule: FirewallRule, _ instance: InstanceNetworkInfo) -> Bool {
        let tags = rule.targetTags ?? []
        let accounts = rule.targetServiceAccounts ?? []
        if tags.isEmpty, accounts.isEmpty { return true }  // toda la red
        if !tags.isEmpty { return !Set(tags).isDisjoint(with: instance.tags) }
        return !Set(accounts).isDisjoint(with: instance.serviceAccounts)
    }

    /// Sin `ports` = todos; `"22"` o rango `"20-30"`.
    static func portMatches(_ ports: [String]?, _ port: UInt16) -> Bool {
        guard let ports, !ports.isEmpty else { return true }
        return ports.contains { spec in
            let bounds = spec.split(separator: "-").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
            switch bounds.count {
            case 1: return bounds[0] == port
            case 2: return bounds[0] <= port && port <= bounds[1]
            default: return false
            }
        }
    }

    public static func firewallCommand(project: String, network: String, port: UInt16) -> String {
        let name = network.split(separator: "/").last.map(String.init) ?? "default"
        return "gcloud compute firewall-rules create allow-ingress-from-iap-\(port) --project=\(project) "
            + "--network=\(name) --direction=INGRESS --action=allow --rules=tcp:\(port) --source-ranges=\(iapSourceRange)"
    }
}

/// Bloque IPv4 `a.b.c.d/n`.
struct CIDR: Equatable {
    let address: UInt32
    let prefix: Int

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard (1...2).contains(parts.count) else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        let prefix = parts.count == 2 ? Int(parts[1]) : 32
        guard let prefix, (0...32).contains(prefix) else { return nil }
        address = octets.reduce(0) { $0 << 8 | UInt32($1) }
        self.prefix = prefix
    }

    private var mask: UInt32 { prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix)) }

    /// `self` contiene entero a `other` (p. ej. 0.0.0.0/0 ⊇ 35.235.240.0/20).
    func contains(_ other: CIDR) -> Bool {
        prefix <= other.prefix && (address & mask) == (other.address & mask)
    }
}

// MARK: - Orquestación (T-DIAG-5)

/// Ejecuta los pasos en orden. Corta tras un fallo bloqueante de IAM (los
/// pasos restantes se reportan `.skipped`); el firewall es informativo.
public struct DiagnosticsRunner: Sendable {
    public typealias Permissions = @Sendable (DiagnosticsTarget) async -> IapPermissionsCheck
    public typealias NetworkInfo = @Sendable (DiagnosticsTarget) async throws -> GCPClient.InstanceNetworkInfo
    public typealias Firewall = @Sendable (DiagnosticsTarget, GCPClient.InstanceNetworkInfo) async -> GCPClient.FirewallCheck
    public typealias Probe = @Sendable (DiagnosticsTarget) async -> WebSocketProbeOutcome

    let permissions: Permissions
    let networkInfo: NetworkInfo
    let firewall: Firewall
    let probe: Probe
    let now: @Sendable () -> Date

    public init(
        permissions: @escaping Permissions, networkInfo: @escaping NetworkInfo, firewall: @escaping Firewall,
        probe: @escaping Probe, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.permissions = permissions
        self.networkInfo = networkInfo
        self.firewall = firewall
        self.probe = probe
        self.now = now
    }

    /// Sobre un `GCPClient` real; el probe lo aporta quien conoce TunnelKit.
    public init(client: GCPClient, probe: @escaping Probe) {
        self.init(
            permissions: { await client.testIapTunnelPermissions(project: $0.project, zone: $0.zone, instance: $0.instance) },
            networkInfo: { try await client.instanceNetworkInfo(project: $0.project, zone: $0.zone, instance: $0.instance) },
            firewall: { await client.firewallRulesCoveringIapRange(project: $0.project, instance: $1, port: $0.port) },
            probe: probe)
    }

    public func run(_ target: DiagnosticsTarget) async -> DiagnosticsReport {
        let started = now()
        var steps: [DiagnosticsStep] = []
        func finish() -> DiagnosticsReport {
            DiagnosticsReport(target: target, steps: steps, startedAt: started, finishedAt: now())
        }
        // 1. IAM (bloqueante).
        let iam = Self.iamResult(await permissions(target))
        steps.append(DiagnosticsStep(kind: .iam, result: iam))
        guard iam.isPassed else {
            for later in [DiagnosticStepKind.firewall, .websocket] {
                steps.append(DiagnosticsStep(kind: later, result: .skipped(because: "No se evalúa sin los permisos IAM.")))
            }
            return finish()
        }

        // 2. Firewall (informativo: se continúa aunque falle).
        do {
            let info = try await networkInfo(target)
            steps.append(DiagnosticsStep(kind: .firewall, result: Self.firewallResult(await firewall(target, info), target: target, info: info)))
        } catch {
            steps.append(DiagnosticsStep(kind: .firewall, result: .skipped(because: "No se pudo leer la red de la instancia.")))
        }

        // 3. WebSocket.
        steps.append(DiagnosticsStep(kind: .websocket, result: Self.probeResult(await probe(target))))
        return finish()
    }

    static func iamResult(_ check: IapPermissionsCheck) -> DiagnosticStepResult {
        switch check {
        case .evaluated(let granted):
            // compute.instances.get primero: sin él no se puede ni leer la instancia.
            if granted[GCPClient.instanceGetPermission] != true {
                return .failed(reason: .missingPermission(GCPClient.instanceGetPermission), help: .grantAccess)
            }
            if granted[GCPClient.iapTunnelPermission] != true {
                return .failed(reason: .missingPermission(GCPClient.iapTunnelPermission), help: .grantAccess)
            }
            return .passed(info: "iap.tunnelInstances.accessViaIAP y compute.instances.get concedidos.")
        case .instanceNotFound:
            return .failed(reason: .instanceNotFound, help: nil)
        case .httpError(let status, let message):
            return .failed(reason: .httpError(status: status, message: message), help: nil)
        }
    }

    static func firewallResult(
        _ check: GCPClient.FirewallCheck, target: DiagnosticsTarget, info: GCPClient.InstanceNetworkInfo
    ) -> DiagnosticStepResult {
        let fix = DiagnosticHelp(
            title: DiagnosticHelp.createFirewallRule.title, url: DiagnosticHelp.createFirewallRule.url,
            command: GCPClient.firewallCommand(project: target.project, network: info.network, port: target.port))
        switch check {
        case .covered(let rule):
            return .passed(info: "La regla \(rule) permite \(GCPClient.iapSourceRange) → tcp:\(target.port).")
        case .blocked(let rule):
            return .failed(reason: .blockedByDenyRule(rule: rule), help: fix)
        case .notCovered:
            return .failed(reason: .noMatchingFirewallRule(expectedRange: GCPClient.iapSourceRange, port: target.port), help: fix)
        case .listDenied:
            return .skipped(because: "Sin permiso compute.firewalls.list: no se pudo verificar.")
        case .httpError(let status, let message):
            return .failed(reason: .httpError(status: status, message: message), help: nil)
        }
    }

    static func probeResult(_ outcome: WebSocketProbeOutcome) -> DiagnosticStepResult {
        switch outcome {
        case .connected(let latency):
            let ms = Int((Double(latency.components.seconds) * 1000 + Double(latency.components.attoseconds) / 1e15).rounded())
            return .passed(info: "Túnel abierto y cerrado en \(ms) ms.")
        case .authRejected:
            return .failed(reason: .authRejected, help: .grantAccess)
        case .backendUnreachable:
            return .failed(reason: .backendUnreachable, help: .createFirewallRule)
        case .networkUnreachable:
            return .failed(reason: .networkUnreachable, help: .proxyConfiguration)
        case .protocolError(let detail):
            return .failed(reason: .protocolError(detail), help: .tcpForwarding)
        }
    }
}

extension DiagnosticFailureReason {
    /// Texto accionable para el usuario (sin tokens ni cuerpos de respuesta).
    public var message: String {
        switch self {
        case .missingPermission(GCPClient.iapTunnelPermission):
            return "Falta \(GCPClient.iapTunnelPermission): pide el rol IAP-Secured Tunnel User "
                + "(roles/iap.tunnelResourceAccessor) en la instancia o el proyecto."
        case .missingPermission(GCPClient.instanceGetPermission):
            return "Falta \(GCPClient.instanceGetPermission): no puedes ni leer la instancia "
                + "(p. ej. rol Compute Viewer)."
        case .missingPermission(let permission):
            return "Falta el permiso \(permission)."
        case .instanceNotFound:
            return "La instancia no existe en ese proyecto/zona."
        case .httpError(let status, let message):
            return status == 0 ? "Sin respuesta de Google Cloud (\(message))." : "Google Cloud respondió HTTP \(status) (\(message))."
        case .noMatchingFirewallRule(let range, let port):
            return "Ninguna regla de firewall permite \(range) → tcp:\(port) hacia esta instancia."
        case .blockedByDenyRule(let rule):
            return "La regla DENY \(rule) bloquea \(GCPClient.iapSourceRange) con más prioridad que cualquier ALLOW."
        case .authRejected:
            return "IAP rechazó la conexión (token o permiso IAP)."
        case .backendUnreachable:
            return "IAP no llega a la VM: firewall o servicio parado en el puerto."
        case .networkUnreachable:
            return "No se pudo contactar con IAP (red, timeout o proxy)."
        case .protocolError(let detail):
            return "IAP respondió de forma inesperada (\(detail))."
        }
    }
}
