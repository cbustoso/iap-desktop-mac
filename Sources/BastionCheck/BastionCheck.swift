// GH-95: `bastion-check`, equivalente del spike F0 (`Spikes/BastionSpike`)
// sobre el código de PRODUCCIÓN (`BastionKit` + `AzureClient` + `AzCliTokenSource`).
// Lo usa `Spikes/BastionSpike/scripts/validate-f0.sh --usar-bastionkit` para
// validar contra un Bastion real sin duplicar la lógica del protocolo.
//
// Mismas opciones que el spike para el modo túnel (subconjunto) y mismas
// líneas de log en stderr que el script busca (`POST/DELETE /api/tokens → HTTP`,
// `segundo DELETE`). Nunca imprime `aztoken`, `authToken` ni `websocketToken`.
import AuthKit
import AzureClient
import BastionKit
import Foundation

struct Options {
    var subscription = ""
    var resourceGroup = ""
    var bastion = ""
    var vm = ""
    var vmResourceGroup: String?
    var tenant: String?
    var port: UInt16 = 22
    var listenPort: UInt16 = 0
    var doubleDelete = false
    var verbose = false
    var attempts = BastionRetryPolicy.default.maxAttempts

    static let usage = """
    Uso:
      bastion-check --subscription <id> --resource-group <rg> --bastion <nombre> --vm <nombre|resourceId>
                    [--vm-resource-group <rg>] [--tenant <id>] [--port 22|3389|n] [--listen-port <n>]
                    [--attempts <n>] [--double-delete] [--verbose]

    Túnel 127.0.0.1:<listen-port> → VM vía Azure Bastion con BastionKit (código de producción).
    Auth: solo la sesión de Azure CLI (`az login`). Ctrl+C cierra (un único DELETE).
    """

    var vmResourceID: String {
        if vm.hasPrefix("/subscriptions/") { return vm }
        return "/subscriptions/\(subscription)/resourceGroups/\(vmResourceGroup ?? resourceGroup)"
            + "/providers/Microsoft.Compute/virtualMachines/\(vm)"
    }

    var bastionResourceID: String {
        "/subscriptions/\(subscription)/resourceGroups/\(resourceGroup)/providers/Microsoft.Network/bastionHosts/\(bastion)"
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next(), !next.hasPrefix("--") else { throw Failure("Falta el valor de \(flag).") }
            return next
        }
        func number<T: FixedWidthInteger>(_ flag: String, _: T.Type) throws -> T {
            guard let parsed = T(try value(flag)) else { throw Failure("\(flag) debe ser un entero válido.") }
            return parsed
        }
        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help": throw HelpRequested()
            case "--subscription": options.subscription = try value(argument)
            case "--resource-group": options.resourceGroup = try value(argument)
            case "--bastion": options.bastion = try value(argument)
            case "--vm": options.vm = try value(argument)
            case "--vm-resource-group": options.vmResourceGroup = try value(argument)
            case "--tenant": options.tenant = try value(argument)
            case "--port": options.port = try number(argument, UInt16.self)
            case "--listen-port": options.listenPort = try number(argument, UInt16.self)
            case "--attempts": options.attempts = try number(argument, Int.self)
            case "--double-delete": options.doubleDelete = true
            case "--verbose", "-v": options.verbose = true
            // Compatibilidad con la línea de comandos del spike.
            case "--mode": _ = try value(argument)
            default: throw Failure("Argumento desconocido: \(argument)\n\n\(usage)")
            }
        }
        let missing = [("--subscription", options.subscription), ("--resource-group", options.resourceGroup),
                       ("--bastion", options.bastion), ("--vm", options.vm)].filter { $0.1.isEmpty }.map(\.0)
        guard missing.isEmpty else { throw Failure("Faltan: \(missing.joined(separator: ", ")).\n\n\(usage)") }
        return options
    }
}

struct HelpRequested: Error {}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Transporte de producción que además registra cada `/api/tokens` sin
/// tokens y recuerda el último DELETE para `--double-delete` (A0.4).
final class LoggingTransport: BastionHTTPTransport, @unchecked Sendable {
    private let base: any BastionHTTPTransport
    private let lock = NSLock()
    private var lastDelete: URLRequest?

    init(base: any BastionHTTPTransport) { self.base = base }

    var lastDeleteRequest: URLRequest? { lock.withLock { lastDelete } }

    func send(_ request: URLRequest) async throws -> BastionHTTPResponse {
        let method = request.httpMethod ?? "GET"
        let chained = request.value(forHTTPHeaderField: "X-Node-Id") != nil
        do {
            let response = try await base.send(request)
            if method == "DELETE" { lock.withLock { lastDelete = request } }
            log("\(method) /api/tokens → HTTP \(response.status)" + (method == "POST" ? " chained=\(chained)" : ""))
            return response
        } catch {
            log("\(method) /api/tokens → \(BastionTunnelError(describing: error))")
            throw error
        }
    }
}

extension BastionTunnelError {
    init(describing error: any Error) {
        self = (error as? BastionTunnelError) ?? .network(String(describing: type(of: error)))
    }
}

@main
struct BastionCheck {
    static func main() async {
        do {
            try await run(Options.parse(Array(CommandLine.arguments.dropFirst())))
        } catch is HelpRequested {
            print(Options.usage)
        } catch {
            log("ERROR: \(error)")
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        let az = AzCliTokenSource()
        let tenant: String
        if let explicit = options.tenant {
            tenant = explicit
        } else {
            let accounts = try await az.accounts()
            guard let account = accounts.first(where: { $0.id.caseInsensitiveCompare(options.subscription) == .orderedSame })
            else { throw Failure("La sesión de az no ve la suscripción \(options.subscription) (az account list).") }
            tenant = account.tenantID
        }
        let armToken: @Sendable () async throws -> String = { try await az.accessToken(tenantID: tenant).accessToken }

        let arm = AzureARMClient { _ in try await armToken() }
        let bastion = try await arm.bastionHost(id: options.bastionResourceID, tenantID: tenant)
        log("bastion sku=\(bastion.sku) tunneling=\(bastion.enableTunneling) dns=\(bastion.dnsName ?? "-")")
        let target = try BastionTarget.validated(
            bastionSKU: bastion.sku, enableTunneling: bastion.enableTunneling, dnsName: bastion.dnsName,
            vmResourceID: options.vmResourceID, port: options.port)

        // Misma composición que la app: proxy del sistema (ProxyResolver) + renovación + OSLog.
        let network = await BastionNetworkConfiguration.resolve(for: target)
        log("proxy=" + (network.proxy.map { "\($0.host):\($0.port)" } ?? "directo"))
        let transport = LoggingTransport(base: network.transport)
        let verbose = options.verbose
        let telemetry = BastionTelemetry { target, event in
            BastionTelemetry.oslog.record(target, event)
            if verbose { log("event \(event)") }
        }
        let factory = BastionTunnelFactory(
            target: target,
            sessions: BastionSessionClient(transport: transport),
            sockets: network.sockets,
            retry: BastionRetryPolicy(maxAttempts: options.attempts),
            telemetry: telemetry,
            invalidateArmToken: { await az.clearCache() },
            armToken: armToken)
        let forwarder = try await BastionLocalForwarder.start(factory: factory, listenPort: options.listenPort)
        log("escuchando en 127.0.0.1:\(forwarder.port) → \(target)")

        let failures = Task {
            for await failure in forwarder.failures() { log("túnel caído: \(failure.kind) — \(failure.userMessage)") }
        }
        await waitForInterrupt()
        log("cerrando…")
        await forwarder.stop()
        failures.cancel()

        if options.doubleDelete {
            if let request = transport.lastDeleteRequest {
                let status = (try? await network.transport.send(request).status).map(String.init) ?? "error"
                log("segundo DELETE → HTTP \(status) (se espera 404)")
            } else {
                log("segundo DELETE: no hubo DELETE previo")
            }
        }
    }

    /// Espera a SIGINT/SIGTERM (Ctrl+C o `kill -INT` desde el script).
    static func waitForInterrupt() async {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let stream = AsyncStream<Void> { continuation in
            let queue = DispatchQueue(label: "bastion-check.signals")
            let sources = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: queue) }
            for source in sources {
                source.setEventHandler { continuation.yield() }
                source.resume()
            }
            continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
        }
        for await _ in stream { return }
    }
}
