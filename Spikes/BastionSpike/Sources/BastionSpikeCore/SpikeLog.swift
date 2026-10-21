import Foundation

/// Redacción de secretos para los logs del spike (research §3.3 (4): `aztoken`,
/// `authToken` y `websocketToken` nunca se registran).
public enum Redact {
    /// Sustituye un secreto por su longitud: suficiente para depurar sin exponerlo.
    public static func secret(_ value: String) -> String {
        value.isEmpty ? "<vacío>" : "<redacted:\(value.count)>"
    }

    /// Campos del `POST /api/tokens` que llevan credenciales.
    public static let sensitiveFormFields: Set<String> = ["aztoken", "token"]

    /// Cuerpo form legible con los campos sensibles enmascarados.
    public static func form(_ fields: [(String, String)]) -> String {
        fields.map { name, value in
            "\(name)=\(sensitiveFormFields.contains(name) ? secret(value) : value)"
        }.joined(separator: "&")
    }

    /// UPN enmascarado: `a***@contoso.com`.
    public static func upn(_ value: String) -> String {
        guard let at = value.firstIndex(of: "@"), at > value.startIndex else { return secret(value) }
        return "\(value[value.startIndex])***\(value[at...])"
    }
}

/// Logger a stderr. Además de los `Redact.*` explícitos, borra de cada línea
/// cualquier secreto registrado (defensa en profundidad: si un mensaje de
/// error del servidor repite un token, tampoco sale).
public final class SpikeLog: @unchecked Sendable {
    public static let shared = SpikeLog()

    private let lock = NSLock()
    private var secrets: Set<String> = []
    private var verboseEnabled = false
    private var sink: @Sendable (String) -> Void

    public init(sink: @escaping @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }) {
        self.sink = sink
    }

    public var verbose: Bool {
        get { lock.withLock { verboseEnabled } }
        set { lock.withLock { verboseEnabled = newValue } }
    }

    /// Los secretos muy cortos no se registran: reemplazarlos destrozaría el log.
    public func register(secret: String) {
        guard secret.count >= 8 else { return }
        lock.withLock { _ = secrets.insert(secret) }
    }

    public func scrub(_ message: String) -> String {
        let known = lock.withLock { secrets }
        return known.reduce(message) { text, secret in
            text.replacingOccurrences(of: secret, with: Redact.secret(secret))
        }
    }

    public func info(_ message: String) { emit("INFO", message) }
    public func warn(_ message: String) { emit("WARN", message) }
    public func error(_ message: String) { emit("ERROR", message) }
    public func debug(_ message: String) {
        if verbose { emit("DEBUG", message) }
    }

    private func emit(_ level: String, _ message: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        sink("\(stamp) [\(level)] \(scrub(message))")
    }
}
