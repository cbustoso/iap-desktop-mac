// GH-64 (T-CLOSE-1): botón `×` por pestaña en SessionAreaView.
import AppKit
import Testing
@testable import ExplorerUI

@MainActor
private func area(_ ids: [String] = ["p/z/web-01", "p/z/db-01"]) -> SessionAreaView {
    let area = SessionAreaView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    for id in ids { area.openSession(identifier: id, title: String(id.split(separator: "/").last!), content: NSView()) }
    return area
}

@Suite("Cierre por pestaña: botón × (GH-64)")
@MainActor
struct SessionTabCloseTests {
    @Test func closeButtonOnlyVisibleOnHover() throws {
        let area = area()
        var requested: [String] = []
        area.onCloseRequested = { requested.append($0) }
        let web = try #require(area.tabItems["p/z/web-01"])
        let db = try #require(area.tabItems["p/z/db-01"])
        #expect(web.closeButton.isHidden)
        #expect(db.closeButton.isHidden)

        web.mouseEntered(with: NSEvent())
        #expect(!web.closeButton.isHidden)
        #expect(db.closeButton.isHidden)  // solo la pestaña bajo el ratón
        web.mouseExited(with: NSEvent())
        #expect(web.closeButton.isHidden)
        #expect(requested.isEmpty)
    }

    @Test func pressingCloseReportsIdentifierWithoutClosingAnything() throws {
        let area = area()
        var requested: [String] = []
        area.onCloseRequested = { requested.append($0) }
        let db = try #require(area.tabItems["p/z/db-01"])
        db.isHovering = true
        db.closeButton.performClick(nil)
        #expect(requested == ["p/z/db-01"])
        // El área no decide: ninguna pestaña desaparece hasta que la App llame a closeSession.
        #expect(area.sessionIdentifiers == ["p/z/web-01", "p/z/db-01"])
        #expect(area.tabItems.count == 2)
    }

    @Test func withoutHandlerThereIsNoCloseButton() throws {
        let area = area()
        let web = try #require(area.tabItems["p/z/web-01"])
        web.isHovering = true
        #expect(web.closeButton.isHidden)
        web.closeClicked(nil)  // sin handler no hace nada (ni crashea)
        #expect(area.sessionCount == 2)
        area.onCloseRequested = { _ in }
        #expect(!web.closeButton.isHidden)  // aparece al cablearlo
    }

    @Test func clickingTabSelectsIt() throws {
        let area = area()
        #expect(area.selectedSessionIdentifier == "p/z/db-01")  // la última abierta
        let web = try #require(area.tabItems["p/z/web-01"])
        web.mouseDown(with: NSEvent())
        #expect(area.selectedSessionIdentifier == "p/z/web-01")
        #expect(web.isSelected)
        #expect(area.tabItems["p/z/db-01"]?.isSelected == false)
    }

    @Test func closingOneTabLeavesTheOthersAndEmptyStateReturns() {
        let area = area(["a", "b", "c"])
        area.onCloseRequested = { _ in }
        area.closeSession(identifier: "b")
        #expect(area.sessionIdentifiers == ["a", "c"])
        #expect(area.tabItems.keys.sorted() == ["a", "c"])
        #expect(area.tabStrip.arrangedSubviews.count == 2)
        #expect(area.selectedSessionIdentifier != nil)
        area.closeSession(identifier: "a")
        area.closeSession(identifier: "c")
        area.closeSession(identifier: "c")  // idempotente
        #expect(area.isShowingEmptyState)
        #expect(area.tabStrip.isHidden)
    }

    @Test func titlesUpdateInTheStrip() {
        let area = area(["a"])
        area.setSessionTitle("web-01 — desconectado", identifier: "a")
        #expect(area.tabLabel(for: "a") == "web-01 — desconectado")
        #expect(area.tabItems["a"]?.title == "web-01 — desconectado")
        #expect(area.tabItems["a"]?.closeButton.accessibilityLabel() == "Cerrar web-01 — desconectado")
    }

    @Test func reopeningExistingIdentifierDoesNotDuplicateTab() {
        let area = area(["a"])
        area.openSession(identifier: "a", title: "a", content: NSView())
        #expect(area.tabStrip.arrangedSubviews.count == 1)
    }

    @Test func layoutWithStripIsUnambiguous() {
        let area = area(["a", "b"])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = area
        window.layoutIfNeeded()
        #expect(!area.hasAmbiguousLayout)
        #expect(area.tabItems["a"]!.frame.width >= 80)
        window.close()
    }
}
