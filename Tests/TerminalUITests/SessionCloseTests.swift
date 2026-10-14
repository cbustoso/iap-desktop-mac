// GH-64 (T-CLOSE-2..5): heurística de actividad, confirmación (un diálogo
// como mucho), ⌘W contextual, cierre idempotente y cierre agregado de ventana.
import AppKit
import Foundation
import Testing
@testable import ExplorerUI
@testable import TerminalUI

/// `@unchecked Sendable`: estado bajo `lock`.
private final class CloseBackend: TerminalBackend, @unchecked Sendable {
    let output: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var closes = 0

    init() { (output, continuation) = AsyncStream<String>.makeStream() }

    func push(_ text: String) { continuation.yield(text) }
    func endRemote() { continuation.finish() }
    var closeCount: Int { lock.withLock { closes } }

    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func close() async {
        lock.withLock { closes += 1 }
        continuation.finish()
    }
}

/// Diálogo falso: cuenta las preguntas y responde lo programado (tras ceder).
@MainActor
private final class FakeAsk {
    var answer = true
    private(set) var questions: [(message: String, informative: String)] = []
    var count: Int { questions.count }

    var ask: SessionCloseCoordinator.Ask {
        { [self] message, informative, _ in
            questions.append((message, informative))
            try? await Task.sleep(for: .milliseconds(30))  // diálogo abierto un rato
            return answer
        }
    }
}

@MainActor
private struct Rig {
    let host: SessionAreaView
    let tabs: TerminalTabManager
    let backends: [String: CloseBackend]
    let ask: FakeAsk
    let coordinator: SessionCloseCoordinator
    var ended: [String] { endedBox.values }
    let endedBox: Box

    final class Box { var values: [String] = [] }

    init(ids: [String] = ["p/z/a", "p/z/b", "p/z/c"], active: Set<String> = [], transfers: Set<String> = []) {
        host = SessionAreaView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tabs = TerminalTabManager(host: host)
        let box = Box()
        endedBox = box
        tabs.onSessionEnded = { box.values.append($0) }
        var backends: [String: CloseBackend] = [:]
        for id in ids {
            let backend = CloseBackend()
            backends[id] = backend
            tabs.open(instanceID: id, title: String(id.split(separator: "/").last!), backend: backend)
        }
        self.backends = backends
        ask = FakeAsk()
        let confirmer = SessionCloseConfirmer(
            hasActiveTransfer: { transfers.contains($0) },
            recentOutputWithinWindow: { active.contains($0) })
        coordinator = SessionCloseCoordinator(tabs: tabs, host: host, confirmer: confirmer, ask: ask.ask)
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

@Suite("SessionCloseConfirmer (T-CLOSE-3)")
@MainActor
struct SessionCloseConfirmerTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func activeTransferAlwaysConfirms() {
        let confirmer = SessionCloseConfirmer(hasActiveTransfer: { _ in true }, recentOutputWithinWindow: { _ in false })
        #expect(confirmer.isActive(instanceID: "x"))
    }

    @Test func idleSessionClosesWithoutAsking() {
        let confirmer = SessionCloseConfirmer(hasActiveTransfer: { _ in false }, recentOutputWithinWindow: { _ in false })
        #expect(!confirmer.isActive(instanceID: "x"))
    }

    @Test func notEvaluableIsFailSafeNoQuestion() {
        let confirmer = SessionCloseConfirmer(hasActiveTransfer: { _ in false }, recentOutputWithinWindow: { _ in nil })
        #expect(!confirmer.isActive(instanceID: "x"))
    }

    @Test func recentOutputHeuristic() {
        func recent(_ output: TimeInterval?, enter: TimeInterval? = nil) -> Bool {
            SessionCloseConfirmer.recentOutput(
                lastOutputAt: output.map { now.addingTimeInterval(-$0) },
                lastEmptyEnterAt: enter.map { now.addingTimeInterval(-$0) }, now: now, window: 2)
        }
        #expect(recent(0.5))  // salida hace 0,5 s → activa
        #expect(!recent(5))  // fuera de la ventana
        #expect(!recent(nil))  // nunca hubo salida
        #expect(!recent(0.5, enter: 0.6))  // respuesta a Enter vacío: el prompt
        #expect(recent(0.5, enter: 4))  // Enter vacío viejo: no cuenta
        #expect(recent(0.5, enter: 0.2))  // Enter vacío DESPUÉS de la salida: sigue activa
    }

    @Test func liveConfirmerReadsTerminalTimestamps() async throws {
        let host = SessionAreaView(frame: .zero)
        let tabs = TerminalTabManager(host: host)
        let backend = CloseBackend()
        let view = tabs.open(instanceID: "a", title: "a", backend: backend)
        var clock = Date()
        let confirmer = SessionCloseConfirmer.live(tabs: tabs, now: { clock }, hasActiveTransfer: { _ in false })
        #expect(confirmer.recentOutputWithinWindow("a") == false)  // sin salida aún
        #expect(confirmer.recentOutputWithinWindow("missing") == nil)  // no evaluable

        view.noteInput(ArraySlice(Array("ls\r".utf8)))  // comando tecleado
        backend.push("file1\r\n")
        #expect(await eventually { view.lastOutputAt != nil })
        clock = Date()
        #expect(confirmer.isActive(instanceID: "a"))

        view.noteInput([0x0d])  // Enter sobre línea vacía
        backend.push("$ ")
        let before = view.lastOutputAt
        #expect(await eventually { view.lastOutputAt != before })
        clock = Date()
        #expect(!confirmer.isActive(instanceID: "a"))  // es el prompt

        clock = Date().addingTimeInterval(10)
        #expect(!confirmer.isActive(instanceID: "a"))  // pasó la ventana
        backend.endRemote()
        #expect(await eventually { view.hasEnded })
        #expect(confirmer.recentOutputWithinWindow("a") == false)  // canal cerrado
    }
}

@Suite("Cierre individual (T-CLOSE-2/4)", .timeLimit(.minutes(1)))
@MainActor
struct SessionIndividualCloseTests {
    @Test func idleTabClosesWithoutDialogAndOnlyThatTab() async {
        let rig = Rig()
        #expect(await rig.coordinator.requestClose(instanceID: "p/z/b", title: "b"))
        #expect(rig.ask.count == 0)
        #expect(rig.tabs.openInstanceIDs == ["p/z/a", "p/z/c"])
        #expect(rig.backends["p/z/b"]?.closeCount == 1)  // canal shell liberado
        #expect(rig.backends["p/z/a"]?.closeCount == 0)
        #expect(rig.ended == ["p/z/b"])
    }

    @Test func activeTabAsksOnceCancelKeepsIt() async {
        let rig = Rig(active: ["p/z/a"])
        rig.ask.answer = false
        #expect(!(await rig.coordinator.requestClose(instanceID: "p/z/a", title: "a")))
        #expect(rig.ask.count == 1)
        #expect(rig.ask.questions.first?.message == "¿Cerrar a?")
        #expect(rig.tabs.openInstanceIDs.contains("p/z/a"))
        #expect(rig.backends["p/z/a"]?.closeCount == 0)
        #expect(rig.ended.isEmpty)
    }

    @Test func activeTabConfirmCloses() async {
        let rig = Rig(transfers: ["p/z/a"])  // transferencia Files en curso
        #expect(await rig.coordinator.requestClose(instanceID: "p/z/a", title: "a"))
        #expect(rig.ask.count == 1)
        #expect(!rig.tabs.openInstanceIDs.contains("p/z/a"))
    }

    @Test func repeatedRequestsWhileAskingShowOneDialog() async {
        let rig = Rig(active: ["p/z/a"])
        async let first = rig.coordinator.requestClose(instanceID: "p/z/a", title: "a")
        try? await Task.sleep(for: .milliseconds(5))
        let second = await rig.coordinator.requestClose(instanceID: "p/z/a", title: "a")  // ⌘W otra vez
        let firstResult = await first
        #expect(firstResult)
        #expect(!second)
        #expect(rig.ask.count == 1)
        #expect(rig.ended == ["p/z/a"])
    }

    @Test func doubleCloseAndRemoteEndNotifyOnce() async {
        let rig = Rig()
        // Race: el remoto termina y después se pulsa ×.
        rig.backends["p/z/a"]?.endRemote()
        #expect(await eventually { rig.tabs.view(for: "p/z/a")?.hasEnded == true })
        #expect(rig.ended == ["p/z/a"])
        #expect(await rig.coordinator.requestClose(instanceID: "p/z/a", title: "a"))
        #expect(rig.ended == ["p/z/a"])  // no se duplica
        // Doble cierre: el segundo no hace nada ni lanza.
        await rig.tabs.close(instanceID: "p/z/b")
        await rig.tabs.close(instanceID: "p/z/b")
        #expect(!(await rig.coordinator.requestClose(instanceID: "p/z/b", title: "b")))
        #expect(rig.ended == ["p/z/a", "p/z/b"])
        #expect(rig.backends["p/z/b"]?.closeCount == 1)
    }

    @Test func nonSessionTabsAreNotHandled() async {
        let rig = Rig(ids: ["p/z/a"])
        rig.host.openSession(identifier: "p/z/a#files", title: "Files", content: NSView())
        #expect(!rig.coordinator.isSessionTab("p/z/a#files"))
        #expect(!(await rig.coordinator.requestClose(instanceID: "p/z/a#files", title: "Files")))
        #expect(rig.host.sessionIdentifiers.contains("p/z/a#files"))
    }

    @Test func commandWClosesSelectedSessionTabAndKeepsWindow() async {
        let rig = Rig()
        rig.host.selectSession(identifier: "p/z/b")
        var windowClosed = false
        rig.coordinator.closeActiveSessionOrWindow(title: { String($0.split(separator: "/").last!) }) { windowClosed = true }
        #expect(await eventually { !rig.tabs.openInstanceIDs.contains("p/z/b") })
        #expect(!windowClosed)
        #expect(rig.tabs.openInstanceIDs == ["p/z/a", "p/z/c"])
    }

    @Test func commandWWithoutSessionTabClosesWindow() {
        let empty = Rig(ids: [])
        var closed = 0
        empty.coordinator.closeActiveSessionOrWindow(title: { $0 }) { closed += 1 }
        #expect(closed == 1)  // comportamiento anterior

        let files = Rig(ids: ["p/z/a"])
        files.host.openSession(identifier: "p/z/a#files", title: "Files", content: NSView())  // seleccionada
        files.coordinator.closeActiveSessionOrWindow(title: { $0 }) { closed += 1 }
        #expect(closed == 2)
        #expect(files.tabs.openInstanceIDs == ["p/z/a"])
    }
}

@Suite("Cierre de ventana (T-CLOSE-5)", .timeLimit(.minutes(1)))
@MainActor
struct WindowCloseTests {
    @Test func idleTabsCloseWithoutDialog() async {
        let rig = Rig()
        var reclosed = 0
        var othersClosed = 0
        let allowed1 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: { othersClosed += 1 }, reclose: { reclosed += 1 })
        #expect(!allowed1)
        #expect(await eventually { reclosed == 1 })
        #expect(rig.ask.count == 0)
        #expect(rig.tabs.openInstanceIDs.isEmpty)
        #expect(othersClosed == 1)  // Files también
        #expect(rig.backends.values.allSatisfy { $0.closeCount == 1 })
        #expect(rig.ended.sorted() == ["p/z/a", "p/z/b", "p/z/c"])
        // Segundo intento (el `reclose`): ya aprobado.
        let allowed2 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: {}, reclose: {})
        #expect(allowed2)
    }

    @Test func oneActiveOfThreeAsksOnceAndConfirmClosesAll() async {
        let rig = Rig(active: ["p/z/b"])
        var reclosed = 0
        let allowed3 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: {}, reclose: { reclosed += 1 })
        #expect(!allowed3)
        // Cerrar otra vez mientras el diálogo está abierto: ningún diálogo más.
        let allowed4 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: {}, reclose: { reclosed += 1 })
        #expect(!allowed4)
        #expect(await eventually { reclosed == 1 })
        #expect(rig.ask.count == 1)
        #expect(rig.ask.questions.first?.informative == "Hay 1 sesión con actividad. Se cerrarán 3 sesión(es) SSH.")
        #expect(rig.tabs.openInstanceIDs.isEmpty)
    }

    @Test func cancelKeepsWindowAndAllTabs() async {
        let rig = Rig(active: ["p/z/a", "p/z/c"])
        rig.ask.answer = false
        var reclosed = 0
        let allowed5 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: {}, reclose: { reclosed += 1 })
        #expect(!allowed5)
        #expect(await eventually { rig.ask.count == 1 })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(reclosed == 0)
        #expect(rig.tabs.openInstanceIDs == ["p/z/a", "p/z/b", "p/z/c"])
        #expect(rig.backends.values.allSatisfy { $0.closeCount == 0 })
        #expect(rig.ended.isEmpty)
        // Un nuevo intento vuelve a preguntar (una vez).
        let allowed6 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: {}, reclose: { reclosed += 1 })
        #expect(!allowed6)
        #expect(await eventually { rig.ask.count == 2 })
    }

    @Test func noTabsClosesImmediately() {
        let rig = Rig(ids: [])
        let allowed7 = rig.coordinator.windowShouldClose(hasOtherTabs: false, closeOthers: {}, reclose: {})
        #expect(allowed7)
    }

    @Test func onlyFilesTabsStillCleanedBeforeClosing() async {
        let rig = Rig(ids: [])
        var othersClosed = 0
        var reclosed = 0
        let allowed8 = rig.coordinator.windowShouldClose(hasOtherTabs: true, closeOthers: { othersClosed += 1 }, reclose: { reclosed += 1 })
        #expect(!allowed8)
        #expect(await eventually { reclosed == 1 })
        #expect(othersClosed == 1)
        #expect(rig.ask.count == 0)
    }
}
