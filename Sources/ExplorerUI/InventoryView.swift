import AppKit
import GCPClient

/// Semántica del filtro separada de AppKit para cubrirla con tests unitarios.
public enum InventoryFilter {
    public static func apply(
        _ packages: [InventoryPackage], text: String
    ) -> [InventoryPackage] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return packages }
        return packages.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.version?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.manager.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Tabla de paquetes instalada: nombre, versión y gestor que la reportó.
@MainActor
public final class InventoryView: NSView {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let version = NSUserInterfaceItemIdentifier("version")
        static let origin = NSUserInterfaceItemIdentifier("origin")
    }

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    public let statusLabel = NSTextField(labelWithString: "")
    private var packages: [InventoryPackage] = []
    private var visiblePackages: [InventoryPackage] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func show(packages: [InventoryPackage]) {
        self.packages = packages.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.manager < $1.manager : comparison == .orderedAscending
        }
        applyFilter()
    }

    private func buildContent() {
        searchField.placeholderString = "Filtrar por nombre, versión u origen"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        addColumn(Column.name, title: "Nombre", width: 330)
        addColumn(Column.version, title: "Versión", width: 260)
        addColumn(Column.origin, title: "Origen", width: 140)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for view in [searchField, statusLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = 80
        tableView.addTableColumn(column)
    }

    @objc private func filterChanged(_ sender: NSSearchField) { applyFilter() }

    private func applyFilter() {
        visiblePackages = InventoryFilter.apply(packages, text: searchField.stringValue)
        tableView.reloadData()
    }
}

extension InventoryView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { visiblePackages.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let package = visiblePackages[row]
        let value: String
        switch tableColumn.identifier {
        case Column.name: value = package.name
        case Column.version: value = package.version ?? ""
        case Column.origin: value = package.manager
        default: value = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("InventoryCell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = value
        field.toolTip = value
        return field
    }
}

public enum InventoryScope: Hashable, Sendable {
    case instance(InstanceInfo)
    case zone(ZoneInfo)

    public var id: String {
        switch self {
        case .instance(let instance): return "instance:\(instance.id)"
        case .zone(let zone): return "zone:\(zone.id)"
        }
    }
}

/// Carga una VM directamente (incluido Windows) o agrega las VMs Linux de una zona.
@MainActor
public final class InventoryWindowController: NSWindowController, NSWindowDelegate {
    private let scope: InventoryScope
    private let client: GCPClient
    private let inventoryView = InventoryView(frame: .zero)
    private var loadTask: Task<Void, Never>?

    public init(scope: InventoryScope, client: GCPClient) {
        self.scope = scope
        self.client = client
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        switch scope {
        case .instance(let instance): window.title = "Software packages — \(instance.name)"
        case .zone(let zone): window.title = "Software packages — \(zone.name)"
        }
        window.setFrameAutosaveName("InventoryWindow")
        super.init(window: window)
        window.delegate = self
        inventoryView.frame = window.contentView?.bounds ?? .zero
        inventoryView.autoresizingMask = [.width, .height]
        window.contentView = inventoryView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApplication.shared.activate()
        load()
    }

    public func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
    }

    private func load() {
        guard loadTask == nil else { return }
        inventoryView.statusLabel.stringValue = "Loading guest inventory…"
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { loadTask = nil }
            do {
                switch scope {
                case .instance(let instance):
                    let packages = try await client.packageInventory(
                        project: instance.project, zone: instance.zone, instance: instance.name)
                    guard !Task.isCancelled else { return }
                    inventoryView.show(packages: packages ?? [])
                    inventoryView.statusLabel.stringValue = packages.map {
                        "\($0.count) packages"
                    } ?? "Inventory unavailable — enable guest attributes and the guest agent"
                case .zone(let zone):
                    let inventories = try await client.collectZonePackageInventory(
                        project: zone.project, zone: zone.name)
                    guard !Task.isCancelled else { return }
                    let packages = inventories.compactMap(\.packages).flatMap { $0 }
                    inventoryView.show(packages: packages)
                    let available = inventories.filter { $0.packages != nil }.count
                    inventoryView.statusLabel.stringValue =
                        "\(packages.count) packages from \(available) of \(inventories.count) Windows instances"
                }
            } catch is CancellationError {
                return
            } catch {
                inventoryView.show(packages: [])
                inventoryView.statusLabel.stringValue = "Could not load guest inventory"
            }
        }
    }
}
