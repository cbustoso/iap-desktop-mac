import AppKit
import GCPClient

/// Elimina secuencias CSI de VT100 y conserva una secuencia incompleta entre
/// fragmentos. No interpreta colores ni movimiento del cursor: produce texto
/// legible para el visor de solo lectura.
public struct VT100Filter: Sendable {
    private var pending = ""

    public init() {}

    public mutating func consume(_ fragment: String) -> String {
        let input = pending + fragment
        pending = ""
        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            guard input[index] == "\u{1B}" else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }

            let escapeStart = index
            index = input.index(after: index)
            guard index < input.endIndex else {
                pending = String(input[escapeStart...])
                break
            }
            guard input[index] == "[" else {
                // Secuencia ESC no CSI: se descarta ESC y se conserva el texto.
                continue
            }

            index = input.index(after: index)
            var completed = false
            while index < input.endIndex {
                let scalar = input[index].unicodeScalars.first!
                index = input.index(after: index)
                if (0x40...0x7E).contains(scalar.value) {
                    completed = true
                    break
                }
            }
            if !completed {
                pending = String(input[escapeStart...])
                break
            }
        }
        return output
    }
}

/// Panel de salida serie de una instancia. Cada puerto mantiene su propia vista
/// desde el cursor inicial; cambiar de puerto limpia el texto y reinicia el polling.
@MainActor
public final class SerialOutputWindowController: NSWindowController, NSWindowDelegate {
    private let instance: InstanceInfo
    private let client: GCPClient
    private let refreshInterval: Duration
    private let textView = NSTextView()
    private let portSelector = NSPopUpButton()
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var pollingTask: Task<Void, Never>?
    private var nextToken: String?
    private var filter = VT100Filter()

    public init(
        instance: InstanceInfo,
        client: GCPClient,
        refreshInterval: Duration = .seconds(2)
    ) {
        self.instance = instance
        self.client = client
        self.refreshInterval = refreshInterval
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Serial port output — \(instance.name)"
        window.setFrameAutosaveName("SerialOutputWindow")
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
        startPolling(reset: pollingTask == nil && nextToken == nil && textView.string.isEmpty)
    }

    public func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    private var selectedPort: Int { portSelector.indexOfSelectedItem + 1 }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let portLabel = NSTextField(labelWithString: "Port:")
        portSelector.addItems(withTitles: ["1", "2", "3", "4"])
        portSelector.target = self
        portSelector.action = #selector(portChanged(_:))
        stopButton.target = self
        stopButton.action = #selector(stopPressed(_:))
        stopButton.bezelStyle = .rounded
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.autoresizingMask = [.width]
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        for view in [portLabel, portSelector, stopButton, statusLabel, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            portLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            portLabel.centerYAnchor.constraint(equalTo: portSelector.centerYAnchor),
            portSelector.leadingAnchor.constraint(equalTo: portLabel.trailingAnchor, constant: 6),
            portSelector.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stopButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: portSelector.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: portSelector.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: portSelector.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: portSelector.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @objc private func portChanged(_ sender: NSPopUpButton) {
        startPolling(reset: true)
    }

    @objc private func stopPressed(_ sender: NSButton) {
        stopPolling()
        statusLabel.stringValue = "Stopped"
    }

    private func startPolling(reset: Bool) {
        pollingTask?.cancel()
        if reset {
            nextToken = nil
            filter = VT100Filter()
            textView.string = ""
        }
        stopButton.isEnabled = true
        statusLabel.stringValue = "Refreshing…"
        let port = selectedPort
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let response = try await client.getSerialPortOutput(
                        project: instance.project,
                        zone: instance.zone,
                        instance: instance.name,
                        port: port,
                        start: nextToken)
                    guard !Task.isCancelled else { return }
                    if !response.contents.isEmpty {
                        append(filter.consume(response.contents))
                    }
                    if let next = response.next { nextToken = next }
                    statusLabel.stringValue = "Auto-refresh every 2 seconds"
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    statusLabel.stringValue = "Could not refresh serial output"
                }
                do {
                    try await Task.sleep(for: refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        stopButton.isEnabled = false
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        textView.textStorage?.append(NSAttributedString(string: text))
        textView.scrollToEndOfDocument(nil)
    }
}
