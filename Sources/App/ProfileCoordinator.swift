import AppKit
import AuthKit
import OSLog

/// GH-72 (T-MT-4): N perfiles, una ventana Explorer por perfil abierto.
/// Activar un perfil abierto solo lo trae al frente (misma sesión,
/// conexiones intactas); cerrar la ventana de uno solo limpia lo suyo.
///
/// GH-91: multi-proveedor. Cada perfil abre la sesión de su nube
/// (`ProfileSession` para Google, `AzureProfileSession` para la sesión
/// `az login`), ambas detrás de `ProfileSessionHosting`.
@MainActor
final class ProfileCoordinator {
    static let log = Logger(subsystem: "com.iapdesktop.mac", category: "profiles")

    private let store: ProfileStore
    private let migrationCompleted: Bool
    private let registry = ProfileSessionRegistry<any ProfileSessionHosting>()
    private let azureDependencies: AzureProfileSession.Dependencies

    init(
        store: ProfileStore = ProfileStore(), migrationCompleted: Bool,
        azureDependencies: AzureProfileSession.Dependencies = .live
    ) {
        self.store = store
        self.migrationCompleted = migrationCompleted
        self.azureDependencies = azureDependencies
    }

    /// Perfiles conocidos. Sin migración completada, el perfil legado existe
    /// siempre (modo "perfil único implícito", REQ-MT-5).
    var profiles: [ProfileDescriptor] {
        var list = store.list()
        if !list.contains(where: { $0.id == .legacyDefault }), !migrationCompleted || list.isEmpty {
            list.insert(ProfileDescriptor(id: .legacyDefault, displayName: "Perfil principal"), at: 0)
        }
        return list
    }

    var openSessions: [any ProfileSessionHosting] { registry.openIDs.compactMap(registry.session(for:)) }

    func isOpen(_ id: ProfileID) -> Bool { registry.session(for: id) != nil }

    func environment(for id: ProfileID) -> ProfileEnvironment {
        ProfileEnvironment(id: id, migrationCompleted: migrationCompleted)
    }

    /// Perfil inicial: el usado más recientemente, o el legado.
    var initialProfile: ProfileID {
        profiles.max { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }?.id ?? .legacyDefault
    }

    /// Perfil de la ventana al frente (o de alguna de sus ventanas auxiliares).
    var frontSession: (any ProfileSessionHosting)? {
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let session = openSessions.first(where: { $0.owns(window) }) { return session }
        }
        return registry.mostRecent
    }

    /// Abre (o enfoca) la ventana del perfil.
    @discardableResult
    func activate(_ id: ProfileID) -> (any ProfileSessionHosting)? {
        if let existing = registry.session(for: id) {
            _ = registry.activate(id) { existing }
            existing.bringToFront()
            return existing
        }
        guard let descriptor = profiles.first(where: { $0.id == id }) else { return nil }
        guard let session = makeSession(for: descriptor) else {
            // Fallo aislado a este perfil (REQ-MT-6): los demás siguen abiertos.
            Self.log.error("profile open failed profile=\(id.rawValue, privacy: .public) cause=defaults")
            return nil
        }
        session.showsProfileName = { [weak self] in (self?.profiles.count ?? 0) > 1 }
        session.onWindowClosed = { [weak self] session in self?.windowDidClose(for: session) }
        _ = registry.activate(id) { session }
        session.openWindow()
        Self.log.notice("""
            profile opened profile=\(id.rawValue, privacy: .public) \
            provider=\(descriptor.provider.rawValue, privacy: .public)
            """)
        refreshTitles()
        return session
    }

    /// Sesión de la nube del perfil, con su callback de cuenta.
    private func makeSession(for descriptor: ProfileDescriptor) -> (any ProfileSessionHosting)? {
        let id = descriptor.id
        switch descriptor.provider {
        case .google:
            let session = ProfileSession(id: id, descriptor: descriptor, environment: environment(for: id))
            session?.onAccountChanged = { [weak self] session, credential in self?.accountChanged(session, credential) }
            return session
        case .azure:
            let session = AzureProfileSession(
                id: id, descriptor: descriptor, environment: environment(for: id), dependencies: azureDependencies)
            session?.onAccountChanged = { [weak self] session, identity in self?.azureAccountChanged(session, identity) }
            return session
        }
    }

    /// Alta: `profileID` nuevo, nombre provisional, ventana y Sign In. Un
    /// perfil Azure no tiene Sign In propio: su ventana detecta `az` al abrirse.
    @discardableResult
    func createProfile(named name: String? = nil, provider: CloudProvider = .google) -> (any ProfileSessionHosting)? {
        let id = ProfileID.generate()
        let displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Perfil \(profiles.count + 1)"
        do {
            try store.upsert(ProfileDescriptor(id: id, displayName: displayName, provider: provider))
        } catch {
            Self.log.error("profile create failed profile=\(id.rawValue, privacy: .public)")
            return nil
        }
        Self.log.notice("profile created profile=\(id.rawValue, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
        let session = activate(id)
        if provider == .google { session?.showLoginWindow(nil) }
        return session
    }

    /// Baja irreversible (la UI confirma antes). Con la ventana abierta se
    /// rechaza: cerrarla antes limpia sus sesiones con su propia confirmación.
    func removeProfile(_ id: ProfileID) throws {
        guard !isOpen(id) else { throw ProfileError.cannotRemoveActiveProfileWindow }
        try environment(for: id).purge()
        do {
            try store.remove(id)
        } catch ProfileError.notFound(id) where id == .legacyDefault {
            // Legado implícito sin entrada en el índice: no hay nada que quitar.
        }
        Self.log.notice("profile removed profile=\(id.rawValue, privacy: .public)")
        refreshTitles()
    }

    private func windowDidClose(for session: any ProfileSessionHosting) {
        guard registry.remove(session.id) != nil else { return }
        Self.log.notice("profile closed profile=\(session.id.rawValue, privacy: .public)")
        Task { await session.teardown() }
        refreshTitles()
    }

    private func accountChanged(_ session: ProfileSession, _ credential: OfflineCredential?) {
        var descriptor = store.descriptor(for: session.id) ?? session.descriptor
        descriptor.issuer = credential?.issuer
        descriptor.redactedAccount = credential.map { ProfileDescriptor.redactedAccount(issuer: $0.issuer, account: $0.email) }
        if credential != nil { descriptor.lastUsedAt = Date() }
        do {
            try store.upsert(descriptor)
            session.update(descriptor)
        } catch {
            Self.log.error("profile index update failed profile=\(session.id.rawValue, privacy: .public)")
        }
    }

    /// Perfil Azure: fija la cuenta de la sesión `az` (tenant + `oid` + UPN
    /// enmascarado) o, tras Sign Out, la libera para poder ligar otra cuenta.
    private func azureAccountChanged(_ session: AzureProfileSession, _ identity: AzureAccountIdentity?) {
        var descriptor = store.descriptor(for: session.id) ?? session.descriptor
        if let identity {
            descriptor.bindAzureAccount(identity)
            descriptor.lastUsedAt = Date()
        } else {
            descriptor.homeTenantID = nil
            descriptor.azureObjectID = nil
            descriptor.redactedAccount = nil
        }
        do {
            try store.upsert(descriptor)
            session.update(descriptor)
        } catch {
            Self.log.error("profile index update failed profile=\(session.id.rawValue, privacy: .public)")
        }
    }

    /// Con más de un perfil, cada ventana muestra el suyo en la status bar.
    private func refreshTitles() {
        for session in openSessions {
            session.update(profiles.first { $0.id == session.id } ?? session.descriptor)
        }
    }
}
