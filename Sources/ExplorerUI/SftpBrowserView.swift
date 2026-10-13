// GH-60 (T-SFTP-5): explorador de ficheros remoto (pestaña "Files" de una
// instancia). ExplorerUI no conoce SFTP: la App adapta FileBrowserViewModel
// (SFTPKit) a `SftpBrowserModel`. AppKit puro; drag&drop nativo:
// - subida: soltar ficheros de Finder (URLs de fichero) sobre la tabla;
// - descarga: arrastrar una fila a Finder (`NSFilePromiseProvider`).
import AppKit

public struct SftpBrowserRow: Equatable, Sendable {
    public var name: String
    public var size: String
    public var modified: String
    /// `drwxr-xr-x`
    public var permissions: String
    public var isDirectory: Bool
    public var isDownloadable: Bool

    public init(name: String, size: String, modified: String, permissions: String, isDirectory: Bool, isDownloadable: Bool) {
        self.name = name
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.isDirectory = isDirectory
        self.isDownloadable = isDownloadable
    }
}

public struct SftpBrowserCrumb: Equatable, Sendable {
    public var title: String
    public var path: String

    public init(title: String, path: String) {
        self.title = title
        self.path = path
    }
}

public struct SftpBrowserTransferRow: Equatable, Sendable {
    public var name: String
    /// 0…1, o `nil` (indeterminado).
    public var fraction: Double?
    public var status: String

    public init(name: String, fraction: Double?, status: String) {
        self.name = name
        self.fraction = fraction
        self.status = status
    }
}

/// Lo que la vista necesita del explorador (lo implementa la App).
@MainActor
public protocol SftpBrowserModel: AnyObject {
    var rows: [SftpBrowserRow] { get }
    var crumbs: [SftpBrowserCrumb] { get }
    /// Transferencias recientes (la última, al final).
    var transfers: [SftpBrowserTransferRow] { get }
    var isLoading: Bool { get }
    var errorText: String? { get }
    var onChange: (@MainActor () -> Void)? { get set }

    func openRow(_ index: Int)
    func navigate(to path: String)
    func goUp()
    func refresh()
    func conflictingNames(for localURLs: [URL]) -> [String]
    func upload(_ localURLs: [URL])
    /// Descarga la fila a `fileURL`; `completion` cuando termina (nil = éxito).
    func download(row: Int, to fileURL: URL, completion: @escaping @MainActor ((any Error)?) -> Void)
    func close()
}

@MainActor
public final class SftpBrowserView: NSView {
    // Internos (no privados) para los tests.
    let tableView = NSTableView()
    let crumbBar = NSStackView()
    let statusLabel = NSTextField(labelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let upButton = NSButton()
    let refreshButton = NSButton()
    let uploadButton = NSButton()
    let downloadButton = NSButton()
    let closeButton = NSButton()

    public let model: any SftpBrowserModel
    /// Confirmación antes de sobrescribir (por defecto, NSAlert). Inyectable en tests.
    public var confirmOverwrite: @MainActor ([String]) -> Bool = SftpBrowserView.askOverwrite
    /// Elección de ficheros a subir / destino de descarga (paneles; inyectables).
    public var chooseUploads: @MainActor () -> [URL] = SftpBrowserView.openPanel
    public var chooseDownloadDestination: @MainActor (String) -> URL? = SftpBrowserView.savePanel

    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
    static let permissionsColumn = NSUserInterfaceItemIdentifier("permissions")

    public init(model: any SftpBrowserModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        build()
        model.onChange = { [weak self] in self?.reload() }
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Estado → vista

    func reload() {
        tableView.reloadData()
        rebuildCrumbs()
        upButton.isEnabled = model.crumbs.count > 1
        updateDownloadButton()
        if let error = model.errorText {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemRed
        } else if let transfer = model.transfers.last {
            statusLabel.stringValue = "\(transfer.name): \(transfer.status)"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = model.isLoading ? "Cargando…" : "\(model.rows.count) elementos"
            statusLabel.textColor = .secondaryLabelColor
        }
        if let transfer = model.transfers.last, let fraction = transfer.fraction, fraction < 1 {
            progressIndicator.isHidden = false
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = fraction
        } else if model.isLoading || model.transfers.last.map({ $0.fraction == nil && $0.status == Self.inProgress }) == true {
            progressIndicator.isHidden = false
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
        }
    }

    /// Texto de estado que la App usa mientras una transferencia sigue viva.
    public static let inProgress = "transfiriendo…"

    private func rebuildCrumbs() {
        crumbBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, crumb) in model.crumbs.enumerated() {
            if index > 1 {
                let separator = NSTextField(labelWithString: "›")
                separator.textColor = .tertiaryLabelColor
                crumbBar.addArrangedSubview(separator)
            }
            let button = NSButton(title: crumb.title, target: self, action: #selector(crumbClicked(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.tag = index
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: index == model.crumbs.count - 1 ? .semibold : .regular)
            button.lineBreakMode = .byTruncatingMiddle
            crumbBar.addArrangedSubview(button)
        }
    }

    var crumbButtons: [NSButton] { crumbBar.arrangedSubviews.compactMap { $0 as? NSButton } }

    private func updateDownloadButton() {
        let row = tableView.selectedRow
        downloadButton.isEnabled = row >= 0 && row < model.rows.count && model.rows[row].isDownloadable
    }

    // MARK: - Acciones

    @objc func crumbClicked(_ sender: NSButton) {
        guard model.crumbs.indices.contains(sender.tag) else { return }
        model.navigate(to: model.crumbs[sender.tag].path)
    }

    @objc func goUp(_ sender: Any?) { model.goUp() }
    @objc func refresh(_ sender: Any?) { model.refresh() }
    @objc func closeBrowser(_ sender: Any?) { model.close() }

    @objc func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard model.rows.indices.contains(row) else { return }
        model.openRow(row)
    }

    @objc func uploadClicked(_ sender: Any?) {
        upload(chooseUploads())
    }

    @objc func downloadClicked(_ sender: Any?) {
        let row = tableView.selectedRow
        guard model.rows.indices.contains(row), model.rows[row].isDownloadable,
              let destination = chooseDownloadDestination(model.rows[row].name)
        else { return }
        model.download(row: row, to: destination) { _ in }
    }

    /// Sube tras confirmar si algún nombre ya existe (subir sobrescribe).
    @discardableResult
    func upload(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        let conflicts = model.conflictingNames(for: files)
        guard conflicts.isEmpty || confirmOverwrite(conflicts) else { return false }
        model.upload(files)
        return true
    }

    // MARK: - Paneles por defecto

    static func askOverwrite(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1 ? "\"\(names[0])\" ya existe" : "\(names.count) ficheros ya existen"
        alert.informativeText = "Subirlos sobrescribirá los ficheros remotos."
        alert.addButton(withTitle: "Sobrescribir")
        alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openPanel() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Subir"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func savePanel(_ name: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.prompt = "Descargar"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: - Construcción

    private func build() {
        func toolButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        toolButton(upButton, symbol: "arrow.up", tip: "Directorio superior", action: #selector(goUp(_:)))
        toolButton(refreshButton, symbol: "arrow.clockwise", tip: "Refrescar", action: #selector(refresh(_:)))
        toolButton(uploadButton, symbol: "square.and.arrow.up", tip: "Subir…", action: #selector(uploadClicked(_:)))
        toolButton(downloadButton, symbol: "square.and.arrow.down", tip: "Descargar…", action: #selector(downloadClicked(_:)))
        toolButton(closeButton, symbol: "xmark", tip: "Cerrar explorador", action: #selector(closeBrowser(_:)))

        crumbBar.orientation = .horizontal
        crumbBar.spacing = 2
        crumbBar.setHuggingPriority(.defaultLow, for: .horizontal)
        crumbBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [upButton, crumbBar, NSView(), refreshButton, uploadButton, downloadButton, closeButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        for (identifier, title, width) in [
            (Self.nameColumn, "Nombre", 260.0), (Self.sizeColumn, "Tamaño", 80),
            (Self.modifiedColumn, "Modificado", 130), (Self.permissionsColumn, "Permisos", 100),
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 60
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([], forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isHidden = true
        progressIndicator.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let footer = NSStackView(views: [statusLabel, NSView(), progressIndicator])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let stack = NSStackView(views: [toolbar, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}

// MARK: - Tabla

extension SftpBrowserView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, model.rows.indices.contains(row) else { return nil }
        let entry = model.rows[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        switch identifier {
        case Self.nameColumn:
            text.stringValue = entry.name
            let icon = NSImageView(image: NSImage(
                systemSymbolName: entry.isDirectory ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage())
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
            ])
            leading = icon.trailingAnchor
        case Self.sizeColumn:
            text.stringValue = entry.size
            text.alignment = .right
        case Self.modifiedColumn:
            text.stringValue = entry.modified
        case Self.permissionsColumn:
            text.stringValue = entry.permissions
            text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        default:
            return nil
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateDownloadButton()
    }

    // Descarga: arrastrar una fila a Finder.
    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard model.rows.indices.contains(row), model.rows[row].isDownloadable else { return nil }
        let provider = NSFilePromiseProvider(fileType: "public.data", delegate: self)
        provider.userInfo = row
        return provider
    }

    // Subida: soltar URLs de fichero (solo de fuera de esta tabla).
    public func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard (info.draggingSource as? NSTableView) !== tableView, !Self.fileURLs(in: info.draggingPasteboard).isEmpty
        else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)  // todo el listado: directorio actual
        return .copy
    }

    public func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        upload(Self.fileURLs(in: info.draggingPasteboard))
    }

    static func fileURLs(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

// MARK: - Promesas de fichero (descarga por arrastre)

extension SftpBrowserView: NSFilePromiseProviderDelegate {
    /// Los callbacks llegan en la cola principal (ver `operationQueue(for:)`).
    public nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let row = provider.userInfo as? Int
        return MainActor.assumeIsolated {
            guard let row, model.rows.indices.contains(row) else { return "download" }
            return model.rows[row].name
        }
    }

    public nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    public nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let handler = UncheckedCompletion(completionHandler)
        let row = provider.userInfo as? Int
        MainActor.assumeIsolated {
            guard let row, model.rows.indices.contains(row) else {
                handler.call(CocoaError(.fileNoSuchFile))
                return
            }
            model.download(row: row, to: url) { handler.call($0) }
        }
    }
}

/// El completion de AppKit no es `Sendable`, pero AppKit lo espera desde
/// cualquier hilo; se invoca una sola vez desde el actor principal.
private struct UncheckedCompletion: @unchecked Sendable {
    let body: ((any Error)?) -> Void
    init(_ body: @escaping ((any Error)?) -> Void) { self.body = body }
    func call(_ error: (any Error)?) { body(error) }
}
