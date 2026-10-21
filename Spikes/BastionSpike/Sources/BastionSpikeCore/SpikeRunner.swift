import Foundation

/// Orquestación del spike: `az` → GET Bastion → listener → por conexión
/// POST /api/tokens + WS + bombeo → DELETE al quedar sin conexiones.
public enum SpikeRunner {
    public static func main(arguments: [String], log: SpikeLog = .shared) async -> Int32 {
        let options: SpikeOptions
        do {
            options = try SpikeOptions.parse(arguments)
        } catch {
            log.error("\(error)")
            print(SpikeOptions.usage)
            return 64
        }
        log.verbose = options.verbose

        do {
            switch options.command {
            case .help:
                print(SpikeOptions.usage)
                return 0
            case .listAccounts:
                try await listAccounts(provider: AzTokenProvider(log: log))
                return 0
            case .tunnel:
                return try await tunnel(options, log: log)
            }
        } catch {
            log.error("\(error)")
            return 1
        }
    }

    // MARK: - (b) az account list

    static func listAccounts(provider: AzTokenProvider) async throws {
        let accounts = try await provider.accounts()
        print("Suscripciones de la sesión `az` (usuario enmascarado):")
        for account in accounts {
            let mark = account.isDefault ? "*" : " "
            let user = account.user.map { Redact.upn($0.name) } ?? "-"
            print("\(mark) \(account.id)  tenant=\(account.tenantId)  state=\(account.state ?? "-")  user=\(user)  \(account.name)")
        }
    }

    // MARK: - Túnel

    static func tunnel(_ options: SpikeOptions, log: SpikeLog) async throws -> Int32 {
        let provider = AzTokenProvider(log: log)

        // Tenant: el explícito o el de la suscripción en `az account list`.
        let tenant: String?
        if let explicit = options.tenant {
            tenant = explicit
        } else {
            let accounts = try await provider.accounts()
            guard let account = accounts.first(where: { $0.id == options.subscription }) else {
                log.error("La suscripción \(options.subscription) no está en `az account list`. Prueba `az login --tenant <tenant>` o pasa --tenant.")
                return 1
            }
            tenant = account.tenantId
        }
        log.info("tenant=\(tenant ?? "<default>") subscription=\(options.subscription)")

        let armToken = try await provider.token(tenant: tenant)
        log.info("token ARM de az: expira \(armToken.expiresOn) (\(Redact.secret(armToken.accessToken)))")

        // (c) GET ARM del Bastion y gate SKU/enableTunneling.
        let transport = URLSessionTransport()
        let host = try await BastionHost.fetch(resourceID: options.bastionResourceID, armToken: armToken.accessToken, transport: transport, log: log)
        log.info("bastion=\(host.name) sku=\(host.sku?.name ?? "?") enableTunneling=\(host.properties.enableTunneling.map(String.init) ?? "nil") enableIpConnect=\(host.properties.enableIpConnect.map(String.init) ?? "nil") dnsName=\(host.properties.dnsName ?? "nil")")
        let dnsName = try host.tunnelEndpoint()

        let dataPlane = BastionDataPlane(dnsName: dnsName, transport: transport, log: log)
        let manager = BastionSessionManager(dataPlane: dataPlane, resourceID: options.vmResourceID, port: options.targetPort, log: log) {
            try await provider.token(tenant: tenant).accessToken
        }
        let connector = WebSocketKitConnector()
        let counter = ConnectionCounter()

        // (f) Listener local.
        let listener = try LocalListener(port: options.listenPort)
        let localPort = try await listener.start { stream in
            Task {
                let id = await counter.next()
                await handle(id: id, stream: stream, dnsName: dnsName, manager: manager, connector: connector, log: log)
            }
        }
        log.info("túnel listo: 127.0.0.1:\(localPort) → \(options.vmResourceID):\(options.targetPort) vía \(dnsName)")

        // (g) Modos.
        switch options.mode {
        case .ssh:
            print("Conecta con:  ssh -p \(localPort) \(options.user ?? "<usuario>")@127.0.0.1")
        case .rdp:
            let file = try RDPLauncher.writeTemporaryFile(port: localPort, username: options.user)
            if try RDPLauncher.open(file) {
                log.info("abierto \(file.path) con \(RDPLauncher.installedApp()?.lastPathComponent ?? "cliente RDP")")
            } else {
                print("Windows App no está instalada. Abre a mano: \(file.path)")
            }
        }
        print("Ctrl+C para cerrar (hace DELETE /api/tokens).")

        let signal = await SignalWaiter.waitForTermination()
        log.info("señal \(signal): cerrando")
        listener.stop()
        await manager.shutdown()
        if options.doubleDelete, let deleted = await manager.lastDeleted {
            // A0.4: el segundo DELETE de la misma sesión debe dar 404.
            let outcome = try? await dataPlane.deleteTokens(deleted)
            log.info("segundo DELETE (A0.4): \(outcome.map { "\($0)" } ?? "error")")
        }
        return 0
    }

    static func handle(
        id: Int, stream: NWConnectionStream, dnsName: String,
        manager: BastionSessionManager, connector: any TunnelSocketConnector, log: SpikeLog
    ) async {
        log.info("conexión #\(id) desde \(stream.remoteDescription)")
        let tokens: BastionSessionTokens
        do {
            tokens = try await manager.open()
        } catch {
            log.error("conexión #\(id): \(error)")
            await stream.close()
            return
        }

        let request = WebSocketRequest.bastion(dnsName: dnsName, tokens: tokens)
        let socket: any TunnelSocket
        do {
            log.info("conexión #\(id): WS \(request)")
            socket = try await connector.connect(request)
        } catch {
            log.error("conexión #\(id): \(error)")
            await stream.close()
            await manager.release()
            return
        }

        let started = Date()
        log.info("conexión #\(id): 101 Switching Protocols, bombeando")
        let result = await TunnelPump.run(local: stream, socket: socket)
        let seconds = Int(Date().timeIntervalSince(started))
        log.info("conexión #\(id) cerrada: \(result.reason) ↑\(result.bytesUp) B ↓\(result.bytesDown) B en \(seconds) s")
        await manager.release()
    }
}

actor ConnectionCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

/// Espera SIGINT/SIGTERM sin matar el proceso, para poder hacer el DELETE.
enum SignalWaiter {
    private final class Sources: @unchecked Sendable {
        var sources: [any DispatchSourceSignal] = []
    }

    static func waitForTermination() async -> Int32 {
        let holder = Sources()
        let once = ResumeOnce()
        let received: Int32 = await withCheckedContinuation { continuation in
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    if once.claim() { continuation.resume(returning: number) }
                }
                source.resume()
                holder.sources.append(source)
            }
        }
        holder.sources.forEach { $0.cancel() }
        return received
    }
}
