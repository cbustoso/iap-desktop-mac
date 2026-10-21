import Foundation

// Auth solo con la sesión `az login` (research §0.1): sin app registration,
// sin PKCE ni device code. Los tokens viven en memoria; los custodia `az`.

public struct AzCommandOutput: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol AzCommandRunning: Sendable {
    func run(_ arguments: [String], timeout: Duration) async throws -> AzCommandOutput
}

public enum AzCliError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case notLoggedIn(tenant: String?)
    case failed(exitCode: Int32, aadsts: String?)
    case timedOut
    case invalidJSON(String)

    public var description: String {
        switch self {
        case .notInstalled:
            return "No se encontró `az`. Instálalo con `brew install azure-cli` y ejecuta `az login`."
        case .notLoggedIn(let tenant):
            let hint = tenant.map { "az login --tenant \($0)" } ?? "az login"
            return "La sesión de Azure CLI no es válida o expiró. Ejecuta `\(hint)`."
        case .failed(let code, let aadsts):
            return "`az` terminó con código \(code)" + (aadsts.map { " (\($0))" } ?? "") + "."
        case .timedOut:
            return "`az` no respondió a tiempo."
        case .invalidJSON(let what):
            return "Salida JSON inesperada de `az` (\(what))."
        }
    }

    /// stderr solo se usa para clasificar; nunca se muestra ni se registra (§0.1).
    static func classify(exitCode: Int32, stderr: Data, tenant: String?) -> AzCliError {
        let text = String(decoding: stderr, as: UTF8.self)
        let aadsts = text.range(of: #"AADSTS\d+"#, options: .regularExpression).map { String(text[$0]) }
        if text.contains("az login") || aadsts == "AADSTS700082" || aadsts == "AADSTS50173" || aadsts == "AADSTS50076" {
            return .notLoggedIn(tenant: tenant)
        }
        return .failed(exitCode: exitCode, aadsts: aadsts)
    }
}

/// Ejecuta `az` con `Process`: sin stdin, con timeout y PATH ampliado con las
/// rutas de Homebrew (un `.app` no hereda el PATH de la shell).
public struct ProcessAzRunner: AzCommandRunning {
    public static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    private let executable: URL?

    public init(executable: URL? = nil) {
        self.executable = executable
    }

    public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let current = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (current + extraSearchPaths.filter { !current.contains($0) }).joined(separator: ":")
        environment["AZURE_CORE_NO_COLOR"] = "true"
        environment["AZURE_CORE_ONLY_SHOW_ERRORS"] = "true"
        environment["AZURE_CORE_SURVEY_MESSAGE"] = "false"
        return environment
    }

    public static func locate(environment: [String: String] = environment()) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("az")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func run(_ arguments: [String], timeout: Duration) async throws -> AzCommandOutput {
        let environment = Self.environment()
        guard let az = executable ?? Self.locate(environment: environment) else { throw AzCliError.notInstalled }

        let process = Process()
        process.executableURL = az
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let box = ProcessBox(process)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            box.terminateForTimeout()
        }
        defer { watchdog.cancel() }

        // Ambos pipes en paralelo: un pipe lleno bloquearía a `az`.
        async let out = Self.readToEnd(stdout.fileHandleForReading)
        async let err = Self.readToEnd(stderr.fileHandleForReading)
        let (outData, errData) = await (out, err)
        let status = await box.waitForExit()
        if box.timedOut { throw AzCliError.timedOut }
        return AzCommandOutput(exitCode: status, stdout: outData, stderr: errData)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}

/// `Process` no es `Sendable`; el acceso se serializa con un lock.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var didTimeOut = false

    init(_ process: Process) { self.process = process }

    var timedOut: Bool { lock.withLock { didTimeOut } }

    func terminateForTimeout() {
        lock.withLock {
            guard process.isRunning else { return }
            didTimeOut = true
            process.terminate()
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.process.waitUntilExit()
                continuation.resume(returning: self.process.terminationStatus)
            }
        }
    }
}

// MARK: - Modelos

public struct AzAccessToken: Sendable, CustomStringConvertible {
    public let accessToken: String
    public let expiresOn: Date
    public let tenantID: String?
    public let subscriptionID: String?

    public var description: String {
        "AzAccessToken(tenant: \(tenantID ?? "nil"), expiresOn: \(expiresOn), token: \(Redact.secret(accessToken)))"
    }
}

public struct AzAccount: Decodable, Sendable, Equatable {
    public struct User: Decodable, Sendable, Equatable {
        public let name: String
        public let type: String
    }

    public let id: String
    public let name: String
    public let tenantId: String
    public let isDefault: Bool
    public let state: String?
    public let user: User?
}

struct RawAccessToken: Decodable {
    let accessToken: String
    let tenant: String?
    let subscription: String?
    let expiresOnEpoch: Double?
    let expiresOnLocal: String?

    enum CodingKeys: String, CodingKey {
        case accessToken, tenant, subscription
        case expiresOnEpoch = "expires_on"
        case expiresOnLocal = "expiresOn"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant)
        subscription = try container.decodeIfPresent(String.self, forKey: .subscription)
        expiresOnLocal = try container.decodeIfPresent(String.self, forKey: .expiresOnLocal)
        // `expires_on` (epoch, az ≥ 2.54) es número; algunas versiones lo dan como texto.
        if let number = try? container.decodeIfPresent(Double.self, forKey: .expiresOnEpoch) {
            expiresOnEpoch = number
        } else {
            expiresOnEpoch = (try? container.decodeIfPresent(String.self, forKey: .expiresOnEpoch))?.flatMap(Double.init)
        }
    }

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

// MARK: - Proveedor de tokens

/// (a) Tokens ARM de la sesión `az`, cacheados en memoria por tenant hasta
/// `expires_on` menos un margen. (b) Listado de cuentas con `az account list`.
public actor AzTokenProvider {
    public static let armResource = "https://management.core.windows.net/"

    private let runner: any AzCommandRunning
    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval
    private let log: SpikeLog
    private var cache: [String: AzAccessToken] = [:]

    public init(
        runner: any AzCommandRunning = ProcessAzRunner(),
        now: @escaping @Sendable () -> Date = Date.init,
        refreshMargin: TimeInterval = 300,
        log: SpikeLog = .shared
    ) {
        self.runner = runner
        self.now = now
        self.refreshMargin = refreshMargin
        self.log = log
    }

    static func tokenArguments(tenant: String?) -> [String] {
        var arguments = ["account", "get-access-token", "--resource", armResource]
        if let tenant { arguments += ["--tenant", tenant] }
        return arguments + ["--output", "json"]
    }

    public func token(tenant: String?) async throws -> AzAccessToken {
        let key = tenant ?? "<default>"
        if let cached = cache[key], cached.expiresOn.addingTimeInterval(-refreshMargin) > now() {
            return cached
        }
        let output = try await runner.run(Self.tokenArguments(tenant: tenant), timeout: .seconds(30))
        guard output.exitCode == 0 else {
            throw AzCliError.classify(exitCode: output.exitCode, stderr: output.stderr, tenant: tenant)
        }
        guard let raw = try? JSONDecoder().decode(RawAccessToken.self, from: output.stdout),
              let expiry = raw.expiry
        else { throw AzCliError.invalidJSON("get-access-token") }
        log.register(secret: raw.accessToken)
        let token = AzAccessToken(accessToken: raw.accessToken, expiresOn: expiry, tenantID: raw.tenant ?? tenant, subscriptionID: raw.subscription)
        cache[key] = token
        log.debug("token ARM obtenido de az: \(token)")
        return token
    }

    public func accounts() async throws -> [AzAccount] {
        let output = try await runner.run(["account", "list", "--output", "json"], timeout: .seconds(30))
        guard output.exitCode == 0 else {
            throw AzCliError.classify(exitCode: output.exitCode, stderr: output.stderr, tenant: nil)
        }
        guard let accounts = try? JSONDecoder().decode([AzAccount].self, from: output.stdout) else {
            throw AzCliError.invalidJSON("account list")
        }
        // `az account list` sin sesión devuelve `[]` con código 0.
        if accounts.isEmpty { throw AzCliError.notLoggedIn(tenant: nil) }
        return accounts
    }
}
