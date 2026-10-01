import AppKit

/// Ventana principal estilo IAP Desktop, todo programático (sin nibs ni SwiftUI):
///
/// ```
/// ┌ NSToolbar: Add project · Refresh · Settings ───────────────────┐
/// │ Project Explorer │ Área de sesiones (NSTabView / empty-state)   │
/// │ filtro + toggles │──────────────────────────────────────────────│
/// │ árbol            │ Properties                                   │
/// ├──────────────────┴──────────────────────────────────────────────┤
/// │ status bar: MOCK — N proyectos, M instancias        cuenta      │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
///
/// Solo colores semánticos del sistema: respeta apariencia clara/oscura.
public final class ExplorerWindowController: NSWindowController {
    private let viewModel: ExplorerViewModel
    private let dataSourceLabel: String

    private let outline = NSOutlineView()
    private let mainSplit = NSSplitView()
    private let centerSplit = NSSplitView()
    let sessionArea = SessionAreaView()

    /// Nota transitoria de la status bar (p. ej. por qué no cargaron los
    /// proyectos, CBU-28d). Cadena vacía = sin nota.
    public var statusNote: String {
        get { statusBar.note }
        set {
            statusBar.note = newValue
            statusBar.noteLabel.toolTip = newValue.isEmpty ? nil : newValue
        }
    }

    /// Pestañas de sesión del área central (TerminalUI acopla aquí sus terminales).
    public var sessionTabs: any SessionTabHosting { sessionArea }

    /// Doble clic en una instancia. Sin handler se muestra el aviso de hito
    /// (M1/M2); la App lo conecta a SSH (SshSession + TerminalUI).
    public var onConnectRequest: (@MainActor (InstanceInfo) -> Void)?
    let propertiesPane = PropertiesView()
    let statusBar = StatusBarView()

    private var rootItem: OutlineItem?
    private var isReloading = false
    private(set) var selectedNode: ExplorerNode?

    private enum ToolbarID {
        static let addProject = NSToolbarItem.Identifier("iap.addProject")
        static let refresh = NSToolbarItem.Identifier("iap.refresh")
        static let settings = NSToolbarItem.Identifier("iap.settings")
    }

    private static let sidebarWidth: CGFloat = 280
    private static let propertiesHeight: CGFloat = 260

    /// - Parameter dataSourceLabel: origen de los datos para la status bar ("MOCK").
    public init(viewModel: ExplorerViewModel, dataSourceLabel: String = "MOCK") {
        self.viewModel = viewModel
        self.dataSourceLabel = dataSourceLabel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "IAP Desktop Mac"
        window.minSize = NSSize(width: 820, height: 520)
        super.init(window: window)
        buildToolbar(for: window)
        buildContent(in: window)
        window.center()
        reload()
        viewModel.onChange = { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func buildToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "iap.explorer.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    private func buildContent(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        centerSplit.isVertical = false
        centerSplit.dividerStyle = .thin
        centerSplit.delegate = self

        let sidebar = buildSidebar()
        sidebar.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: 660)
        let center = NSView(frame: NSRect(x: 0, y: 0, width: 1100 - Self.sidebarWidth, height: 660))
        centerSplit.frame = center.bounds
        centerSplit.autoresizingMask = [.width, .height]
        sessionArea.frame = NSRect(x: 0, y: 0, width: center.bounds.width, height: 660 - Self.propertiesHeight)
        propertiesPane.frame = NSRect(x: 0, y: 0, width: center.bounds.width, height: Self.propertiesHeight)
        centerSplit.addArrangedSubview(sessionArea)
        centerSplit.addArrangedSubview(propertiesPane)
        center.addSubview(centerSplit)

        mainSplit.addArrangedSubview(sidebar)
        mainSplit.addArrangedSubview(center)
        // Al redimensionar la ventana crece el área central, no los paneles.
        mainSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        mainSplit.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        centerSplit.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        centerSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)

        for view in [mainSplit, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            mainSplit.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainSplit.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainSplit.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        contentView.layoutSubtreeIfNeeded()
        mainSplit.setPosition(Self.sidebarWidth, ofDividerAt: 0)
        centerSplit.setPosition(centerSplit.bounds.height - Self.propertiesHeight, ofDividerAt: 0)
    }

    private func buildSidebar() -> NSView {
        let panel = NSVisualEffectView()
        panel.material = .sidebar
        panel.blendingMode = .behindWindow
        panel.state = .followsWindowActiveState

        let title = NSTextField(labelWithString: "Project Explorer")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let search = NSSearchField()
        search.placeholderString = "Filtrar instancias"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))

        let linuxToggle = NSButton(checkboxWithTitle: "Linux", target: self, action: #selector(linuxToggled(_:)))
        linuxToggle.state = viewModel.showLinux ? .on : .off
        let windowsToggle = NSButton(
            checkboxWithTitle: "Windows", target: self, action: #selector(windowsToggled(_:)))
        windowsToggle.state = viewModel.showWindows ? .on : .off
        for toggle in [linuxToggle, windowsToggle] {
            toggle.controlSize = .small
            toggle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let toggles = NSStackView(views: [linuxToggle, windowsToggle])
        toggles.spacing = 12

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(outlineDoubleClicked)
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        outline.menu = contextMenu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        for view in [title, search, toggles, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            toggles.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            toggles.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: toggles.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    // MARK: - Acciones (toolbar y menús principales vía responder chain)

    /// Acción real (la implementa quien tenga workspace+viewModel, vía
    /// `onAddProject`); sin callback cae al stub informativo.
    public var onAddProject: (@MainActor () -> Void)?

    @objc public func addProject(_ sender: Any?) {
        if let onAddProject { onAddProject() } else { showStub(title: "Add project", milestone: "M2") }
    }

    @objc public func refreshExplorer(_ sender: Any?) {
        showStub(title: "Refresh", milestone: "M2")
    }

    @objc public func openSettings(_ sender: Any?) {
        showStub(title: "Settings", milestone: "M2")
    }

    /// Muestra u oculta el panel Properties (menú View).
    /// Session > Connect: conecta la instancia seleccionada (si es Linux).
    @objc public func connectSelectedInstance(_ sender: Any?) {
        guard let instance = viewModel.selection else {
            showMessage(title: "Connect", text: "Selecciona una instancia en Project Explorer.")
            return
        }
        guard instance.os == .linux, let onConnectRequest else {
            showStub(title: "Connect to \(instance.name)", milestone: instance.os.connectMilestone)
            return
        }
        onConnectRequest(instance)
    }

    static func isSshTarget(_ node: ExplorerNode) -> Bool {
        if case .instance(let instance) = node { return instance.os == .linux }
        return false
    }

    @objc public func toggleProperties(_ sender: Any?) {
        setPropertiesVisible(propertiesPane.isHidden)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        viewModel.filterText = sender.stringValue
    }

    @objc private func linuxToggled(_ sender: NSButton) {
        viewModel.showLinux = sender.state == .on
    }

    @objc private func windowsToggled(_ sender: NSButton) {
        viewModel.showWindows = sender.state == .on
    }

    @objc private func outlineDoubleClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? OutlineItem else { return }
        if case .instance(let instance) = item.node {
            if let onConnectRequest, instance.os == .linux {
                onConnectRequest(instance)
                return
            }
            showStub(
                title: "Connect to \(instance.name)",
                milestone: instance.os.connectMilestone)
        } else if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandItem(item)
        }
    }

    @objc private func performContextCommand(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextPayload else { return }
        switch payload.command {
        case .connect where Self.isSshTarget(payload.node) && onConnectRequest != nil:
            if case .instance(let instance) = payload.node { onConnectRequest?(instance) }
        case .connect, .connectAsUser, .connectionSettings:
            showStub(title: payload.command.title, milestone: payload.command.milestone ?? "M2")
        case .refreshProject:
            reload()
            statusBar.note = "\(payload.node.projectName ?? payload.node.title) refrescado (\(dataSourceLabel))"
        case .properties:
            _ = selectNode(id: payload.node.id)
            setPropertiesVisible(true)
        }
    }

    private func showStub(title: String, milestone: String) {
        showMessage(title: title, text: "Disponible en \(milestone)")
    }

    private func showMessage(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func setPropertiesVisible(_ visible: Bool) {
        propertiesPane.isHidden = !visible
        centerSplit.adjustSubviews()
        if visible {
            centerSplit.setPosition(centerSplit.bounds.height - Self.propertiesHeight, ofDividerAt: 0)
        }
    }

    // MARK: - Datos

    private func reload() {
        let previousID = selectedNode?.id
        let projects = viewModel.filteredProjects
        let cloud = ExplorerNode.cloud(
            projectCount: projects.count,
            instanceCount: projects.reduce(0) { $0 + $1.zones.reduce(0) { $0 + $1.instances.count } })
        rootItem = OutlineItem(
            node: cloud,
            children: projects.map { project in
                OutlineItem(
                    node: .project(project),
                    children: project.zones.map { zone in
                        OutlineItem(
                            node: .zone(zone),
                            children: zone.instances.map { OutlineItem(node: .instance($0), children: []) })
                    })
            })

        isReloading = true
        outline.reloadData()
        if let rootItem { outline.expandItem(rootItem, expandChildren: true) }
        isReloading = false

        statusBar.summary = viewModel.statusSummary(source: dataSourceLabel)
        if let previousID, selectNode(id: previousID) { return }
        outline.deselectAll(nil)
        select(nil)
    }

    /// Selecciona el nodo con ese id (si está visible). Devuelve si lo encontró.
    @discardableResult
    public func selectNode(id: String) -> Bool {
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? OutlineItem, item.node.id == id else { continue }
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
            select(item.node)
            return true
        }
        return false
    }

    private func select(_ node: ExplorerNode?) {
        selectedNode = node
        if case .instance(let instance) = node {
            viewModel.selection = instance
        } else {
            viewModel.selection = nil
        }
        propertiesPane.show(node)
    }
}

/// Item del outline con identidad de referencia: NSOutlineView compara items
/// por puntero, así que un enum (valor) re-empaquetado rompe expandir/seleccionar.
@MainActor
final class OutlineItem {
    let node: ExplorerNode
    let children: [OutlineItem]

    init(node: ExplorerNode, children: [OutlineItem]) {
        self.node = node
        self.children = children
    }
}

private struct ContextPayload {
    let command: ExplorerCommand
    let node: ExplorerNode
}

// MARK: - NSToolbarDelegate

extension ExplorerWindowController: NSToolbarDelegate {
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.addProject, ToolbarID.refresh, .flexibleSpace, ToolbarID.settings]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let spec: (label: String, symbol: String, action: Selector)
        switch itemIdentifier {
        case ToolbarID.addProject:
            spec = ("Add project", "plus.rectangle.on.folder", #selector(addProject(_:)))
        case ToolbarID.refresh:
            spec = ("Refresh", "arrow.clockwise", #selector(refreshExplorer(_:)))
        case ToolbarID.settings:
            spec = ("Settings", "gearshape", #selector(openSettings(_:)))
        default:
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = spec.label
        item.paletteLabel = spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.isBordered = true
        item.target = self
        item.action = spec.action
        return item
    }
}

// MARK: - NSMenuDelegate (menú contextual)

extension ExplorerWindowController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = outline.item(atRow: outline.clickedRow) as? OutlineItem else { return }
        for menuItem in Self.contextMenuItems(
            for: item.node, target: self, sshConnectAvailable: onConnectRequest != nil) {
            menu.addItem(menuItem)
        }
    }

    static func contextMenuItems(
        for node: ExplorerNode, target: AnyObject?, sshConnectAvailable: Bool = false
    ) -> [NSMenuItem] {
        ExplorerContextMenu.entries(for: node).map { entry in
            switch entry {
            case .separator:
                return .separator()
            case .command(let command):
                let item = NSMenuItem(
                    title: command.title,
                    action: #selector(ExplorerWindowController.performContextCommand(_:)),
                    keyEquivalent: "")
                item.target = target
                item.representedObject = ContextPayload(command: command, node: node)
                item.image = NSImage(systemSymbolName: command.symbolName, accessibilityDescription: nil)
                // Connect por SSH ya existe (CBU-44) si la App lo cablea y la
                // instancia es Linux; RDP (Windows) sigue en M2.
                if command == .connect, sshConnectAvailable, Self.isSshTarget(node) {
                    item.isEnabled = true
                    item.toolTip = "Abrir sesión SSH vía IAP"
                    return item
                }
                item.isEnabled = command.isAvailable
                if let milestone = command.milestone {
                    item.badge = NSMenuItemBadge(string: milestone)
                    item.toolTip = "Disponible en \(milestone)"
                }
                return item
            }
        }
    }
}

// MARK: - NSSplitViewDelegate

extension ExplorerWindowController: NSSplitViewDelegate {
    public func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        splitView === mainSplit ? 220 : 160
    }

    public func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        splitView === mainSplit
            ? min(480, splitView.bounds.width - 420)
            : splitView.bounds.height - 110
    }
}

// MARK: - NSOutlineView

extension ExplorerWindowController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let parent = item as? OutlineItem else { return rootItem == nil ? 0 : 1 }
        return parent.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let parent = item as? OutlineItem else { return rootItem as Any }
        return parent.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? OutlineItem else { return false }
        return !item.children.isEmpty
    }
}

extension ExplorerWindowController: NSOutlineViewDelegate {
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        select((outline.item(atRow: outline.selectedRow) as? OutlineItem)?.node)
    }

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = (item as? OutlineItem)?.node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: id)
        guard let text = cell.textField, let icon = cell.imageView else { return cell }

        text.stringValue = node.title
        icon.image = NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil)
        // Las celdas se reutilizan: resetear siempre tinte, fuente y color.
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textColor = .labelColor
        switch node {
        case .cloud:
            icon.contentTintColor = .systemBlue
            text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        case .project, .zone:
            icon.contentTintColor = .secondaryLabelColor
        case .instance(let instance):
            icon.setAccessibilityLabel("\(instance.os.displayName), \(instance.status.displayName)")
            switch instance.status {
            case .running: icon.contentTintColor = .systemGreen
            case .stopped:
                icon.contentTintColor = .tertiaryLabelColor
                text.textColor = .secondaryLabelColor
            case .unknown: icon.contentTintColor = .systemOrange
            }
            if instance.connected {
                icon.contentTintColor = .controlAccentColor
                text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            }
        }
        cell.toolTip = node.properties.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for view in [icon, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = icon
        cell.textField = text
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
