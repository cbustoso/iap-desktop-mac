import AppKit
import GCPClient

/// Filtro local del panel, separado de AppKit para poder probar su semántica.
public enum EventLogFilter {
    public static func apply(
        _ events: [InstanceAuditEvent], severity: String?, text: String
    ) -> [InstanceAuditEvent] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            let matchesSeverity = severity == nil || event.severity == severity
            let matchesText = query.isEmpty
                || event.description.localizedCaseInsensitiveContains(query)
                || event.user.localizedCaseInsensitiveContains(query)
            return matchesSeverity && matchesText
        }
    }
}

/// Visor AppKit de Cloud Audit Logs para una instancia.
@MainActor
public final class EventLogWindowController: NSWindowController, NSWindowDelegate {
    private enum Column {
        static let timestamp = NSUserInterfaceItemIdentifier("timestamp")
        static let severity = NSUserInterfaceItemIdentifier("severity")
        static let description = NSUserInterfaceItemIdentifier("description")
        static let user = NSUserInterfaceItemIdentifier("user")
    }

    private let instance: InstanceInfo
    private let client: GCPClient
    private let refreshInterval: Duration
    private let since: Date
    private let tableView = NSTableView()
    private let severitySelector = NSPopUpButton()
    private let searchField = NSSearchField()
    private let autoRefresh = NSButton(checkboxWithTitle: "Auto-refresh", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var events: [InstanceAuditEvent] = []
    private var visibleEvents: [InstanceAuditEvent] = []
    private var pollingTask: Task<Void, Never>?

    public init(
        instance: InstanceInfo, client: GCPClient,
        since: Date = Date().addingTimeInterval(-86_400),
        refreshInterval: Duration = .seconds(10)
    ) {
        self.instance = instance
        self.client = client
        self.since = since
        self.refreshInterval = refreshInterval
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Event log — \(instance.name)"
        window.setFrameAutosaveName("EventLogWindow")
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApplication.shared.activate()
        startPolling()
    }

    public func windowWillClose(_ notification: Notification) {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let severityLabel = NSTextField(labelWithString: "Severity:")
        severitySelector.addItems(withTitles: [
            "All", "DEFAULT", "DEBUG", "INFO", "NOTICE", "WARNING", "ERROR",
            "CRITICAL", "ALERT", "EMERGENCY",
        ])
        severitySelector.target = self
        severitySelector.action = #selector(filterChanged(_:))
        searchField.placeholderString = "Filter description or user"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        autoRefresh.state = .on
        autoRefresh.target = self
        autoRefresh.action = #selector(autoRefreshChanged(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        addColumn(Column.timestamp, title: "Timestamp", width: 190)
        addColumn(Column.severity, title: "Severity", width: 90)
        addColumn(Column.description, title: "Description", width: 390)
        addColumn(Column.user, title: "User", width: 220)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        for view in [severityLabel, severitySelector, searchField, autoRefresh, statusLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            severityLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            severityLabel.centerYAnchor.constraint(equalTo: severitySelector.centerYAnchor),
            severitySelector.leadingAnchor.constraint(equalTo: severityLabel.trailingAnchor, constant: 6),
            severitySelector.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: severitySelector.trailingAnchor, constant: 12),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            searchField.centerYAnchor.constraint(equalTo: severitySelector.centerYAnchor),
            autoRefresh.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 12),
            autoRefresh.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            autoRefresh.centerYAnchor.constraint(equalTo: severitySelector.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: severitySelector.bottomAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = 70
        tableView.addTableColumn(column)
    }

    @objc private func filterChanged(_ sender: Any?) { applyFilter() }

    @objc private func autoRefreshChanged(_ sender: NSButton) {
        if sender.state == .on { startPolling() } else {
            pollingTask?.cancel()
            pollingTask = nil
            statusLabel.stringValue = "Auto-refresh stopped — \(visibleEvents.count) events"
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        autoRefresh.state = .on
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pollingTask = nil }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: refreshInterval) } catch { return }
            }
        }
    }

    private func refresh() async {
        statusLabel.stringValue = "Refreshing…"
        do {
            events = try await client.listInstanceEvents(
                project: instance.project, zone: instance.zone,
                instance: instance.name, since: since)
            applyFilter()
            statusLabel.stringValue = "\(visibleEvents.count) events — auto-refresh every 10 seconds"
        } catch is CancellationError {
            return
        } catch {
            statusLabel.stringValue = "Could not refresh event log"
        }
    }

    private func applyFilter() {
        let severity = severitySelector.indexOfSelectedItem == 0
            ? nil : severitySelector.titleOfSelectedItem
        visibleEvents = EventLogFilter.apply(events, severity: severity, text: searchField.stringValue)
        tableView.reloadData()
    }
}

extension EventLogWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { visibleEvents.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let event = visibleEvents[row]
        let text: String
        switch tableColumn.identifier {
        case Column.timestamp:
            text = event.timestamp.formatted(
                .iso8601.year().month().day().dateSeparator(.dash)
                    .time(includingFractionalSeconds: false).timeZone(separator: .colon))
        case Column.severity: text = event.severity
        case Column.description: text = event.description
        case Column.user: text = event.user
        default: text = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("EventLogCell")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = text
        field.toolTip = text
        return field
    }
}
