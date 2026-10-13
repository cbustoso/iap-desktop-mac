import AppKit

/// Área central donde se acoplan las sesiones (SSH M1, RDP M2) como pestañas.
/// Sin sesiones muestra el empty-state "Double-click a VM to connect".
final class SessionAreaView: NSView {
    private let tabView = NSTabView()
    /// Barra de pestañas propia (GH-64): `NSTabView` no tiene `×` por pestaña,
    /// así que sus pestañas nativas se ocultan y aquí se dibuja una por sesión.
    let tabStrip = NSStackView()
    private(set) var tabItems: [String: SessionTabItemView] = [:]
    /// Ver `SessionTabHosting.onCloseRequested`.
    var onCloseRequested: (@MainActor (String) -> Void)? {
        didSet { tabItems.values.forEach { $0.isClosable = onCloseRequested != nil } }
    }
    private let emptyState = NSStackView()
    // Internos (no privados) para que los tests comprueben el truncado.
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")

    var isShowingEmptyState: Bool { !emptyState.isHidden }

    override func layout() {
        // El wrap de un NSTextField necesita un ancho de referencia: el del
        // panel menos los márgenes del empty-state (16 + 16) y el padding de
        // la celda (~2 pt por lado), que `preferredMaxLayoutWidth` no incluye.
        let available = max(bounds.width - 32 - 4, 80)
        if subtitle.preferredMaxLayoutWidth != available {
            subtitle.preferredMaxLayoutWidth = available
        }
        super.layout()
        layoutTabItems()
    }
    var sessionCount: Int { tabView.numberOfTabViewItems }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        updateEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Acopla una sesión como pestaña y la activa. Punto de entrada para M1/M2.
    func openSession(identifier: String, title: String, content: NSView) {
        if let existing = tabView.tabViewItems.first(where: { $0.identifier as? String == identifier }) {
            tabView.selectTabViewItem(existing)
            return
        }
        let item = NSTabViewItem(identifier: identifier)
        item.label = title
        item.view = content
        tabView.addTabViewItem(item)
        let tab = SessionTabItemView(identifier: identifier, title: title)
        tab.isClosable = onCloseRequested != nil
        tab.onSelect = { [weak self] in self?.selectSession(identifier: $0) }
        tab.onClose = { [weak self] in self?.onCloseRequested?($0) }
        tabItems[identifier] = tab
        tabStrip.addArrangedSubview(tab)
        selectSession(identifier: identifier)
        updateEmptyState()
    }

    func setSessionTitle(_ title: String, identifier: String) {
        tabView.tabViewItems.first(where: { $0.identifier as? String == identifier })?.label = title
        tabItems[identifier]?.title = title
    }

    /// Activa la pestaña `identifier` (clic en la barra).
    func selectSession(identifier: String) {
        guard let item = tabView.tabViewItems.first(where: { $0.identifier as? String == identifier }) else { return }
        tabView.selectTabViewItem(item)
        for (id, tab) in tabItems { tab.isSelected = id == identifier }
    }

    var sessionIdentifiers: [String] {
        tabView.tabViewItems.compactMap { $0.identifier as? String }
    }

    func tabLabel(for identifier: String) -> String? {
        tabView.tabViewItems.first(where: { $0.identifier as? String == identifier })?.label
    }

    var selectedSessionIdentifier: String? {
        tabView.selectedTabViewItem?.identifier as? String
    }

    func closeSession(identifier: String) {
        guard let item = tabView.tabViewItems.first(where: { $0.identifier as? String == identifier })
        else { return }
        tabView.removeTabViewItem(item)
        tabItems.removeValue(forKey: identifier)?.removeFromSuperview()
        if let selected = selectedSessionIdentifier {
            for (id, tab) in tabItems { tab.isSelected = id == selected }
        }
        updateEmptyState()
    }

    /// Ancho por pestaña: hasta 200 pt, repartiendo si no caben.
    private func layoutTabItems() {
        guard !tabItems.isEmpty else { return }
        let width = max(80, min(200, (bounds.width - 8) / CGFloat(tabItems.count)))
        for tab in tabItems.values where tab.preferredWidth != width { tab.preferredWidth = width }
    }

    private func build() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .noTabsNoBorder
        addSubview(tabView)
        tabStrip.orientation = .horizontal
        tabStrip.spacing = 1
        tabStrip.alignment = .centerY
        tabStrip.setHuggingPriority(.defaultLow, for: .horizontal)
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabStrip)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Sesiones")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        title.stringValue = "Double-click a VM to connect"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor
        // Por encima del hugging del stack (250) para no truncar con sitio de
        // sobra; por debajo de los márgenes (required) para truncar con "…".
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh - 10, for: .horizontal)

        subtitle.stringValue = "Las sesiones SSH (M1) y RDP (M2) se abrirán aquí como pestañas."
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .tertiaryLabelColor
        // `labelWithString` recorta sin "…" y no hace wrap: con el panel central
        // estrecho el subtítulo se cortaba a media palabra. Ahora envuelve.
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 0

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 10
        [icon, title, subtitle].forEach(emptyState.addArrangedSubview)
        emptyState.setCustomSpacing(16, after: icon)  // solo tras añadir (si no, NSStackView lanza)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)

        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            tabStrip.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            tabStrip.heightAnchor.constraint(equalToConstant: SessionTabItemView.height),
            tabView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: 2),
            tabView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    private func updateEmptyState() {
        let empty = tabView.numberOfTabViewItems == 0
        emptyState.isHidden = !empty
        tabStrip.isHidden = empty
        needsLayout = true
    }
}

extension SessionAreaView: SessionTabHosting {}

// MARK: - Pestaña de la barra (GH-64)

/// Título + `×` visible solo con el ratón encima (patrón Safari/Terminal).
final class SessionTabItemView: NSView {
    static let height: CGFloat = 24

    let sessionID: String
    let titleLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    var onSelect: (@MainActor (String) -> Void)?
    var onClose: (@MainActor (String) -> Void)?
    private var widthConstraint: NSLayoutConstraint?
    private var tracking: NSTrackingArea?

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            toolTip = newValue
            closeButton.setAccessibilityLabel("Cerrar \(newValue)")
        }
    }

    var isSelected = false { didSet { needsDisplay = true; titleLabel.textColor = isSelected ? .labelColor : .secondaryLabelColor } }
    var isHovering = false { didSet { updateCloseButton() } }
    var isClosable = true { didSet { updateCloseButton() } }

    var preferredWidth: CGFloat {
        get { widthConstraint?.constant ?? 0 }
        set { widthConstraint?.constant = newValue }
    }

    init(identifier: String, title: String) {
        sessionID = identifier
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 5
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar pestaña")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = "Cerrar pestaña (⌘W)"
        for view in [closeButton, titleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let width = widthAnchor.constraint(equalToConstant: 200)
        width.priority = .defaultHigh
        widthConstraint = width
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: Self.height),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.title = title
        isSelected = false
        updateCloseButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func updateCloseButton() {
        // Oculto pero conserva su hueco: el título no salta al pasar el ratón.
        closeButton.isHidden = !(isClosable && isHovering)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseDown(with event: NSEvent) {
        onSelect?(sessionID)
    }

    /// Clic central: cierra (convención de pestañas de navegador, opcional en la spec).
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, isClosable { onClose?(sessionID) } else { super.otherMouseDown(with: event) }
    }

    @objc func closeClicked(_ sender: Any?) {
        guard isClosable else { return }
        onClose?(sessionID)
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18)
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)).setFill()
        bounds.fill()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { title }
}
