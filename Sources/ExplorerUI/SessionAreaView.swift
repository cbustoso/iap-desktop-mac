import AppKit

/// Área central donde se acoplan las sesiones (SSH M1, RDP M2) como pestañas.
/// Sin sesiones muestra el empty-state "Double-click a VM to connect".
final class SessionAreaView: NSView {
    private let tabView = NSTabView()
    private let emptyState = NSStackView()

    var isShowingEmptyState: Bool { !emptyState.isHidden }
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

        let title = NSTextField(labelWithString: "Double-click a VM to connect")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let subtitle = NSTextField(
            labelWithString: "Las sesiones SSH (M1) y RDP (M2) se abrirán aquí como pestañas.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .tertiaryLabelColor

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
        ])
    }

    private func updateEmptyState() {
        let empty = tabView.numberOfTabViewItems == 0
        emptyState.isHidden = !empty
        // Sin pestañas no se dibuja el marco del NSTabView (evita una caja vacía).
        tabView.tabViewType = empty ? .noTabsNoBorder : .topTabsBezelBorder
    }
}
