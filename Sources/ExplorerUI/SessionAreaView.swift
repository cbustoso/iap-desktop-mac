import AppKit

/// Área central donde se acoplan las sesiones (SSH M1, RDP M2) como pestañas.
/// Sin sesiones muestra el empty-state "Double-click a VM to connect".
final class SessionAreaView: NSView {
    private let tabView = NSTabView()
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
        tabView.selectTabViewItem(item)
        updateEmptyState()
    }

    func setSessionTitle(_ title: String, identifier: String) {
        tabView.tabViewItems.first(where: { $0.identifier as? String == identifier })?.label = title
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
        updateEmptyState()
    }

    private func build() {
        tabView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabView)

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
            tabView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabView.topAnchor.constraint(equalTo: topAnchor),
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
        // Sin pestañas no se dibuja el marco del NSTabView (evita una caja vacía).
        tabView.tabViewType = empty ? .noTabsNoBorder : .topTabsBezelBorder
    }
}

extension SessionAreaView: SessionTabHosting {}
