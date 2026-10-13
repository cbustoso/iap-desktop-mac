import AppKit
import ExplorerUI
import GCPClient
import OSLog
import RDPBridge
import SettingsStore
import TunnelKit

// CBU-52: RDP de extremo a extremo por la vía fallback (ADR-0003 §2):
// túnel IAP → .rdp → "Windows App". Solo cableado; la lógica vive en
// RDPBridge (conector) y GCPClient (reset de credenciales).
// CBU-54: la credencial generada se guarda en Keychain (ámbito instancia,
// mismas claves que el panel Settings) y se puede regenerar.

/// Credenciales Windows por instancia en los stores del panel Settings:
/// `RdpPassword` en Keychain (`KeychainSettingsStore`) y `RdpUsername`
/// (no secreto) en el store normal de la instancia. La contraseña nunca va a
/// UserDefaults, disco plano ni logs.
struct KeychainWindowsCredentialVault: WindowsCredentialVault {
    static let usernameKey = "RdpUsername"
    static let passwordKey = "RdpPassword"

    /// Mismo esquema que `ApplicationSettingsDataSource.store(for:isSensitive:)`.
    static func component(for instance: InstanceInfo) -> String {
        SettingsScope.instance(project: instance.project, zone: instance.zone, instance: instance.name)
            .persistencePath.replacingOccurrences(of: "/", with: ".")
    }

    var secureStore: @Sendable (InstanceInfo) -> any SettingsStore = {
        KeychainSettingsStore(service: "com.iapdesktop.mac.settings.secure.\(component(for: $0))")
    }
    var plainStore: @Sendable (InstanceInfo) -> any SettingsStore = {
        UserDefaultsSettingsStore(suiteName: "com.iapdesktop.mac.settings.\(component(for: $0))")
    }

    func load(for instance: InstanceInfo) throws -> WindowsLogonCredential? {
        let password: Setting<String> = try secureStore(instance).read(key: Self.passwordKey, defaultValue: "")
        guard password.isSpecified else { return nil }
        let username: Setting<String> = try plainStore(instance).read(key: Self.usernameKey, defaultValue: "")
        return WindowsLogonCredential(username: username.value, password: password.value)
    }

    func save(_ credential: WindowsLogonCredential, for instance: InstanceInfo) throws {
        var password = Setting(key: Self.passwordKey, defaultValue: "")
        password.value = credential.password
        try secureStore(instance).write(password)
        var username = Setting(key: Self.usernameKey, defaultValue: "")
        username.value = credential.username
        try plainStore(instance).write(username)
    }
}

/// Túnel `IapListener` hacia `remotePort` de la VM.
final class IapRdpTunnel: RdpTunnel {
    private let listener: IapListener
    init(listener: IapListener) { self.listener = listener }
    var localPort: UInt16 { listener.port }
    func close() async { await listener.stop() }
}

struct IapRdpTunnels: RdpTunnelOpening {
    let accessToken: @Sendable () async throws -> String
    var opener: any RelayChannelOpening = NIOWebSocketTransport()

    func openTunnel(to target: RdpTarget, remotePort: UInt16) async throws -> any RdpTunnel {
        let endpoint = RelayEndpoint(IapEndpoint(
            project: target.project, zone: target.zone, instance: target.instance, port: remotePort))
        let opener = self.opener
        let accessToken = self.accessToken
        // Falla pronto (IAP/firewall) antes de lanzar "Windows App" (paridad probe).
        try await RelayStream.probe(endpoint: endpoint, opener: opener, accessToken: accessToken)
        let listener = try await IapListener.start {
            try await RelayStream.connect(endpoint: endpoint, opener: opener, accessToken: accessToken)
        }
        return IapRdpTunnel(listener: listener)
    }
}

/// Flujo de conexión RDP: credenciales (opcional) + túnel + "Windows App".
@MainActor
final class RdpConnectFlow {
    nonisolated static let log = Logger(subsystem: "com.iapdesktop.mac", category: "rdp")

    private let client: GCPClient
    private let connector: RdpFallbackConnector
    private let email: () async -> String?
    private let window: () -> NSWindow?
    private let note: (String) -> Void
    private let credentials: WindowsCredentialCoordinator
    private var busy: Set<RdpTarget> = []

    /// Instancias para las que el siguiente `connect` solo debe generar
    /// credenciales (menú "Generate Windows credentials…"): la App solo
    /// cablea `connect`, y App.swift queda fuera de esta tarea.
    static var credentialsOnly: Set<String> = []

    init(
        client: GCPClient, tunnels: any RdpTunnelOpening,
        email: @escaping () async -> String?, window: @escaping () -> NSWindow?, note: @escaping (String) -> Void
    ) {
        self.client = client
        self.connector = RdpFallbackConnector(tunnels: tunnels)
        self.email = email
        self.window = window
        self.note = note
        self.credentials = WindowsCredentialCoordinator(vault: KeychainWindowsCredentialVault()) { instance, username in
            let credential = try await client.resetWindowsCredentials(
                project: instance.project, zone: instance.zone, instance: instance.name, username: username)
            return WindowsLogonCredential(username: credential.username, password: credential.password)
        }
        RdpFallbackConnector.removeGeneratedFiles()
    }

    func shutdown() async {
        await connector.shutdown()
    }

    func connect(_ instance: InstanceInfo) {
        if Self.credentialsOnly.remove(instance.id) != nil {
            generateCredentials(instance)
            return
        }
        let target = RdpTarget(project: instance.project, zone: instance.zone, instance: instance.name)
        guard !busy.contains(target) else { return }
        guard WindowsAppLauncher().applicationURL != nil else {
            present(RdpError.windowsAppNotInstalled(help: RdpError.windowsAppHelp), instance: instance)
            return
        }
        busy.insert(target)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy.remove(target) }
            do {
                guard let username = try await self.resolveCredential(for: target, instance: instance) else { return }
                self.note("RDP: abriendo túnel IAP a \(instance.name):3389…")
                let launch = try await self.connector.connect(
                    to: target, parameters: RdpParameters(),
                    credential: username.map { RdpCredentialReference(username: $0) })
                Self.log.notice("""
                    rdp launched target=\(target.description, privacy: .public) \
                    localPort=\(launch.localPort, privacy: .public) reused=\(launch.reusedTunnel, privacy: .public)
                    """)
                self.note("RDP: Windows App → 127.0.0.1:\(launch.localPort) (túnel IAP a \(instance.name))")
            } catch {
                Self.log.error("rdp failed target=\(target.description, privacy: .public) \(Self.cause(error), privacy: .public)")
                self.note("")
                self.present(error, instance: instance)
            }
        }
    }

    /// Menú "Generate Windows credentials…": genera (o regenera) y guarda,
    /// sin abrir túnel ni Windows App.
    func generateCredentials(_ instance: InstanceInfo) {
        let target = RdpTarget(project: instance.project, zone: instance.zone, instance: instance.name)
        guard !busy.contains(target) else { return }
        busy.insert(target)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy.remove(target) }
            let stored = self.credentials.stored(for: instance)
            let email = await self.email()
            let suggested = stored?.username ?? WindowsUsername.suggest(email: email)
            guard case .generate(let username) = self.askForCredentials(
                instance: instance, suggested: suggested, connecting: false, replacing: stored != nil)
            else { return }
            do {
                _ = try await self.generateAndShow(instance, username: username, connecting: false)
            } catch {
                Self.log.error("rdp credentials failed target=\(target.description, privacy: .public) \(Self.cause(error), privacy: .public)")
                self.note("")
                self.present(error, instance: instance)
            }
        }
    }

    /// `nil` = cancelado; `.some(nil)` = sin usuario (Windows App lo pedirá).
    private func resolveCredential(for target: RdpTarget, instance: InstanceInfo) async throws -> String?? {
        // Guardada en Keychain y utilizable: se muestra el diálogo (no solo
        // aviso) porque Windows App no puede rellenar sola la contraseña del
        // .rdp — el usuario debe pegarla desde el portapapeles.
        if let stored = credentials.stored(for: instance) {
            Self.log.notice("""
                rdp keychain hit target=\(target.description, privacy: .public) \
                user=\(stored.username, privacy: .public)
                """)
            copyToPasteboard(stored.password)
            switch showGenerated(
                WindowsCredentialCoordinator.Generated(credential: stored, persisted: true),
                instance: instance, connecting: true)
            {
            case .done:
                return .some(stored.username)
            case .cancel:
                return nil
            case .regenerate:
                guard confirmRegenerate(instance: instance, username: stored.username) else {
                    return .some(stored.username)
                }
                guard let credential = try await generateAndShow(
                    instance, username: stored.username, connecting: true)
                else {
                    return nil
                }
                return .some(credential.username)
            }
        }
        Self.log.notice("rdp keychain miss target=\(target.description, privacy: .public)")
        let suggested = WindowsUsername.suggest(email: await email())
        switch askForCredentials(instance: instance, suggested: suggested, connecting: true, replacing: false) {
        case .cancel:
            return nil
        case .skip:
            return .some(nil)
        case .generate(let username):
            guard let credential = try await generateAndShow(instance, username: username, connecting: true) else {
                return nil
            }
            return .some(credential.username)
        }
    }

    /// Genera, guarda y muestra; "Regenerar…" repite el reset (con
    /// confirmación) y sustituye la anterior, que deja de valer en la VM.
    private func generateAndShow(
        _ instance: InstanceInfo, username: String, connecting: Bool
    ) async throws -> WindowsLogonCredential? {
        let target = RdpTarget(project: instance.project, zone: instance.zone, instance: instance.name)
        while true {
            note("RDP: generando credenciales Windows para \(username) en \(instance.name)…")
            let generated = try await credentials.generate(for: instance, username: username)
            Self.log.notice("""
                rdp credentials generated target=\(target.description, privacy: .public) \
                persisted=\(generated.persisted, privacy: .public)
                """)
            copyToPasteboard(generated.credential.password)
            note("")
            switch showGenerated(generated, instance: instance, connecting: connecting) {
            case .done:
                return generated.credential
            case .cancel:
                return nil
            case .regenerate:
                guard confirmRegenerate(instance: instance, username: username) else {
                    return connecting ? generated.credential : nil
                }
            }
        }
    }

    private enum CredentialChoice { case generate(String), skip, cancel }

    private func askForCredentials(
        instance: InstanceInfo, suggested: String, connecting: Bool, replacing: Bool
    ) -> CredentialChoice {
        let alert = NSAlert()
        alert.messageText = connecting
            ? "Conectar a \(instance.name) por RDP" : "Generar credenciales Windows para \(instance.name)"
        let intro = replacing
            ? "Ya hay credenciales guardadas: se resetea la contraseña y la anterior dejará de funcionar. "
            : "¿Generar (o resetear) un usuario Windows local? "
        let instructions = intro + "La contraseña nueva se guarda en el llavero de macOS y se copia "
            + "al portapapeles para pegarla en Windows App."
        alert.informativeText = instructions
        let field = NSTextField(string: suggested)
        field.placeholderString = "Usuario Windows"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: connecting ? "Generar y conectar" : "Generar")
        if connecting { alert.addButton(withTitle: "Conectar sin credenciales") }
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        while true {
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                let username = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard WindowsUsername.isValidLocal(username) else {
                    alert.informativeText = "Usuario no válido: 1–20 caracteres, sin espacios ni \" / \\ [ ] : ; | = , + * ? < >."
                    continue
                }
                return .generate(username)
            case .alertSecondButtonReturn where connecting:
                return .skip
            default:
                return .cancel
            }
        }
    }

    private enum GeneratedChoice { case done, regenerate, cancel }

    private func showGenerated(
        _ generated: WindowsCredentialCoordinator.Generated, instance: InstanceInfo, connecting: Bool
    ) -> GeneratedChoice {
        let alert = NSAlert()
        alert.messageText = "Credenciales Windows listas"
        let storage = generated.persisted
            ? "Guardada en el llavero de macOS."
            : "No se pudo guardar en el llavero: tendrás que regenerarla la próxima vez."
        alert.informativeText = "Usuario: \(generated.credential.username)\nLa contraseña está en el portapapeles "
            + "(se borra en 90 s). Pégala cuando Windows App la pida para \(instance.name).\n\(storage)"
        alert.addButton(withTitle: connecting ? "Abrir Windows App" : "OK")
        alert.addButton(withTitle: "Regenerar…")
        if connecting { alert.addButton(withTitle: "Cancelar") }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .done
        case .alertSecondButtonReturn: return .regenerate
        default: return .cancel
        }
    }

    private func confirmRegenerate(instance: InstanceInfo, username: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Regenerar la contraseña de \(username)?"
        alert.informativeText = "Se resetea en \(instance.name): la contraseña actual dejará de funcionar "
            + "(también en sesiones abiertas que la vuelvan a pedir)."
        alert.addButton(withTitle: "Regenerar")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Portapapeles marcado como oculto/transitorio (los gestores de
    /// portapapeles no lo guardan) y vaciado a los 90 s si nadie lo cambió.
    private func copyToPasteboard(_ secret: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
    }

    /// Causa para el log: tipo y caso, sin mensajes con datos de la sesión.
    nonisolated static func cause(_ error: any Error) -> String {
        switch error {
        case let error as WindowsCredentialError: return "cause=credentials \(error)"
        case let error as RdpError: return "cause=launch \(error)"
        case let error as TunnelError: return "cause=tunnel \(error)"
        default: return "cause=other type=\(type(of: error))"
        }
    }

    private func present(_ error: any Error, instance: InstanceInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No se pudo conectar a \(instance.name) por RDP"
        var help: URL?
        switch error {
        case RdpError.windowsAppNotInstalled(let url):
            alert.informativeText = "Para RDP hace falta \"Windows App\" de Microsoft (gratis en la App Store)."
            help = url
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Abrir App Store")
        case let error as WindowsCredentialError:
            alert.informativeText = error.message
            alert.addButton(withTitle: "OK")
        case let error as TunnelError:
            alert.informativeText = error.userMessage
            help = error.helpTopic?.url
            alert.addButton(withTitle: "OK")
            if let title = error.helpTopic?.title { alert.addButton(withTitle: title) }
        default:
            alert.informativeText = "No se pudo abrir la sesión RDP."
            alert.addButton(withTitle: "OK")
        }
        let open: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn, let help { NSWorkspace.shared.open(help) }
        }
        if let window = window(), window.isVisible {
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { open(response) } }
        } else {
            open(alert.runModal())
        }
    }
}

/// Encamina doble clic y menú contextual de VMs Windows a RDP sin tocar
/// ExplorerUI (que hoy solo cablea Linux): envuelve la acción de doble clic
/// del outline y su delegado de menú, y delega el resto al original.
@MainActor
final class WindowsConnectInterposer: NSObject, NSMenuDelegate {
    private weak var outline: NSOutlineView?
    private weak var originalTarget: AnyObject?
    private let originalAction: Selector?
    private weak var originalMenuDelegate: (any NSMenuDelegate)?
    private let onWindowsConnect: (InstanceInfo) -> Void
    /// GH-60: "Browse files…" en instancias Linux (SFTP); `nil` = sin item.
    var onBrowseFiles: ((InstanceInfo) -> Void)?

    /// Título del item SFTP del menú contextual.
    static let browseFilesTitle = "Browse files…"

    init?(window: NSWindow?, onWindowsConnect: @escaping (InstanceInfo) -> Void) {
        guard let outline = Self.findOutline(in: window?.contentView) else { return nil }
        self.outline = outline
        self.originalTarget = outline.target
        self.originalAction = outline.doubleAction
        self.originalMenuDelegate = outline.menu?.delegate
        self.onWindowsConnect = onWindowsConnect
        super.init()
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.menu?.delegate = self
        // CBU-54: "Generate Windows credentials…" → mismo flujo, sin conectar.
        (window?.windowController as? ExplorerWindowController)?.onGenerateWindowsCredentialsRequest = {
            [onWindowsConnect] instance in
            RdpConnectFlow.credentialsOnly.insert(instance.id)
            onWindowsConnect(instance)
        }
    }

    /// Instancia de la fila `row`, si es una instancia.
    private func instance(atRow row: Int) -> InstanceInfo? {
        guard row >= 0, let item = outline?.item(atRow: row),
              let node = Mirror(reflecting: item).children.first(where: { $0.label == "node" })?.value as? ExplorerNode,
              case .instance(let instance) = node
        else { return nil }
        return instance
    }

    /// Instancia Windows de la fila `row`, si lo es.
    private func windowsInstance(atRow row: Int) -> InstanceInfo? {
        instance(atRow: row).flatMap { $0.os == .windows ? $0 : nil }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        if let instance = windowsInstance(atRow: outline?.clickedRow ?? -1) {
            onWindowsConnect(instance)
        } else if let originalAction {
            NSApp.sendAction(originalAction, to: originalTarget, from: sender)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        originalMenuDelegate?.menuNeedsUpdate?(menu)
        if onBrowseFiles != nil, let linux = instance(atRow: outline?.clickedRow ?? -1), linux.os == .linux,
           let connectIndex = menu.items.firstIndex(where: { $0.title == ExplorerCommand.connect.title }) {
            let browse = NSMenuItem(title: Self.browseFilesTitle, action: #selector(browseFromMenu(_:)), keyEquivalent: "")
            browse.target = self
            browse.representedObject = RdpMenuPayload(instance: linux)
            browse.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            browse.toolTip = "Explorar ficheros por SFTP (misma sesión SSH)"
            menu.insertItem(browse, at: connectIndex + 1)
        }
        guard let instance = windowsInstance(atRow: outline?.clickedRow ?? -1),
              let connect = menu.items.first(where: { $0.title == ExplorerCommand.connect.title })
        else { return }
        connect.target = self
        connect.action = #selector(connectFromMenu(_:))
        connect.representedObject = RdpMenuPayload(instance: instance)
        connect.isEnabled = true
        connect.badge = nil
        connect.toolTip = "Abrir RDP con Windows App vía IAP"
    }

    @objc private func browseFromMenu(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? RdpMenuPayload { onBrowseFiles?(payload.instance) }
    }

    @objc private func connectFromMenu(_ sender: NSMenuItem) {
        if let payload = sender.representedObject as? RdpMenuPayload { onWindowsConnect(payload.instance) }
    }

    private final class RdpMenuPayload: NSObject {
        let instance: InstanceInfo
        init(instance: InstanceInfo) { self.instance = instance }
    }

    private static func findOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = findOutline(in: subview) { return found }
        }
        return nil
    }
}
