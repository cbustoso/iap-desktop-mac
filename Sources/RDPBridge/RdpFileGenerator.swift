import Foundation

/// Credencial por referencia para el `.rdp`: solo usuario y dominio. No hay
/// campo de contraseña, así que no puede acabar en el archivo; "Windows App"
/// la pide en su propio prompt o usa la que el usuario guardó allí.
public struct RdpCredentialReference: Equatable, Sendable {
    public var username: String
    public var domain: String?

    public init(username: String, domain: String? = nil) {
        self.username = username
        self.domain = domain
    }
}

/// Serializa `RdpParameters` a un `.rdp` de Microsoft (`clave:tipo:valor`)
/// apuntando al túnel local `127.0.0.1:{puerto}` (T-RDP-1, REQ-RDP-2/4).
/// Los parámetros sin clave `.rdp` equivalente se omiten sin fallar:
/// `restrictedAdminMode`, `dpiScaling` y `connectionTimeout` (los aplica
/// solo la vía FreeRDP).
public enum RdpFileGenerator {
    /// Contenido del `.rdp`, con líneas en orden estable y fin de línea CRLF.
    public static func contents(
        parameters: RdpParameters,
        credential: RdpCredentialReference?,
        localPort: UInt16
    ) throws(RdpError) -> String {
        var lines = ["full address:s:127.0.0.1:\(localPort)"]
        if let credential {
            lines.append("username:s:\(try field("username", credential.username))")
            if let domain = credential.domain, !domain.isEmpty {
                lines.append("domain:s:\(try field("domain", domain))")
            }
        }
        lines += [
            "prompt for credentials:i:\(promptForCredentials(parameters.automaticLogon))",
            "authentication level:i:\(authenticationLevel(parameters.authenticationLevel))",
            "enablecredsspsupport:i:\(flag(parameters.networkLevelAuthentication == .enabled))",
            "administrative session:i:\(flag(parameters.sessionType == .admin))",
            "session bpp:i:\(bitsPerPixel(parameters.colorDepth))",
            "audiomode:i:\(audioMode(parameters.audioPlayback))",
            "audiocapturemode:i:\(flag(parameters.audioInput == .enabled))",
            "redirectclipboard:i:\(flag(parameters.redirectClipboard == .enabled))",
            "redirectprinters:i:\(flag(parameters.redirectPrinter == .enabled))",
            "redirectsmartcards:i:\(flag(parameters.redirectSmartCard == .enabled))",
            "redirectcomports:i:\(flag(parameters.redirectPort == .enabled))",
            "drivestoredirect:s:\(parameters.redirectDrive == .enabled ? "*" : "")",
            "devicestoredirect:s:\(parameters.redirectDevice == .enabled ? "*" : "")",
            "redirectwebauthn:i:\(flag(parameters.redirectWebAuthn == .enabled))",
            "keyboardhook:i:\(keyboardHook(parameters.hookWindowsKeys))",
            "displayconnectionbar:i:\(flag(parameters.connectionBar != .off))",
            "pinconnectionbar:i:\(flag(parameters.connectionBar == .pinned))",
            "dynamic resolution:i:\(flag(dynamicResolution(parameters.desktopSize)))",
        ]
        return lines.map { $0 + "\r\n" }.joined()
    }

    /// Escribe el `.rdp` en `directory` (por defecto un directorio temporal de
    /// la app) con permisos 0600 y devuelve su URL.
    public static func makeFile(
        parameters: RdpParameters,
        credential: RdpCredentialReference?,
        localPort: UInt16,
        name: String,
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("IAPDesktop-RDP", isDirectory: true)
    ) throws -> URL {
        let text = try contents(parameters: parameters, credential: credential, localPort: localPort)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(fileName(for: name))
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// Nombre de archivo seguro: solo `[A-Za-z0-9._-]`, sin rutas.
    static func fileName(for name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return (cleaned.isEmpty ? "session" : cleaned) + ".rdp"
    }

    // MARK: - Traducción (switch exhaustivos: un caso nuevo no compila sin mapear)

    private static func field(_ name: String, _ value: String) throws(RdpError) -> String {
        guard !value.contains(where: \.isNewline) else { throw .invalidCredentialField(name) }
        return value
    }

    private static func flag(_ on: Bool) -> Int { on ? 1 : 0 }

    /// `.rdp`: 0 = conectar sin avisar, 1 = no conectar si falla, 2 = avisar.
    static func authenticationLevel(_ level: RdpAuthenticationLevel) -> Int {
        switch level {
        case .noServerAuthentication: return 0
        case .requireServerAuthentication: return 1
        case .attemptServerAuthentication: return 2
        }
    }

    static func promptForCredentials(_ logon: RdpAutomaticLogon) -> Int {
        switch logon {
        case .enabled: return 0
        case .legacyAbortOnFailure, .disabled: return 1
        }
    }

    static func bitsPerPixel(_ depth: RdpColorDepth) -> Int {
        switch depth {
        case .highColor16: return 16
        case .trueColor24: return 24
        case .deepColor32: return 32
        }
    }

    /// `.rdp`: 0 = en este equipo, 1 = en el remoto, 2 = no reproducir.
    static func audioMode(_ playback: RdpAudioPlayback) -> Int {
        switch playback {
        case .playLocally: return 0
        case .playOnServer: return 1
        case .doNotPlay: return 2
        }
    }

    /// `.rdp`: 0 = local, 1 = remoto, 2 = solo a pantalla completa.
    static func keyboardHook(_ hook: RdpHookWindowsKeys) -> Int {
        switch hook {
        case .disabled: return 0
        case .enabled: return 1
        case .fullScreenOnly: return 2
        }
    }

    static func dynamicResolution(_ size: RdpDesktopSize) -> Bool {
        switch size {
        case .autoAdjust: return true
        case .screenSize, .legacyClientSize: return false
        }
    }
}
