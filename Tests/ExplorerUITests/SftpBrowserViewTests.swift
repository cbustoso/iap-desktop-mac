// GH-60: SftpBrowserView con un modelo falso: columnas, breadcrumb,
// navegación, subida con confirmación, descarga por arrastre y progreso.
import AppKit
import Testing
@testable import ExplorerUI

@MainActor
private final class FakeBrowserModel: SftpBrowserModel {
    var rows: [SftpBrowserRow] = [
        SftpBrowserRow(name: "src", size: "—", modified: "2023-11-14 22:13", permissions: "drwxr-xr-x",
                       isDirectory: true, isDownloadable: false),
        SftpBrowserRow(name: "notes.txt", size: "4 B", modified: "2023-11-14 22:15", permissions: "-rw-r--r--",
                       isDirectory: false, isDownloadable: true),
    ]
    var crumbs = [
        SftpBrowserCrumb(title: "/", path: "/"), SftpBrowserCrumb(title: "home", path: "/home"),
        SftpBrowserCrumb(title: "ada", path: "/home/ada"),
    ]
    var transfers: [SftpBrowserTransferRow] = []
    var isLoading = false
    var errorText: String?
    var onChange: (@MainActor () -> Void)?

    var opened: [Int] = []
    var navigated: [String] = []
    var wentUp = 0
    var uploaded: [[URL]] = []
    var downloads: [(row: Int, url: URL)] = []
    var closed = false
    var existing: Set<String> = []

    func openRow(_ index: Int) { opened.append(index) }
    func navigate(to path: String) { navigated.append(path) }
    func goUp() { wentUp += 1 }
    func refresh() {}
    func conflictingNames(for localURLs: [URL]) -> [String] {
        localURLs.map(\.lastPathComponent).filter(existing.contains)
    }
    func upload(_ localURLs: [URL]) { uploaded.append(localURLs) }
    func download(row: Int, to fileURL: URL, completion: @escaping @MainActor ((any Error)?) -> Void) {
        downloads.append((row, fileURL))
        completion(nil)
    }
    func close() { closed = true }
}

@MainActor
private func cellText(_ view: SftpBrowserView, row: Int, column: NSUserInterfaceItemIdentifier) -> String? {
    let tableColumn = view.tableView.tableColumns.first { $0.identifier == column }
    return (view.tableView(view.tableView, viewFor: tableColumn, row: row) as? NSTableCellView)?.textField?.stringValue
}

@Suite("SftpBrowserView (GH-60)")
@MainActor
struct SftpBrowserViewTests {
    @Test func showsFourColumnsWithFormattedValues() {
        let view = SftpBrowserView(model: FakeBrowserModel())
        #expect(view.tableView.tableColumns.map(\.title) == ["Nombre", "Tamaño", "Modificado", "Permisos"])
        #expect(view.tableView.numberOfRows == 2)
        #expect(cellText(view, row: 0, column: SftpBrowserView.nameColumn) == "src")
        #expect(cellText(view, row: 1, column: SftpBrowserView.sizeColumn) == "4 B")
        #expect(cellText(view, row: 1, column: SftpBrowserView.modifiedColumn) == "2023-11-14 22:15")
        #expect(cellText(view, row: 0, column: SftpBrowserView.permissionsColumn) == "drwxr-xr-x")
        #expect(cellText(view, row: 1, column: SftpBrowserView.permissionsColumn) == "-rw-r--r--")
        #expect(view.statusLabel.stringValue == "2 elementos")
    }

    @Test func breadcrumbNavigatesAndUpGoesToParent() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        #expect(view.crumbButtons.map(\.title) == ["/", "home", "ada"])
        view.crumbButtons[1].performClick(nil)
        #expect(model.navigated == ["/home"])
        #expect(view.upButton.isEnabled)
        view.upButton.performClick(nil)
        #expect(model.wentUp == 1)

        model.crumbs = [SftpBrowserCrumb(title: "/", path: "/")]
        model.onChange?()
        #expect(!view.upButton.isEnabled)  // en la raíz
        #expect(view.crumbButtons.map(\.title) == ["/"])
    }

    @Test func doubleClickOpensRow() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        view.tableView.selectRowIndexes([0], byExtendingSelection: false)
        view.rowDoubleClicked(nil)
        #expect(model.opened == [0])
    }

    @Test func uploadAsksBeforeOverwriting() {
        let model = FakeBrowserModel()
        model.existing = ["notes.txt"]
        let view = SftpBrowserView(model: model)
        let fresh = URL(fileURLWithPath: "/tmp/new.txt")
        let clash = URL(fileURLWithPath: "/tmp/notes.txt")

        var asked: [[String]] = []
        view.confirmOverwrite = { asked.append($0); return false }
        #expect(!view.upload([fresh, clash]))
        #expect(asked == [["notes.txt"]])
        #expect(model.uploaded.isEmpty)  // cancelado: no se trunca nada

        view.confirmOverwrite = { _ in true }
        #expect(view.upload([fresh, clash]))
        #expect(model.uploaded == [[fresh, clash]])

        // Sin conflictos, sin pregunta; URLs no de fichero, ignoradas.
        view.confirmOverwrite = { _ in Issue.record("no debía preguntar"); return false }
        #expect(view.upload([fresh, URL(string: "https://example.com/x")!]))
        #expect(model.uploaded.last == [fresh])
        #expect(!view.upload([URL(string: "https://example.com/x")!]))
    }

    @Test func uploadButtonUsesChosenFiles() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        let picked = URL(fileURLWithPath: "/tmp/a.bin")
        view.chooseUploads = { [picked] }
        view.uploadButton.performClick(nil)
        #expect(model.uploaded == [[picked]])
    }

    @Test func dragOutPromisesFilesOnly() throws {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        #expect(view.tableView(view.tableView, pasteboardWriterForRow: 0) == nil)  // directorio
        let provider = try #require(view.tableView(view.tableView, pasteboardWriterForRow: 1) as? NSFilePromiseProvider)
        #expect(view.filePromiseProvider(provider, fileNameForType: "public.data") == "notes.txt")

        let destination = URL(fileURLWithPath: "/tmp/Downloads/notes.txt")
        var completed: [Bool] = []
        view.filePromiseProvider(provider, writePromiseTo: destination) { completed.append($0 == nil) }
        #expect(model.downloads.map(\.row) == [1])
        #expect(model.downloads.map(\.url) == [destination])
        #expect(completed == [true])
    }

    @Test func downloadButtonFollowsSelectionAndSavePanel() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        #expect(!view.downloadButton.isEnabled)
        view.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(!view.downloadButton.isEnabled)  // directorio
        view.tableView.selectRowIndexes([1], byExtendingSelection: false)
        #expect(view.downloadButton.isEnabled)
        let target = URL(fileURLWithPath: "/tmp/elsewhere.txt")
        var suggested: [String] = []
        view.chooseDownloadDestination = { suggested.append($0); return target }
        view.downloadButton.performClick(nil)
        #expect(suggested == ["notes.txt"])
        #expect(model.downloads.map(\.url) == [target])
    }

    @Test func acceptsFileDropsAsUpload() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        #expect(view.tableView.registeredDraggedTypes.contains(.fileURL))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sftp-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/dropped.txt")
        pasteboard.writeObjects([file as NSURL])
        #expect(SftpBrowserView.fileURLs(in: pasteboard) == [file])
        #expect(view.upload(SftpBrowserView.fileURLs(in: pasteboard)))
        #expect(model.uploaded == [[file]])
        pasteboard.releaseGlobally()
    }

    @Test func progressAndErrorsReachTheFooter() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        #expect(view.progressIndicator.isHidden)

        model.transfers = [SftpBrowserTransferRow(name: "↑ big.bin", fraction: 0.4, status: "40 %")]
        model.onChange?()
        #expect(!view.progressIndicator.isHidden)
        #expect(!view.progressIndicator.isIndeterminate)
        #expect(view.progressIndicator.doubleValue == 0.4)
        #expect(view.statusLabel.stringValue == "↑ big.bin: 40 %")

        model.transfers = [SftpBrowserTransferRow(name: "↑ big.bin", fraction: 1, status: "completado (1.0 MB)")]
        model.onChange?()
        #expect(view.progressIndicator.isHidden)
        #expect(view.statusLabel.stringValue == "↑ big.bin: completado (1.0 MB)")

        model.errorText = "nope: no existe."
        model.onChange?()
        #expect(view.statusLabel.stringValue == "nope: no existe.")
    }

    @Test func closeButtonClosesBrowser() {
        let model = FakeBrowserModel()
        let view = SftpBrowserView(model: model)
        view.closeButton.performClick(nil)
        #expect(model.closed)
    }
}

@Suite("SftpBrowserView layout (GH-60)")
@MainActor
struct SftpBrowserViewLayoutTests {
    @Test func laysOutWithoutAmbiguityInAWindow() {
        let view = SftpBrowserView(model: FakeBrowserModel())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.layoutIfNeeded()
        #expect(!view.hasAmbiguousLayout)
        #expect(view.tableView.enclosingScrollView!.frame.height > 200)  // la tabla ocupa el espacio
        #expect(view.crumbBar.frame.width > 0)
        window.close()
    }
}
