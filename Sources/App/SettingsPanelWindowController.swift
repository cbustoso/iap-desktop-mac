import AppKit
import ExplorerUI
import Foundation

/// Ventana de Settings con herencia por ámbito (CBU-53). Todo programático:
/// selector de ámbito + filas por descriptor (texto/secreto/entero/toggle)
/// con valor heredado visible y checkbox de override. Solo persiste lo dirty
/// (vía el dataSource); los secretos solo van a Keychain, nunca a logs.
@MainActor
final class SettingsPanelWindowController: NSWindowController {
    private let dataSource: ApplicationSettingsDataSource
    private var snapshot: SettingsPanelSnapshot?
    private let scopePopup = NSPopUpButton()
    private let rowsStack = NSStackView()
    private var rowControls: [String: RowControl] = [:]

    private struct RowControl {
        var setValue: (SettingsFieldValue) -> Void
        var readValue: () -> SettingsFieldValue?
        var setOverridden: (Bool) -> Void
        var isOverridden: () -> Bool
    }

    init(dataSource: ApplicationSettingsDataSource) {
        self.dataSource = dataSource
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        loadScopes(selecting: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Muestra el panel con el ámbito preseleccionado si se conoce.
    func show(preferredScope: SettingsPanelScope?) {
        loadScopes(selecting: preferredScope)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))

        let scroll = NSScrollView()
        scroll.documentView = rowsStack
        scroll.hasVerticalScroller = true
        rowsStack.orientation = .vertical
        rowsStack.spacing = 10
        rowsStack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let revertButton = NSButton(title: "Revert", target: self, action: #selector(revert(_:)))
        revertButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), revertButton, saveButton])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [scopePopup, scroll, buttons])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Datos

    private func loadScopes(selecting preferred: SettingsPanelScope?) {
        let scopes = dataSource.availableScopes()
        scopePopup.removeAllItems()
        for scope in scopes {
            scopePopup.addItem(withTitle: Self.title(for: scope))
            scopePopup.lastItem?.representedObject = scope
        }
        let index = preferred.flatMap { scopes.firstIndex(of: $0) } ?? 0
        scopePopup.selectItem(at: scopes.isEmpty ? -1 : index)
        loadCurrentScope()
    }

    private static func title(for scope: SettingsPanelScope) -> String {
        switch scope {
        case .universe: return "All projects (defaults)"
        case .project(let p): return "Project \(p)"
        case .zone(let p, let z): return "Zone \(z) (\(p))"
        case .instance(let p, let z, let i): return "\(i) (\(z))"
        }
    }

    @objc private func scopeChanged(_ sender: Any?) { loadCurrentScope() }

    private func currentScope() -> SettingsPanelScope? {
        scopePopup.selectedItem?.representedObject as? SettingsPanelScope
    }

    private func loadCurrentScope() {
        guard let scope = currentScope() else { return }
        do {
            let snapshot = try dataSource.loadSettings(at: scope)
            self.snapshot = snapshot
            rebuildRows(snapshot)
        } catch {
            showError("Could not load settings for this scope.")
        }
    }

    // MARK: - Filas

    private func rebuildRows(_ snapshot: SettingsPanelSnapshot) {
        rowControls.removeAll()
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for field in snapshot.fields {
            rowsStack.addArrangedSubview(rowView(for: field))
        }
    }

    private func rowView(for field: SettingsPanelField) -> NSView {
        let title = NSTextField(labelWithString: field.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.toolTip = field.help.isEmpty ? nil : field.help

        let inherited = NSTextField(labelWithString: "Inherited: \(displayValue(field.inheritedValue, kind: field.kind))")
        inherited.font = .systemFont(ofSize: 11)
        inherited.textColor = .secondaryLabelColor

        let override = NSButton(checkboxWithTitle: "Override", target: nil, action: nil)
        override.state = field.isOverridden ? .on : .off

        let control: NSView
        switch field.kind {
        case .text:
            let text = NSTextField()
            if case .text(let v) = field.value { text.stringValue = v }
            text.isEnabled = field.isOverridden
            control = text
            rowControls[field.key] = RowControl(
                setValue: { if case .text(let v) = $0 { text.stringValue = v } },
                readValue: { .text(text.stringValue) },
                setOverridden: { text.isEnabled = $0 },
                isOverridden: { text.isEnabled })
        case .secret:
            let text = NSSecureTextField()
            if case .text(let v) = field.value { text.stringValue = v }
            text.isEnabled = field.isOverridden
            control = text
            rowControls[field.key] = RowControl(
                setValue: { if case .text(let v) = $0 { text.stringValue = v } },
                readValue: { .text(text.stringValue) },
                setOverridden: { text.isEnabled = $0 },
                isOverridden: { text.isEnabled })
        case .integer(let range):
            let text = NSTextField()
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            formatter.minimum = NSNumber(value: range.lowerBound)
            formatter.maximum = NSNumber(value: range.upperBound)
            text.formatter = formatter
            if case .integer(let v) = field.value { text.integerValue = v }
            text.isEnabled = field.isOverridden
            control = text
            rowControls[field.key] = RowControl(
                setValue: { if case .integer(let v) = $0 { text.integerValue = v } },
                readValue: { .integer(text.integerValue) },
                setOverridden: { text.isEnabled = $0 },
                isOverridden: { text.isEnabled })
        case .toggle:
            let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            if case .toggle(let v) = field.value { box.state = v ? .on : .off }
            box.isEnabled = field.isOverridden
            control = box
            rowControls[field.key] = RowControl(
                setValue: { if case .toggle(let v) = $0 { box.state = v ? .on : .off } },
                readValue: { .toggle(box.state == .on) },
                setOverridden: { box.isEnabled = $0 },
                isOverridden: { box.isEnabled })
        }
        override.target = self
        override.action = #selector(overrideToggled(_:))
        override.identifier = NSUserInterfaceItemIdentifier(field.key)

        let top = NSStackView(views: [title, control, override])
        top.orientation = .horizontal
        top.spacing = 8
        title.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let row = NSStackView(views: [top, inherited])
        row.orientation = .vertical
        row.spacing = 2
        return row
    }

    private func displayValue(_ value: SettingsFieldValue, kind: SettingsFieldKind) -> String {
        // Los secretos heredados nunca se muestran (ni siquiera existen en
        // memoria como texto salvo al editarlos).
        if kind == .secret { return "(stored in Keychain)" }
        switch value {
        case .text(let v): return v.isEmpty ? "(empty)" : v
        case .integer(let v): return String(v)
        case .toggle(let v): return v ? "On" : "Off"
        }
    }

    @objc private func overrideToggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let row = rowControls[key] else { return }
        row.setOverridden(sender.state == .on)
    }

    // MARK: - Guardado

    @objc private func revert(_ sender: Any?) { loadCurrentScope() }

    @objc private func save(_ sender: Any?) {
        guard var snapshot else { return }
        snapshot.fields = snapshot.fields.map { field in
            var updated = field
            if let row = rowControls[field.key] {
                updated.isOverridden = row.isOverridden()
                if let value = row.readValue() { updated.value = value }
            }
            return updated
        }
        do {
            try dataSource.saveSettings(snapshot)
            loadCurrentScope()
        } catch {
            showError("Could not save settings.")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }
}
