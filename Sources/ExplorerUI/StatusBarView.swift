import AppKit

/// Barra de estado inferior: origen de datos + conteos a la izquierda, nota
/// transitoria en el centro y cuenta a la derecha (como la del IAP Desktop).
final class StatusBarView: NSView {
    static let height: CGFloat = 24

    private let summaryLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let accountLabel = NSTextField(labelWithString: "Sin sesión — cuenta pendiente (M1)")

    var summary: String {
        get { summaryLabel.stringValue }
        set { summaryLabel.stringValue = newValue }
    }

    var note: String {
        get { noteLabel.stringValue }
        set { noteLabel.stringValue = newValue }
    }

    var account: String { accountLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func build() {
        let rule = NSBox()
        rule.boxType = .separator

        for label in [summaryLabel, noteLabel, accountLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        noteLabel.textColor = .tertiaryLabelColor
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let accountIcon = NSImageView()
        accountIcon.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Cuenta")
        accountIcon.contentTintColor = .secondaryLabelColor
        accountIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [summaryLabel, noteLabel, spacer, accountIcon, accountLabel])
        row.spacing = 12
        row.setCustomSpacing(4, after: accountIcon)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        for view in [rule, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: rule.bottomAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }
}
