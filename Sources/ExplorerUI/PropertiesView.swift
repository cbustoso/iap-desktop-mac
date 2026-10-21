import AppKit

/// Panel "Properties" bajo el área de sesiones (como el panel inferior del
/// IAP Desktop). Grid clave/valor del nodo seleccionado.
final class PropertiesView: NSView {
    private let header = NSTextField(labelWithString: "Properties")
    private let content = FlippedView()
    private(set) var rows: [PropertyRow] = []
    private(set) var bastionSelector: NSPopUpButton?
    var onBastionSelection: (@MainActor (String?, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ node: ExplorerNode?) {
        content.subviews.forEach { $0.removeFromSuperview() }
        bastionSelector = nil
        guard let node else {
            rows = []
            let hint = NSTextField(labelWithString: "Selecciona un elemento en Project Explorer.")
            hint.textColor = .secondaryLabelColor
            place(hint)
            return
        }
        rows = node.properties

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: node.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let titleRow = NSStackView(views: [icon, title])
        titleRow.spacing = 8

        let grid = NSGridView(views: rows.map { row -> [NSView] in
            let key = NSTextField(labelWithString: row.label)
            key.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: row.value)
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [key, value]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 130

        var views: [NSView] = [titleRow]
        if case .azureVirtualMachine(let vmNode) = node {
            views.append(makeBastionSelector(for: vmNode))
        }
        views.append(grid)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        place(stack)
    }

    private func makeBastionSelector(for node: AzureExplorerVMNode) -> NSView {
        let label = NSTextField(labelWithString: "Bastion:")
        label.textColor = .secondaryLabelColor
        let popup = NSPopUpButton()
        bastionSelector = popup
        if node.bastions.isEmpty {
            popup.addItem(withTitle: "No hay Bastion disponible")
            popup.isEnabled = false
        } else {
            popup.addItem(withTitle: "Sin asignar — selecciona un Bastion")
            popup.lastItem?.representedObject = NSNull()
            for bastion in node.bastions {
                let suffix = bastion.supportsNativeClient ? "" : " — no apto"
                popup.addItem(withTitle: "\(bastion.name) (\(bastion.sku))\(suffix)")
                popup.lastItem?.representedObject = bastion.id
            }
            if let selectedID = node.selectedBastionID,
               let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedID }) {
                popup.selectItem(at: index)
            }
            popup.target = self
            popup.action = #selector(bastionChanged(_:))
        }
        popup.identifier = NSUserInterfaceItemIdentifier(node.virtualMachine.id)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, popup])
        row.spacing = 16
        return row
    }

    @objc private func bastionChanged(_ sender: NSPopUpButton) {
        guard let virtualMachineID = sender.identifier?.rawValue else { return }
        onBastionSelection?(sender.selectedItem?.representedObject as? String, virtualMachineID)
    }

    private func place(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            view.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            view.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
        ])
    }

    private func build() {
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let topRule = NSBox()
        topRule.boxType = .separator
        topRule.translatesAutoresizingMaskIntoConstraints = false

        // El contenido va en un documentView con tamaño explícito: sin esto el
        // stack queda con frame cero y el detalle se ve vacío (bug de la captura).
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        [topRule, header, scroll].forEach(addSubview)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            topRule.topAnchor.constraint(equalTo: topAnchor),
            topRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.widthAnchor.constraint(equalTo: clip.widthAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
        ])
    }
}

/// Origen arriba-izquierda para que el contenido del scroll arranque arriba.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
