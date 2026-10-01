import Foundation

/// VM destino de una sesión RDP.
public struct RdpTarget: Sendable, Hashable, CustomStringConvertible {
    public var project: String
    public var zone: String
    public var instance: String

    public init(project: String, zone: String, instance: String) {
        self.project = project
        self.zone = zone
        self.instance = instance
    }

    public var description: String { "\(project)/\(zone)/\(instance)" }
}

/// Túnel local `127.0.0.1:{localPort}` → VM (lo implementa la App sobre
/// `TunnelKit.IapListener`; RDPBridge no depende de TunnelKit).
public protocol RdpTunnel: AnyObject, Sendable {
    var localPort: UInt16 { get }
    func close() async
}

public protocol RdpTunnelOpening: Sendable {
    /// Abre (y prueba) un túnel hacia `remotePort` de la VM.
    func openTunnel(to target: RdpTarget, remotePort: UInt16) async throws -> any RdpTunnel
}

/// Vía fallback de extremo a extremo (T-RDP-2): túnel IAP → `.rdp` apuntando
/// al puerto local → "Windows App". Un túnel por VM, reutilizado mientras la
/// App viva: "Windows App" puede reconectar por el mismo puerto y no avisa
/// cuando termina la sesión.
@MainActor
public final class RdpFallbackConnector {
    public struct Launch: Sendable, Equatable {
        public let localPort: UInt16
        public let fileURL: URL
        public let reusedTunnel: Bool
    }

    private let tunnels: any RdpTunnelOpening
    private let launcher: any WindowsAppLaunching
    private let directory: URL
    private var open: [RdpTarget: any RdpTunnel] = [:]

    public init(
        tunnels: any RdpTunnelOpening,
        launcher: any WindowsAppLaunching = WindowsAppLauncher(),
        directory: URL = RdpFallbackConnector.defaultDirectory
    ) {
        self.tunnels = tunnels
        self.launcher = launcher
        self.directory = directory
    }

    public nonisolated static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("IAPDesktop-RDP", isDirectory: true)

    public var activeTargets: Set<RdpTarget> { Set(open.keys) }

    /// Abre (o reutiliza) el túnel, escribe el `.rdp` y lo lanza. Si "Windows
    /// App" falla, el túnel recién abierto se cierra y el `.rdp` se borra.
    public func connect(
        to target: RdpTarget, parameters: RdpParameters, credential: RdpCredentialReference?
    ) async throws -> Launch {
        let reused = open[target] != nil
        let tunnel: any RdpTunnel
        if let existing = open[target] {
            tunnel = existing
        } else {
            tunnel = try await tunnels.openTunnel(to: target, remotePort: parameters.port)
            open[target] = tunnel
        }
        let fileURL: URL
        do {
            fileURL = try RdpFileGenerator.makeFile(
                parameters: parameters, credential: credential, localPort: tunnel.localPort,
                name: "\(target.instance)-\(tunnel.localPort)", directory: directory)
        } catch {
            if !reused { await disconnect(target) }
            throw error
        }
        do {
            try await launcher.open(fileURL)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            if !reused { await disconnect(target) }
            throw error
        }
        return Launch(localPort: tunnel.localPort, fileURL: fileURL, reusedTunnel: reused)
    }

    public func disconnect(_ target: RdpTarget) async {
        guard let tunnel = open.removeValue(forKey: target) else { return }
        await tunnel.close()
    }

    /// Cierra todos los túneles y borra los `.rdp` generados (al salir).
    public func shutdown() async {
        for target in Array(open.keys) { await disconnect(target) }
        Self.removeGeneratedFiles(in: directory)
    }

    /// Borra `.rdp` de ejecuciones anteriores (contienen usuario, nunca contraseña).
    public nonisolated static func removeGeneratedFiles(in directory: URL = defaultDirectory) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "rdp" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Usuario Windows local (paridad `WindowsUser.cs`).
public enum WindowsUsername {
    private static let disallowed = Set("\"/\\[]:;|=,+*?<>")

    /// Parte local del email, como mucho 20 caracteres; si no hay email, `fallback`.
    public static func suggest(email: String?, fallback: String = NSUserName()) -> String {
        if let email, let at = email.firstIndex(of: "@"), at > email.startIndex {
            return String(email[..<at].prefix(20))
        }
        return String(fallback.prefix(20))
    }

    /// Nombre local válido: 1…20 caracteres, sin los prohibidos por Windows,
    /// sin forma UPN (`a@b.c`) y sin saltos de línea.
    public static func isValidLocal(_ username: String) -> Bool {
        !username.isEmpty && username.count <= 20 && !isUserPrincipalName(username)
            && !username.contains(where: { disallowed.contains($0) || $0.isNewline || $0.isWhitespace })
    }

    static func isUserPrincipalName(_ username: String) -> Bool {
        guard let at = username.firstIndex(of: "@"), at > username.startIndex,
              let dot = username.lastIndex(of: ".") else { return false }
        return dot > at
    }
}
