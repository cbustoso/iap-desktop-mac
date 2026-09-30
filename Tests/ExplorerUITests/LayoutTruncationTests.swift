// CBU-36 fixes: truncado de la status bar y wrap del empty-state, medidos con
// las vistas alojadas en una ventana (como en la app). Sin supervista, Auto
// Layout no fija su ancho y las medidas no son representativas.
import AppKit
import Testing
@testable import ExplorerUI

/// `true` si la etiqueta muestra su texto completo (sin "…" ni recorte).
@MainActor
private func isFullyVisible(_ label: NSTextField) -> Bool {
    label.frame.width + 0.5 >= label.intrinsicContentSize.width
        && label.frame.height + 0.5 >= label.intrinsicContentSize.height
}

/// Aloja `view` anclada a los bordes de una ventana de `width` × `height`.
@MainActor
private func host(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    let content = window.contentView!
    view.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        view.topAnchor.constraint(equalTo: content.topAnchor),
        view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    content.layoutSubtreeIfNeeded()
    return content
}

@Suite("Truncado de layout")
@MainActor
struct LayoutTruncationTests {
    private let longSummary = "LIVE — 12 proyectos, 348 instancias (27 visibles)"
    private let longNote = "demo-web-production-europe (MOCK) refrescado hace un momento"

    private func hostedBar(width: CGFloat) -> (StatusBarView, NSView) {
        let bar = StatusBarView(frame: .zero)
        bar.summary = longSummary
        bar.note = longNote
        return (bar, host(bar, width: width, height: StatusBarView.height))
    }

    @Test func wideWindowShowsEverything() {
        let (bar, _) = hostedBar(width: 1400)
        #expect(isFullyVisible(bar.summaryLabel))
        #expect(isFullyVisible(bar.noteLabel))
        #expect(isFullyVisible(bar.accountLabel))
    }

    /// Al ancho mínimo de la ventana principal (820) solo cede la nota.
    @Test func atMinimumWindowWidthOnlyTheNoteTruncates() {
        let (bar, _) = hostedBar(width: 820)
        #expect(!isFullyVisible(bar.noteLabel))
        #expect(isFullyVisible(bar.summaryLabel))
        #expect(isFullyVisible(bar.accountLabel))
    }

    /// La cuenta nunca queda fuera de la ventana (recortada sin "…"), ni
    /// siquiera si se pide un ancho menor que el contenido.
    @Test(arguments: [300.0, 520.0, 820.0, 1100.0])
    func accountIsNeverClippedByTheWindowEdge(width: CGFloat) {
        let (bar, content) = hostedBar(width: width)
        #expect(isFullyVisible(bar.accountLabel))
        #expect(bar.convert(bar.accountLabel.frame, to: content).maxX <= content.bounds.width + 0.5)
    }

    @Test(arguments: [240.0, 320.0, 480.0])
    func emptyStateSubtitleWrapsInsteadOfClipping(width: CGFloat) {
        let area = SessionAreaView(frame: .zero)
        let content = host(area, width: width, height: 400)
        let subtitle = area.subtitle
        #expect(isFullyVisible(subtitle))
        let inContent = subtitle.convert(subtitle.bounds, to: content)
        #expect(inContent.minX >= 16 - 3)  // tolerancia: padding de la celda
        #expect(inContent.maxX <= content.bounds.width - 16 + 3)
    }

    @Test func narrowEmptyStateSubtitleUsesSeveralLines() {
        let area = SessionAreaView(frame: .zero)
        _ = host(area, width: 240, height: 400)
        let font = area.subtitle.font ?? .systemFont(ofSize: 12)
        #expect(area.subtitle.frame.height > NSLayoutManager().defaultLineHeight(for: font) * 1.5)
    }
}
