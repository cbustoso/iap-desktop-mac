// GH-89 (decisión del dueño, 2026-10-20): ÚNICO origen de credenciales Azure,
// la sesión `az login` del usuario (sin app registration). Se invoca el `az`
// instalado con timeout, se parsea SOLO su stdout JSON (stderr trae avisos y
// progreso) y nunca se registran tokens. Los access tokens se cachean por
// tenant en memoria; el refresh lo gestiona el propio `az` en su caché MSAL.
import Foundation
import OSLog

// MARK: - Ejecución de `az` (inyectable)

public struct AzCommandOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Lo que `AzCliTokenSource` necesita del sistema: localizar `az` y
/// ejecutarlo. Los tests usan un runner falso que simula su salida.
public protocol AzCommandRunning: Sendable {
    /// Ruta de `az` (equivale a `which az`) o `nil` si no está instalado.
    func locate() async -> URL?
    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> AzCommandOutput
}

/// Runner real sobre `Process`. Una app GUI no hereda el `PATH` de la shell:
/// se añaden las rutas habituales de Homebrew y del instalador de Microsoft.
public struct ProcessAzCommandRunner: AzCommandRunning {
    public static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    private let executable: URL?
    private let searchPaths: [String]?

    /// - Parameters:
    ///   - executable: `az` fijo (sin `which`); los tests pasan un script falso.
    ///   - searchPaths: `PATH` exacto para `which az` en vez del del proceso.
    public init(executable: URL? = nil, searchPaths: [String]? = nil) {
        self.executable = executable
        self.searchPaths = searchPaths
    }

    public func locate() async -> URL? {
        if let executable { return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil }
        guard let output = try? await run(URL(fileURLWithPath: "/usr/bin/which"), arguments: ["az"], timeout: .seconds(5)),
              output.exitCode == 0
        else { return nil }
        let path = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        if let searchPaths {
            environment["PATH"] = searchPaths.joined(separator: ":")
        } else {
            let current = (base["PATH"] ?? "").split(separator: ":").map(String.init)
            environment["PATH"] = (current + Self.extraSearchPaths.filter { !current.contains($0) }).joined(separator: ":")
        }
        // Sin color, sin encuestas ni avisos: stdout queda en JSON puro.
        environment["AZURE_CORE_NO_COLOR"] = "true"
        environment["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true"
        environment["AZURE_CORE_SURVEY_MESSAGE"] = "false"
        return environment
    }

    public func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> AzCommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice  // nunca un prompt interactivo
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let state = RunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AzCommandOutput, any Error>) in
                // Leer ambos pipes en paralelo: con salidas grandes (account
                // list de muchas suscripciones) un pipe lleno bloquearía a `az`.
                let reads = DispatchGroup()
                let collected = Collected()
                for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
                    reads.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        collected.set(data, stdout: isStdout)
                        reads.leave()
                    }
                }
                process.terminationHandler = { finished in
                    // Tras un timeout no se espera al EOF: un subproceso huérfano
                    // podría mantener el pipe abierto mucho más.
                    if state.timedOut {
                        state.resume(continuation, with: .failure(AzCliError.timedOut))
                        return
                    }
                    reads.notify(queue: .global()) {
                        if state.timedOut {
                            state.resume(continuation, with: .failure(AzCliError.timedOut))
                        } else {
                            let (out, err) = collected.values
                            state.resume(continuation, with: .success(AzCommandOutput(exitCode: finished.terminationStatus, stdout: out, stderr: err)))
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    try? stdout.fileHandleForWriting.close()
                    try? stderr.fileHandleForWriting.close()
                    state.resume(continuation, with: .failure(AzCliError.notInstalled))
                    return
                }
                state.watch(process, timeout: timeout)
            }
        } onCancel: {
            state.cancel(process)
        }
    }

    /// Estado compartido entre el handler de terminación, el timeout y la
    /// cancelación. `@unchecked`: todo bajo `lock`.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var expired = false
        private var watchdog: Task<Void, Never>?

        var timedOut: Bool { lock.withLock { expired } }

        func watch(_ process: Process, timeout: Duration) {
            let task = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                self.lock.withLock { self.expired = true }
                if process.isRunning { process.terminate() }
            }
            lock.withLock { watchdog = task }
        }

        func cancel(_ process: Process) {
            lock.withLock { expired = true }
            if process.isRunning { process.terminate() }
        }

        func resume(_ continuation: CheckedContinuation<AzCommandOutput, any Error>, with result: Result<AzCommandOutput, any Error>) {
            let first = lock.withLock {
                defer { resumed = true }
                watchdog?.cancel()
                return !resumed
            }
            if first { continuation.resume(with: result) }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func set(_ data: Data, stdout: Bool) { lock.withLock { if stdout { out = data } else { err = data } } }
        var values: (Data, Data) { lock.withLock { (out, err) } }
    }
}

// MARK: - Modelos

/// Entrada de `az account list` (solo campos no sensibles).
public struct AzCliAccount: Sendable, Equatable, Decodable {
    public struct User: Sendable, Equatable, Decodable {
        public let name: String
        /// `user` o `servicePrincipal`.
        public let type: String
    }

    /// ID de suscripción (o del tenant, en cuentas "tenant level").
    public let id: String
    public let name: String
    public let state: String?
    /// Tenant por el que `az` accede a la suscripción.
    public let tenantID: String
    /// Tenant dueño de la suscripción (difiere con Lighthouse/B2B).
    public let homeTenantID: String?
    public let isDefault: Bool
    public let user: User?

    /// `az login --allow-no-subscriptions` añade una entrada por tenant sin suscripciones.
    public var isTenantLevel: Bool { id.caseInsensitiveCompare(tenantID) == .orderedSame }

    enum CodingKeys: String, CodingKey {
        case id, name, state, isDefault, user
        case tenantID = "tenantId"
        case homeTenantID = "homeTenantId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state)
        tenantID = try container.decode(String.self, forKey: .tenantID)
        homeTenantID = try container.decodeIfPresent(String.self, forKey: .homeTenantID)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        user = try container.decodeIfPresent(User.self, forKey: .user)
    }
}

/// Access token emitido por `az` (redactado en cualquier representación).
public struct AzCliAccessToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let expiresOn: Date
    public let tenantID: String?
    public let subscriptionID: String?

    public var description: String { "AzCliAccessToken(tenant: \(tenantID ?? "nil"), expiresOn: \(expiresOn), token: <redacted>)" }
    public var debugDescription: String { description }

    /// Identidad de la cuenta desde los claims del token (`tid`, `oid`, `upn`).
    public func identity() throws -> AzureAccountIdentity {
        try AzureAccountIdentity(accessToken: accessToken)
    }
}

public enum AzCliError: Error, Sendable, Equatable {
    /// `az` no está en el sistema (ni en el PATH ni en las rutas de Homebrew).
    case notInstalled
    /// No hay `az login`, o la sesión caducó: `az login` de nuevo.
    case notLoggedIn
    /// La sesión existe pero ese tenant exige reautenticarse (MFA, CA, consentimiento).
    case reauthenticationRequired(tenantID: String?, codes: [Int])
    case timedOut
    case invalidTenant
    /// stdout no es el JSON esperado.
    case malformedOutput
    /// Fallo no clasificado: código de salida y AADSTS si los hay (sin stderr crudo).
    case commandFailed(exitCode: Int32, codes: [Int])
    /// `az` tiene ahora otra cuenta activa que la que fijó el perfil.
    case accountMismatch
    /// El perfil se desconectó mientras se pedía el token.
    case sessionChanged

    /// Texto para la UI (nunca incluye tokens ni la salida cruda de `az`).
    public var userMessage: String {
        switch self {
        case .notInstalled:
            return "Azure CLI (az) is not installed. Install it with \"brew install azure-cli\", then run \"az login\" in Terminal."
        case .notLoggedIn:
            return "Azure CLI has no active session. Run \"az login\" in Terminal, then reconnect."
        case .reauthenticationRequired(let tenant, _):
            let target = tenant.map { " --tenant \($0)" } ?? ""
            return "Azure CLI needs you to sign in again for this tenant. Run \"az login\(target)\" in Terminal."
        case .timedOut:
            return "Azure CLI did not answer in time."
        case .invalidTenant:
            return "Invalid Azure tenant identifier."
        case .malformedOutput:
            return "Azure CLI returned an unexpected response. Update it with \"az upgrade\"."
        case .commandFailed(let code, let codes):
            let aad = codes.isEmpty ? "" : " (AADSTS\(codes.map(String.init).joined(separator: ", AADSTS")))"
            return "Azure CLI failed with exit code \(code)\(aad)."
        case .accountMismatch:
            return "Azure CLI is now signed in with a different account than this profile. "
                + "Run \"az login\" with the profile's account, or create a new profile."
        case .sessionChanged:
            return "The Azure session changed while the request was in progress. Try again."
        }
    }
}

/// Resultado de la detección de `az` (instalado + sesión activa).
public enum AzCliStatus: Sendable, Equatable {
    case ready(accounts: [AzCliAccount])
    case unavailable(AzCliError)

    public var isReady: Bool { if case .ready = self { true } else { false } }
    public var userMessage: String? {
        if case .unavailable(let error) = self { return error.userMessage }
        return nil
    }
}

// MARK: - Origen de tokens

/// Tokens ARM desde la sesión `az login`. Caché por tenant en memoria y una
/// sola invocación de `az` en vuelo por tenant.
public actor AzCliTokenSource {
    /// Recurso (audiencia) del token ARM. Mismo que el CLI usa para Bastion
    /// (`management.core.windows.net`, §1.3); a validar en el spike F0 (#86).
    public static let defaultResource = "https://management.core.windows.net/"

    private let runner: any AzCommandRunning
    private let resource: String
    private let timeout: Duration
    private let skew: TimeInterval
    private let now: @Sendable () -> Date
    private var executable: URL?
    private var tokens: [String: AzCliAccessToken] = [:]
    private var inflight: [String: (id: UUID, task: Task<AzCliAccessToken, any Error>)] = [:]
    private var generation: UInt64 = 0
    private static let log = Logger(subsystem: "com.iapdesktop.mac", category: "auth.azcli")

    public init(
        runner: any AzCommandRunning = ProcessAzCommandRunner(), resource: String = AzCliTokenSource.defaultResource,
        timeout: Duration = .seconds(30), skew: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.resource = resource
        self.timeout = timeout
        self.skew = skew
        self.now = now
    }

    /// Detección: `which az` + `az account list`. Nunca lanza: devuelve el
    /// motivo para que la UI lo explique (instalar `az`, `az login`).
    public func status() async -> AzCliStatus {
        do {
            let accounts = try await accounts()
            return accounts.isEmpty ? .unavailable(.notLoggedIn) : .ready(accounts: accounts)
        } catch let error as AzCliError {
            return .unavailable(error)
        } catch {
            return .unavailable(.malformedOutput)
        }
    }

    /// `az account list --output json` parseado.
    public func accounts() async throws -> [AzCliAccount] {
        let output = try await accountListJSON()  // errores de `az` tal cual, no como "malformado"
        guard let accounts = try? JSONDecoder().decode([AzCliAccount].self, from: output) else {
            throw AzCliError.malformedOutput
        }
        return accounts
    }

    /// stdout crudo (JSON validado) de `az account list` (no contiene tokens).
    func accountListJSON() async throws -> Data {
        let output = try await az(["account", "list", "--output", "json"])
        guard (try? JSONSerialization.jsonObject(with: output)) is [Any] else { throw AzCliError.malformedOutput }
        return output
    }

    /// Access token ARM para `tenantID` (`nil` = tenant por defecto de `az`).
    public func accessToken(tenantID: String?) async throws -> AzCliAccessToken {
        if let tenantID, !AzureTenantID.isValid(tenantID) { throw AzCliError.invalidTenant }
        let key = tenantID?.lowercased() ?? ""
        if let cached = tokens[key], cached.expiresOn.addingTimeInterval(-skew) > now() { return cached }

        let gen = generation
        let entry: (id: UUID, task: Task<AzCliAccessToken, any Error>)
        if let running = inflight[key] {
            entry = running
        } else {
            entry = (UUID(), Task { try await self.fetchToken(tenantID: tenantID) })
            inflight[key] = entry
        }
        let result = await entry.task.result
        if inflight[key]?.id == entry.id { inflight[key] = nil }
        let token = try result.get()
        if generation == gen { tokens[key] = token }
        return token
    }

    /// Olvida los tokens en memoria (cerrar sesión en la app no hace `az logout`:
    /// la sesión del CLI es del usuario).
    public func clearCache() {
        tokens.removeAll()
        for entry in inflight.values { entry.task.cancel() }
        inflight.removeAll()
        generation &+= 1
    }

    private func fetchToken(tenantID: String?) async throws -> AzCliAccessToken {
        var arguments = ["account", "get-access-token", "--resource", resource, "--output", "json"]
        if let tenantID { arguments += ["--tenant", tenantID] }
        let output = try await az(arguments, tenantID: tenantID)
        guard let raw = try? JSONDecoder().decode(RawToken.self, from: output), !raw.accessToken.isEmpty,
              let expiresOn = raw.expiry
        else { throw AzCliError.malformedOutput }
        Self.log.notice("az token acquired tenant=\(raw.tenant ?? tenantID ?? "default", privacy: .public)")
        return AzCliAccessToken(accessToken: raw.accessToken, expiresOn: expiresOn, tenantID: raw.tenant ?? tenantID, subscriptionID: raw.subscription)
    }

    /// Ejecuta `az` y devuelve stdout si terminó bien; clasifica el fallo
    /// mirando stderr sin propagarlo (puede llevar la cuenta del usuario).
    private func az(_ arguments: [String], tenantID: String? = nil) async throws -> Data {
        if executable == nil { executable = await runner.locate() }
        guard let executable else { throw AzCliError.notInstalled }
        let started = Date()
        let output = try await runner.run(executable, arguments: arguments, timeout: timeout)
        let command = arguments.prefix(2).joined(separator: " ")
        Self.log.notice("""
            az \(command, privacy: .public) exit=\(output.exitCode, privacy: .public) \
            ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)
            """)
        guard output.exitCode == 0 else { throw Self.classify(output, tenantID: tenantID) }
        return output.stdout
    }

    static func classify(_ output: AzCommandOutput, tenantID: String?) -> AzCliError {
        let text = String(decoding: output.stderr, as: UTF8.self)
        let codes = aadstsCodes(in: text)
        let lowered = text.lowercased()
        let reauthCodes: Set<Int> = [50076, 50079, 50158, 50072, 50074, 53003, 65001, 50020, 700_082, 70043, 50173]
        if !codes.isDisjoint(with: reauthCodes), tenantID != nil {
            return .reauthenticationRequired(tenantID: tenantID, codes: codes.sorted())
        }
        if lowered.contains("az login") || lowered.contains("please run 'az login'") || !codes.isDisjoint(with: reauthCodes) {
            return .notLoggedIn
        }
        return .commandFailed(exitCode: output.exitCode, codes: codes.sorted())
    }

    static func aadstsCodes(in text: String) -> Set<Int> {
        var codes = Set<Int>()
        var rest = Substring(text)
        while let range = rest.range(of: "AADSTS") {
            let digits = rest[range.upperBound...].prefix { $0.isNumber }
            if let code = Int(digits) { codes.insert(code) }
            rest = rest[range.upperBound...]
        }
        return codes
    }

    private struct RawToken: Decodable {
        let accessToken: String
        let expiresOnEpoch: Double?
        let expiresOnLocal: String?
        let subscription: String?
        let tenant: String?

        enum CodingKeys: String, CodingKey {
            case accessToken, subscription, tenant
            case expiresOnEpoch = "expires_on"
            case expiresOnLocal = "expiresOn"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            subscription = try container.decodeIfPresent(String.self, forKey: .subscription)
            tenant = try container.decodeIfPresent(String.self, forKey: .tenant)
            expiresOnLocal = try container.decodeIfPresent(String.self, forKey: .expiresOnLocal)
            // `expires_on` (epoch, az ≥ 2.54) es número; versiones intermedias lo dan como texto.
            if let number = try? container.decodeIfPresent(Double.self, forKey: .expiresOnEpoch) {
                expiresOnEpoch = number
            } else {
                expiresOnEpoch = (try? container.decodeIfPresent(String.self, forKey: .expiresOnEpoch)).flatMap { $0.flatMap(Double.init) }
            }
        }

        /// `expires_on` (UTC) o, en `az` antiguos, `expiresOn` en hora local.
        var expiry: Date? {
            if let expiresOnEpoch { return Date(timeIntervalSince1970: expiresOnEpoch) }
            guard let expiresOnLocal else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: expiresOnLocal) { return date }
            }
            return nil
        }
    }
}
