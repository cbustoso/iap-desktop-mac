import AppKit
import AuthKit
import AzureClient

/// GH-91: ventana de un perfil Azure. Muestra el estado de la sesión `az`:
/// detectando, estado vacío con CTA (sin `az` o sin sesión; nunca datos de
/// ejemplo), desconectado, o los tenants y suscripciones de la sesión para
/// elegir los activos. El árbol de VMs/Bastion llega con #92.
@MainActor
final class AzureProfileWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Pane: Equatable { case detecting, signIn, signedOut, accounts }

    static let signInTitle = "Instala Azure CLI y ejecuta az login"
    static let accountsHint = "Elige el tenant y la suscripción activos de este perfil (doble clic o «Usar selección»)."
    static let upcomingNote = "El árbol de VMs y la conexión vía Azure Bastion llegarán en una próxima versión."

    let model: AzureAccountModel
    /// Reintentar la detección (botón del estado vacío y «Conectar» tras Sign Out).
    var onRetry: (@MainActor () -> Void)?

    private(set) var pane: Pane = .detecting

    let headlineLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let commandsLabel = NSTextField(wrappingLabelWithString: "")
    let retryButton = NSButton(title: "Reintentar", target: nil, action: nil)
    let copyButton = NSButton(title: "Copiar comandos", target: nil, action: nil)
    let terminalButton = NSButton(title: "Abrir Terminal", target: nil, action: nil)
    let connectButton = NSButton(title: "Conectar con la sesión az", target: nil, action: nil)
    let useSelectionButton = NSButton(title: "Usar selección", target: nil, action: nil)
    let activeLabel = NSTextField(labelWithString: "")
    let accountLabel = NSTextField(labelWithString: "")
    let outline = NSOutlineView()

    private let progress = NSProgressIndicator()
    private var panes: [Pane: NSView] = [:]
    private var rows: [Row] = []

    init(model: AzureAccountModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "IAP Desktop"
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
        window.center()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Cuenta (UPN enmascarado) en la barra inferior.
    func showAccount(_ text: String?) {
        accountLabel.stringValue = text ?? "sin sesión"
    }

    // MARK: - Estado → vista

    func reload() {
        switch model.state {
        case .idle, .detecting, .loading:
            show(.detecting)
        case .requiresSignIn(let reason):
            headlineLabel.stringValue = Self.headline(for: reason)
            detailLabel.stringValue = reason.userMessage
            commandsLabel.stringValue = Self.commands(for: reason).joined(separator: "\n")
            show(.signIn)
        case .signedOut:
            show(.signedOut)
        case .ready(_, let tenants):
            let selectedKey = (outline.item(atRow: outline.selectedRow) as? Row)?.key
            rows = tenants.map(Row.init(tenant:))
            outline.reloadData()
            outline.expandItem(nil, expandChildren: true)
            if let selectedKey, let index = (0..<outline.numberOfRows).first(where: {
                (outline.item(atRow: $0) as? Row)?.key == selectedKey
            }) {
                outline.selectRowIndexes([index], byExtendingSelection: false)
            }
            activeLabel.stringValue = Self.activeText(model.selection, tenants: tenants)
            updateSelectionButton()
            show(.accounts)
        }
    }

    private func show(_ pane: Pane) {
        self.pane = pane
        for (key, view) in panes { view.isHidden = key != pane }
        if pane == .detecting { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    static func headline(for reason: AzCliError) -> String {
        switch reason {
        case .notInstalled, .notLoggedIn: signInTitle
        case .reauthenticationRequired: "Vuelve a iniciar sesión en el tenant con az login"
        case .accountMismatch: "La sesión az usa otra cuenta que este perfil"
        case .timedOut, .malformedOutput, .commandFailed, .invalidTenant, .sessionChanged:
            "Azure CLI no respondió como se esperaba"
        }
    }

    /// Comandos a ejecutar en Terminal para salir del estado vacío.
    static func commands(for reason: AzCliError) -> [String] {
        switch reason {
        case .notInstalled: ["brew install azure-cli", "az login"]
        case .reauthenticationRequired(let tenant?, _): ["az login --tenant \(tenant)"]
        case .malformedOutput: ["az upgrade", "az login"]
        default: ["az login"]
        }
    }

    static func activeText(_ selection: AzureSelection?, tenants: [AzureTenantEntry]) -> String {
        guard let selection,
              let tenant = tenants.first(where: { $0.tenantID.caseInsensitiveCompare(selection.tenantID) == .orderedSame })
        else { return "Sin tenant activo." }
        guard let subscriptionID = selection.subscriptionID, let subscription = tenant.subscription(subscriptionID) else {
            return "Activo: tenant \(tenant.displayName) (sin suscripción)."
        }
        return "Activa: \(subscription.displayName) · tenant \(tenant.displayName)"
    }

    // MARK: - Acciones

    @objc private func retry(_ sender: Any?) { onRetry?() }

    @objc private func copyCommands(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commandsLabel.stringValue, forType: .string)
    }

    @objc private func openTerminal(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// Fila seleccionada → tenant/suscripción activos del perfil.
    @objc func useSelection(_ sender: Any?) {
        guard let row = outline.item(atRow: outline.selectedRow) as? Row else { return }
        switch row.kind {
        case .tenant(let entry): model.select(tenantID: entry.tenantID, subscriptionID: nil)
        case .subscription(let subscription, let tenantID): model.select(tenantID: tenantID, subscriptionID: subscription.subscriptionID)
        case .failure: return
        }
    }

    private func updateSelectionButton() {
        let row = outline.item(atRow: outline.selectedRow) as? Row
        if case .failure = row?.kind { useSelectionButton.isEnabled = false } else { useSelectionButton.isEnabled = row != nil }
    }

    // MARK: - Layout

    private func buildContent(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        let title = NSTextField(labelWithString: "Microsoft Azure")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Credenciales de la sesión local de Azure CLI (az login).")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor

        panes = [.detecting: detectingPane(), .signIn: signInPane(), .signedOut: signedOutPane(), .accounts: accountsPane()]
        let container = NSView()
        for view in panes.values {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        accountLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        accountLabel.textColor = .secondaryLabelColor
        accountLabel.lineBreakMode = .byTruncatingMiddle
        showAccount(nil)
        let divider = NSBox()
        divider.boxType = .separator

        for view in [title, subtitle, container, divider, accountLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            container.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            container.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: accountLabel.topAnchor, constant: -4),
            accountLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            accountLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            accountLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
    }

    private func centered(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        let pane = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor),
        ])
        return pane
    }

    private func detectingPane() -> NSView {
        progress.style = .spinning
        progress.controlSize = .small
        let label = NSTextField(labelWithString: "Detectando Azure CLI y la sesión az…")
        label.textColor = .secondaryLabelColor
        return centered([progress, label])
    }

    private func signInPane() -> NSView {
        headlineLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headlineLabel.alignment = .center
        detailLabel.alignment = .center
        detailLabel.textColor = .secondaryLabelColor
        commandsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandsLabel.alignment = .center
        commandsLabel.isSelectable = true
        retryButton.keyEquivalent = "\r"
        for (button, action) in [(retryButton, #selector(retry(_:))), (copyButton, #selector(copyCommands(_:))),
                                 (terminalButton, #selector(openTerminal(_:)))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let buttons = NSStackView(views: [terminalButton, copyButton, retryButton])
        buttons.spacing = 8
        let note = NSTextField(wrappingLabelWithString:
            "La app usa solo la sesión de Azure CLI: no guarda tokens. Tras ejecutar los comandos, pulsa Reintentar.")
        note.alignment = .center
        note.textColor = .tertiaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return centered([headlineLabel, detailLabel, commandsLabel, buttons, note])
    }

    private func signedOutPane() -> NSView {
        let label = NSTextField(wrappingLabelWithString:
            "Perfil desconectado. La sesión de Azure CLI sigue abierta en este Mac (no se ejecutó az logout).")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        connectButton.target = self
        connectButton.action = #selector(retry(_:))
        connectButton.bezelStyle = .rounded
        return centered([label, connectButton])
    }

    private func accountsPane() -> NSView {
        let hint = NSTextField(wrappingLabelWithString: Self.accountsHint)
        hint.textColor = .secondaryLabelColor

        for (identifier, title, width) in [("name", "Nombre", 300.0), ("id", "ID", 290.0), ("state", "Estado", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.dataSource = self
        outline.delegate = self
        outline.usesAlternatingRowBackgroundColors = true
        outline.target = self
        outline.doubleAction = #selector(useSelection(_:))
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        useSelectionButton.target = self
        useSelectionButton.action = #selector(useSelection(_:))
        useSelectionButton.bezelStyle = .rounded
        activeLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        activeLabel.lineBreakMode = .byTruncatingTail
        let note = NSTextField(wrappingLabelWithString: Self.upcomingNote)
        note.textColor = .tertiaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let pane = NSView()
        for view in [hint, scroll, activeLabel, useSelectionButton, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        activeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: pane.topAnchor),
            hint.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: useSelectionButton.topAnchor, constant: -8),
            useSelectionButton.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            useSelectionButton.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),
            activeLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            activeLabel.centerYAnchor.constraint(equalTo: useSelectionButton.centerYAnchor),
            activeLabel.trailingAnchor.constraint(lessThanOrEqualTo: useSelectionButton.leadingAnchor, constant: -12),
            note.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    // MARK: - Outline (tenant → suscripciones)

    final class Row: NSObject {
        enum Kind {
            case tenant(AzureTenantEntry)
            case subscription(AzureSubscription, tenantID: String)
            case failure(String)
        }

        let kind: Kind
        let children: [Row]

        init(tenant entry: AzureTenantEntry) {
            kind = .tenant(entry)
            children = entry.failure.map { [Row(kind: .failure($0))] }
                ?? entry.subscriptions.map { Row(kind: .subscription($0, tenantID: entry.tenantID)) }
        }

        private init(kind: Kind) {
            self.kind = kind
            children = []
        }

        /// Identidad estable entre recargas (para conservar la fila seleccionada).
        var key: String {
            switch kind {
            case .tenant(let entry): "t:\(entry.tenantID.lowercased())"
            case .subscription(let subscription, let tenantID): "s:\(tenantID.lowercased())/\(subscription.subscriptionID.lowercased())"
            case .failure(let message): "f:\(message)"
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Row)?.children.count ?? rows.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Row)?.children[index] ?? rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Row)?.children.isEmpty ?? true)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateSelectionButton() }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row, let column = tableColumn?.identifier.rawValue else { return nil }
        let text = Self.text(for: row, column: column, selection: model.selection)
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        if column == "id" { label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
        if column == "name", Self.isActive(row, selection: model.selection) {
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        }
        if case .failure = row.kind { label.textColor = .systemOrange }
        return label
    }

    static func isActive(_ row: Row, selection: AzureSelection?) -> Bool {
        guard let selection else { return false }
        switch row.kind {
        case .tenant(let entry):
            return selection.subscriptionID == nil && entry.tenantID.caseInsensitiveCompare(selection.tenantID) == .orderedSame
        case .subscription(let subscription, let tenantID):
            return tenantID.caseInsensitiveCompare(selection.tenantID) == .orderedSame
                && subscription.subscriptionID.caseInsensitiveCompare(selection.subscriptionID ?? "") == .orderedSame
        case .failure:
            return false
        }
    }

    static func text(for row: Row, column: String, selection: AzureSelection?) -> String {
        let mark = isActive(row, selection: selection) ? "✓ " : ""
        switch (row.kind, column) {
        case (.tenant(let entry), "name"): return mark + entry.displayName
        case (.tenant(let entry), "id"): return entry.tenantID
        case (.tenant(let entry), "state"):
            if entry.failure != nil { return "Error" }
            return entry.subscriptions.count == 1 ? "1 suscripción" : "\(entry.subscriptions.count) suscripciones"
        case (.subscription(let subscription, _), "name"): return mark + subscription.displayName
        case (.subscription(let subscription, _), "id"): return subscription.subscriptionID
        case (.subscription(let subscription, _), "state"): return subscription.state
        case (.failure(let message), "name"): return message
        default: return ""
        }
    }

    /// Filas visibles (para tests): nombre de cada una.
    var visibleRowNames: [String] {
        (0..<outline.numberOfRows).compactMap { index in
            (outline.item(atRow: index) as? Row).map { Self.text(for: $0, column: "name", selection: model.selection) }
        }
    }
}
