// GH-65: panel de resultados del test de conectividad IAP. Una fila por paso
// (IAM / firewall / WebSocket) con estado, motivo y acción correctiva
// (documentación, comando gcloud copiable). Sin lógica de red: la App inyecta
// `run` (DiagnosticsRunner).
import AppKit
import GCPClient

/// Fila ya formateada (testeable sin AppKit).
public struct DiagnosticsRowModel: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case running, passed, failed, skipped, notApplicable }

    public let title: String
    public let status: Status
    public let detail: String
    public let help: DiagnosticHelp?

    public static func rows(for report: DiagnosticsReport) -> [DiagnosticsRowModel] {
        report.steps.map { step in
            switch step.result {
            case .passed(let info):
                return DiagnosticsRowModel(title: step.kind.title, status: .passed, detail: info ?? "Correcto.", help: nil)
            case .failed(let reason, let help):
                return DiagnosticsRowModel(title: step.kind.title, status: .failed, detail: reason.message, help: help)
            case .skipped(let because):
                return DiagnosticsRowModel(title: step.kind.title, status: .skipped, detail: because, help: nil)
            case .notApplicable:
                return DiagnosticsRowModel(title: step.kind.title, status: .notApplicable, detail: "No aplica.", help: nil)
            }
        }
    }

    public static func summary(for report: DiagnosticsReport) -> String {
        if report.isFullyPassed { return "Conectividad IAP correcta." }
        let failed = report.steps.filter { if case .failed = $0.result { true } else { false } }.count
        return failed == 0 ? "Diagnóstico incompleto." : "\(failed) problema(s) encontrado(s)."
    }

    var symbolName: String {
        switch status {
        case .running: return "hourglass"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "minus.circle"
        case .notApplicable: return "circle.dashed"
        }
    }

    var tint: NSColor {
        switch status {
        case .running, .skipped, .notApplicable: return .secondaryLabelColor
        case .passed: return .systemGreen
        case .failed: return .systemRed
        }
    }
}

@MainActor
public final class DiagnosticsPanelView: NSView {
    let summaryLabel = NSTextField(labelWithString: "")
    let rowsStack = NSStackView()
    let rerunButton = NSButton(title: "Volver a ejecutar", target: nil, action: nil)
    private(set) var rows: [DiagnosticsRowModel] = []
    /// Botones de acción de la última pintura (para tests).
    private(set) var helpButtons: [NSButton] = []
    private(set) var copyButtons: [NSButton] = []

    public var onRerun: (@MainActor () -> Void)?
    /// Inyectables en tests.
    public var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var copyText: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 12
        rerunButton.target = self
        rerunButton.action = #selector(rerunClicked(_:))
        let stack = NSStackView(views: [summaryLabel, rowsStack, rerunButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        showRunning()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func showRunning() {
        summaryLabel.stringValue = "Ejecutando diagnóstico…"
        rerunButton.isEnabled = false
        render(DiagnosticStepKind.allCases.map {
            DiagnosticsRowModel(title: $0.title, status: .running, detail: "Pendiente…", help: nil)
        })
    }

    public func show(_ report: DiagnosticsReport) {
        summaryLabel.stringValue = DiagnosticsRowModel.summary(for: report)
        rerunButton.isEnabled = true
        render(DiagnosticsRowModel.rows(for: report))
    }

    private func render(_ models: [DiagnosticsRowModel]) {
        rows = models
        helpButtons = []
        copyButtons = []
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for model in models {
            let icon = NSImageView(image: NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = model.tint
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let title = NSTextField(labelWithString: model.title)
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let detail = NSTextField(wrappingLabelWithString: model.detail)
            detail.textColor = .secondaryLabelColor
            detail.isSelectable = true
            var texts: [NSView] = [title, detail]
            if let help = model.help {
                let open = NSButton(title: help.title, target: self, action: #selector(helpClicked(_:)))
                open.bezelStyle = .inline
                open.tag = helpButtons.count
                helpButtons.append(open)
                var actions: [NSView] = [open]
                if help.command != nil {
                    let copy = NSButton(title: "Copiar comando gcloud", target: self, action: #selector(copyClicked(_:)))
                    copy.bezelStyle = .inline
                    copy.tag = helpButtons.count - 1
                    copyButtons.append(copy)
                    actions.append(copy)
                }
                let row = NSStackView(views: actions)
                row.spacing = 8
                texts.append(row)
            }
            let column = NSStackView(views: texts)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 3
            let row = NSStackView(views: [icon, column])
            row.alignment = .top
            row.spacing = 8
            rowsStack.addArrangedSubview(row)
        }
    }

    private var helps: [DiagnosticHelp] { rows.compactMap(\.help) }

    @objc func helpClicked(_ sender: NSButton) {
        guard helps.indices.contains(sender.tag) else { return }
        openURL(helps[sender.tag].url)
    }

    @objc func copyClicked(_ sender: NSButton) {
        guard helps.indices.contains(sender.tag), let command = helps[sender.tag].command else { return }
        copyText(command)
    }

    @objc func rerunClicked(_ sender: Any?) {
        onRerun?()
    }
}

/// Ventana del diagnóstico de una instancia.
@MainActor
public final class DiagnosticsWindowController: NSWindowController {
    public let panel = DiagnosticsPanelView()
    private let run: @MainActor () async -> DiagnosticsReport
    private var task: Task<Void, Never>?
    public private(set) var lastReport: DiagnosticsReport?

    public init(instanceName: String, run: @escaping @MainActor () async -> DiagnosticsReport) {
        self.run = run
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Diagnóstico de conexión — \(instanceName)"
        window.isReleasedWhenClosed = false
        window.contentView = panel
        super.init(window: window)
        panel.onRerun = { [weak self] in self?.start() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Ejecuta (o re-ejecuta) el diagnóstico; ignora pulsaciones durante una ejecución.
    public func start() {
        guard task == nil else { return }
        panel.showRunning()
        task = Task { [weak self] in
            guard let self else { return }
            let report = await run()
            lastReport = report
            panel.show(report)
            task = nil
        }
    }

    /// Para tests: espera a la ejecución en curso.
    func waitForRun() async { await task?.value }
}
