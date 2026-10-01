// T-SSH-5 (CBU-41): terminal SwiftTerm + pestañas. Headless, sin conexión
// real: un `FakeBackend` sustituye a `SshChannel`.
import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import ExplorerUI
@testable import TerminalUI

// MARK: - Doble de backend

/// Backend controlable: el test empuja salida y lee lo enviado.
/// `@unchecked Sendable`: estado mutable bajo `lock`.
private final class FakeBackend: TerminalBackend, @unchecked Sendable {
    let output: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var writes = Data()
    private var resizes: [Int] = []
    private var closed = false

    init() {
        (output, continuation) = AsyncStream<String>.makeStream()
    }

    func push(_ text: String) { continuation.yield(text) }
    func endRemote() { continuation.finish() }

    var written: Data { lock.withLock { writes } }
    var resizedColumns: [Int] { lock.withLock { resizes } }
    var isClosed: Bool { lock.withLock { closed } }

    func write(_ data: Data) async throws { lock.withLock { writes.append(data) } }
    func resize(columns: Int, rows: Int) async throws { lock.withLock { resizes.append(columns) } }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

// MARK: - Helpers

/// Espera (cediendo el main actor) hasta que `condition` se cumpla.
@MainActor
private func eventually(
    timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Texto visible, celda a celda. Los emoji (clusters de grafemas) se leen con
/// `Terminal.getCharacter(for:)`: `CharData.getCharacter()` los devuelve como
/// espacio. Se saltan las celdas de relleno (ancho 0) de los caracteres anchos.
@MainActor
private func screenText(_ view: TerminalSessionView) -> String {
    let terminal = view.terminalView.getTerminal()
    return (0..<terminal.rows).map { row in
        var line = ""
        for col in 0..<terminal.cols {
            guard let cell = terminal.getCharData(col: col, row: row), cell.width > 0 else { continue }
            let character = terminal.getCharacter(for: cell)
            line.append(character == "\u{0}" ? " " : character)
        }
        return line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }.joined(separator: "\n")
}

/// Aloja la vista en una ventana (como dentro de una pestaña).
@MainActor
private func hosted(_ view: TerminalSessionView, size: NSSize = NSSize(width: 640, height: 400)) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    // Sin esto, `close()` libera la ventana y ARC la vuelve a liberar al
    // salir del test (doble release → EXC_BAD_ACCESS).
    window.isReleasedWhenClosed = false
    view.frame = NSRect(origin: .zero, size: size)
    view.autoresizingMask = [.width, .height]
    window.contentView = view
    return window
}

// MARK: - Vista de terminal

@Suite("TerminalSessionView (headless)", .serialized)
@MainActor
struct TerminalSessionViewTests {
    @Test func feedsRemoteOutputIncludingMultibyte() async {
        let backend = FakeBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view)
        view.start()

        backend.push("hola mundo\r\n")
        backend.push("ñ€😀 日本\r\n")
        #expect(await eventually { screenText(view).contains("ñ€😀 日本") })
        #expect(screenText(view).contains("hola mundo"))
        window.close()
        await view.close()
    }

    @Test func keystrokesReachBackendInOrder() async {
        let backend = FakeBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view)
        view.start()

        for chunk in ["l", "s", " ", "-", "l", "a", "\r"] {
            view.terminalView.send(data: Array(chunk.utf8)[...])
        }
        #expect(await eventually { backend.written == Data("ls -la\r".utf8) })
        window.close()
        await view.close()
    }

    @Test func resizeIsPropagatedToBackend() async {
        let backend = FakeBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view, size: NSSize(width: 640, height: 400))
        view.start()
        let before = view.terminalSize.columns

        window.setContentSize(NSSize(width: 1200, height: 600))
        view.layoutSubtreeIfNeeded()
        let after = view.terminalSize.columns
        #expect(after > before)
        #expect(await eventually { backend.resizedColumns.last == after })
        window.close()
        await view.close()
    }

    @Test func heavyAndHostileFeedDoesNotCrash() async {
        let backend = FakeBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view)
        view.start()

        // ~1 MB con secuencias de escape, colores, movimientos de cursor,
        // borrados, título OSC y bytes de control sueltos.
        let hostile = "\u{1B}[31;1mrojo\u{1B}[0m\u{1B}[2J\u{1B}[H\u{1B}[999;999H\u{1B}]0;título\u{07}"
            + "\u{1B}[?1049h\u{1B}[?1049l\u{08}\u{7F}\t\u{0E}\u{0F}ñ€😀\r\n"
        for _ in 0..<8_000 { backend.push(hostile) }
        backend.push("FIN\r\n")
        #expect(await eventually(timeout: .seconds(30)) { screenText(view).contains("FIN") })
        window.close()
        await view.close()
    }

    @Test func remoteEndMakesViewReadOnly() async {
        let backend = FakeBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view)
        var ended = 0
        view.onEnded = { ended += 1 }
        view.start()

        backend.endRemote()
        #expect(await eventually { view.hasEnded })
        view.terminalView.send(data: Array("x".utf8)[...])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(backend.written.isEmpty)  // no se envía tras el fin
        #expect(ended == 1)
        window.close()
    }

    @Test func closeIsCleanAndIdempotent() async {
        let backend = FakeBackend()
        let view = TerminalSessionView(backend: backend)
        view.start()
        await view.close()
        await view.close()
        #expect(backend.isClosed)
        #expect(view.hasEnded)
    }
}

// MARK: - Pestañas en el área central del Explorer

@Suite("TerminalTabManager", .serialized)
@MainActor
struct TerminalTabManagerTests {
    private func explorer() -> ExplorerWindowController {
        ExplorerWindowController(viewModel: ExplorerViewModel(projects: [
            ProjectInfo(name: "p", zones: [
                ZoneInfo(project: "p", name: "z", instances: [
                    InstanceInfo(project: "p", zone: "z", name: "vm-1", os: .linux, status: .running),
                    InstanceInfo(project: "p", zone: "z", name: "vm-2", os: .linux, status: .running),
                ])
            ])
        ]))
    }

    @Test func onePerInstanceAndRedundantBackendIsClosed() async {
        let controller = explorer()
        let tabs = TerminalTabManager(host: controller.sessionTabs)
        let first = FakeBackend()
        let duplicate = FakeBackend()

        let view = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: first)
        let again = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: duplicate)
        #expect(view === again)
        #expect(controller.sessionTabs.sessionIdentifiers == ["p/z/vm-1"])
        #expect(await eventually { duplicate.isClosed })
        #expect(!first.isClosed)

        tabs.open(instanceID: "p/z/vm-2", title: "vm-2", backend: FakeBackend())
        #expect(controller.sessionTabs.sessionIdentifiers == ["p/z/vm-1", "p/z/vm-2"])
        #expect(controller.sessionTabs.selectedSessionIdentifier == "p/z/vm-2")
        await tabs.closeAll()
    }

    /// Paridad con `ExplorerUIPolishTests.statusBarAndEmptyState`: el empty
    /// state desaparece con la primera pestaña y vuelve al cerrar la última.
    @Test func emptyStateParityWithSessionArea() async {
        let controller = explorer()
        let tabs = TerminalTabManager(host: controller.sessionTabs)
        #expect(controller.sessionArea.isShowingEmptyState)

        let backend = FakeBackend()
        tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: backend)
        #expect(!controller.sessionArea.isShowingEmptyState)

        await tabs.close(instanceID: "p/z/vm-1")
        #expect(controller.sessionArea.isShowingEmptyState)
        #expect(backend.isClosed)
        #expect(tabs.openInstanceIDs.isEmpty)
    }

    @Test func endedSessionIsMarkedAndCanBeReopened() async {
        let controller = explorer()
        let tabs = TerminalTabManager(host: controller.sessionTabs)
        let backend = FakeBackend()
        let view = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: backend)

        backend.endRemote()
        #expect(await eventually { view.hasEnded })
        let label = controller.sessionArea.tabLabel(for: "p/z/vm-1")
        #expect(label == "vm-1 — desconectado")

        // Reabrir la misma instancia sustituye la pestaña terminada.
        let fresh = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: FakeBackend())
        #expect(fresh !== view)
        #expect(controller.sessionTabs.sessionIdentifiers == ["p/z/vm-1"])
        #expect(controller.sessionArea.tabLabel(for: "p/z/vm-1") == "vm-1")
        await tabs.closeAll()
    }
}
