import AppKit

/// Ventana principal: sidebar con outline Cloud → Proyecto → Zona → Instancia
/// + panel de detalle. Todo programático (sin nibs, sin SwiftUI).
public final class ExplorerWindowController: NSWindowController {
    private let viewModel: ExplorerViewModel
    private let outline = NSOutlineView()
    private let detailStack = NSStackView()
    private var roots: [Node] = []

    enum Node: Hashable {
        case project(ProjectInfo)
        case zone(ZoneInfo)
        case instance(InstanceInfo)
    }

    public init(viewModel: ExplorerViewModel) {
        self.viewModel = viewModel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "IAP Desktop Mac"
        super.init(window: window)
        window.center()
        buildContent()
        reload()
        viewModel.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let search = NSSearchField()
        search.placeholderString = "Filtrar instancias"
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(search)

        let linuxToggle = NSButton(checkboxWithTitle: "Linux", target: self, action: #selector(linuxToggled(_:)))
        linuxToggle.state = .on
        header.addArrangedSubview(linuxToggle)
        let windowsToggle = NSButton(
            checkboxWithTitle: "Windows", target: self, action: #selector(windowsToggled(_:)))
        windowsToggle.state = .on
        header.addArrangedSubview(windowsToggle)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(outlineClicked)
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = outline
        sidebarScroll.hasVerticalScroller = true

        let sidebarVC = NSViewController()
        sidebarVC.view = sidebarScroll

        detailStack.orientation = .vertical
        detailStack.spacing = 6
        detailStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailStack
        detailScroll.hasVerticalScroller = true
        let detailVC = NSViewController()
        detailVC.view = detailScroll

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 260
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 400
        split.addSplitViewItem(detailItem)

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.addArrangedSubview(header)
        root.addArrangedSubview(split.view)
        contentView.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Acciones

    @objc private func searchChanged(_ sender: NSSearchField) {
        viewModel.filterText = sender.stringValue
    }

    @objc private func linuxToggled(_ sender: NSButton) {
        viewModel.showLinux = sender.state == .on
    }

    @objc private func windowsToggled(_ sender: NSButton) {
        viewModel.showWindows = sender.state == .on
    }

    @objc private func outlineClicked() {
        let row = outline.clickedRow
        guard row >= 0,
            case .instance(let info) = node(atRow: row)
        else {
            if outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) {
                outline.isItemExpanded(item) ? outline.collapseItem(item) : outline.expandItem(item)
            }
            return
        }
        viewModel.selection = info
        updateDetail()
    }

    // MARK: - Datos

    private func reload() {
        roots = viewModel.filteredProjects.map(Node.project)
        outline.reloadData()
        // Expande proyectos y zonas (profundidad 2).
        var row = 0
        while row < outline.numberOfRows {
            if let item = outline.item(atRow: row), outline.isExpandable(item) {
                outline.expandItem(item)
            }
            row += 1
            if row > 10_000 { break }
        }
        updateDetail()
    }

    private func node(atRow row: Int) -> Node? {
        outline.item(atRow: row) as? Node
    }

    private func children(of node: Node?) -> [Node] {
        switch node {
        case nil: return roots
        case .project(let p): return p.zones.map(Node.zone)
        case .zone(let z): return z.instances.map(Node.instance)
        case .instance: return []
        }
    }

    // MARK: - Detalle

    private func updateDetail() {
        detailStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let instance = viewModel.selection else {
            detailStack.addArrangedSubview(label("Selecciona una instancia", size: 15, bold: true))
            detailStack.addArrangedSubview(
                label("Explora proyectos, zonas e instancias en la barra lateral.", size: 12, secondary: true))
            return
        }
        detailStack.addArrangedSubview(label(instance.name, size: 20, bold: true))
        detailStack.addArrangedSubview(label("Proyecto: \(instance.project)", size: 13))
        detailStack.addArrangedSubview(label("Zona: \(instance.zone)", size: 13))
        detailStack.addArrangedSubview(label("SO: \(instance.os.rawValue)", size: 13))
        detailStack.addArrangedSubview(label("Estado: \(instance.status.rawValue)", size: 13))
        detailStack.addArrangedSubview(label("Conectar", size: 14, bold: true))
        for title in ["SSH (M1)", "RDP (M2)", "SFTP (M3)"] {
            let button = NSButton(title: title, target: nil, action: nil)
            button.isEnabled = false
            detailStack.addArrangedSubview(button)
        }
        detailStack.addArrangedSubview(NSView())  // relleno
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }
}

// MARK: - NSOutlineView

extension ExplorerWindowController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? Node).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? Node)[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        if case .instance = node { return false }
        return true
    }
}

extension ExplorerWindowController: NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? {
                let fresh = NSTableCellView()
                fresh.identifier = id
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                fresh.addSubview(text)
                fresh.textField = text
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                fresh.addSubview(icon)
                fresh.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: fresh.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: fresh.trailingAnchor),
                    text.centerYAnchor.constraint(equalTo: fresh.centerYAnchor),
                ])
                return fresh
            }()
        switch node {
        case .project(let p):
            cell.textField?.stringValue = p.name
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            cell.toolTip = p.name
        case .zone(let z):
            cell.textField?.stringValue = z.name
            cell.imageView?.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            cell.toolTip = z.name
        case .instance(let i):
            cell.textField?.stringValue = i.name
            if i.connected {
                let img = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: nil)
                cell.imageView?.image = img
            } else {
                let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                cell.imageView?.image = img
                switch i.status {
                case .running: cell.imageView?.contentTintColor = .systemGreen
                case .stopped: cell.imageView?.contentTintColor = .systemGray
                case .unknown: cell.imageView?.contentTintColor = .systemOrange
                }
            }
            cell.toolTip = "\(i.name) · \(i.zone) · \(i.os.rawValue) · \(i.status.rawValue)"
        }
        return cell
    }
}
