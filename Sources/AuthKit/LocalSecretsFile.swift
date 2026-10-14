import Foundation
import OSLog

/// GH-80: fichero local opcional con el client OAuth, alternativa cómoda a
/// exportar variables de entorno. Vive FUERA del repo
/// (`~/.config/iap-desktop-mac/secrets.env`, o `$XDG_CONFIG_HOME/...`) y solo
/// se lee si existe.
///
/// Formato `KEY=VALUE` por línea (`#` comenta, `export ` opcional, comillas
/// simples o dobles opcionales). Solo se aceptan las claves de
/// `allowedKeys`; el resto se ignora. Los valores nunca se registran.
public enum LocalSecretsFile {
    public static let allowedKeys: Set<String> = [
        ClientIDStore.environmentKey, ClientIDStore.secretEnvironmentKey,
    ]

    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "login")

    /// `$XDG_CONFIG_HOME/iap-desktop-mac/secrets.env` o `~/.config/...`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("iap-desktop-mac/secrets.env", isDirectory: false)
    }

    /// Valores del fichero; `[:]` si no existe, no es un fichero normal o
    /// otros usuarios pueden modificarlo (alguien podría inyectar su propio
    /// client OAuth).
    public static func load(from url: URL) -> [String: String] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return [:]
        }
        if let attributes = try? manager.attributesOfItem(atPath: url.path),
           let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
           permissions & 0o022 != 0 {
            log.error("secrets file ignored reason=writable-by-others mode=\(String(permissions, radix: 8), privacy: .public)")
            return [:]
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("secrets file ignored reason=unreadable")
            return [:]
        }
        let values = parse(text)
        log.notice("secrets file loaded keys=\(values.keys.sorted().joined(separator: ","), privacy: .public)")
        return values
    }

    /// Solo las claves permitidas, con valor no vacío.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard allowedKeys.contains(key), !value.isEmpty else { continue }
            values[key] = value
        }
        return values
    }
}
