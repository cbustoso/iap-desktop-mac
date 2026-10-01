// La barra de estado en una ventana que NO puede crecer (ancho fijado por el
// usuario): reproduce la captura con "(M" recortado por el borde sin "…".
// El test de CBU-36 alojaba la barra en una ventana que podía crecer y por eso
// no lo detectó.
import AppKit
import Testing
@testable import ExplorerUI

/// Aloja `view` en un contenedor de ancho FIJO (requerido) dentro de una ventana.
@MainActor
private func hostFixed(_ view: NSView, width: CGFloat) -> NSView {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width + 200, height: 100),
        styleMask: [.titled], backing: .buffered, defer: true)
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(container)
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: width),  // no puede crecer
        container.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
        container.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
        container.heightAnchor.constraint(equalToConstant: StatusBarView.height),
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.topAnchor.constraint(equalTo: container.topAnchor),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    window.contentView!.layoutSubtreeIfNeeded()
    return container
}

@MainActor
private func isFullyVisible(_ label: NSTextField) -> Bool {
    label.frame.width + 0.5 >= label.intrinsicContentSize.width
}

@Suite("Status bar con ancho fijo")
@MainActor
struct StatusBarFixedWidthTests {
    /// Textos exactos de la captura del usuario.
    private let summary = "LIVE — 2 proyectos, 3 instancias"
    private let note = "Sin permiso para listar proyectos (403); mostrando 2 añadido(s). File → Add project… para añadir más."

    @Test(arguments: [1100.0, 900.0, 820.0])
    func longNoteNeverPushesTheAccountOffTheBar(width: CGFloat) {
        let bar = StatusBarView(frame: .zero)
        bar.summary = summary
        bar.note = note
        let container = hostFixed(bar, width: width)
        let account = bar.convert(bar.accountLabel.frame, from: bar.accountLabel.superview)
        // La cuenta queda entera y dentro de la barra; cede la nota (con "…").
        #expect(account.maxX <= container.bounds.width + 0.5, "cuenta fuera de la barra a \(width) pt")
        #expect(isFullyVisible(bar.accountLabel))
        #expect(isFullyVisible(bar.summaryLabel))
    }
}

@Suite("Status bar: cuenta y ventana real")
@MainActor
struct StatusBarAccountTests {
    private let note = "Sin permiso para listar proyectos (403); mostrando 2 añadido(s). File → Add project… para añadir más."

    @Test func showsSignedOutByDefaultAndTheEmailWhenSignedIn() {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: []))
        #expect(controller.accountText == "Sin sesión")
        controller.showAccount(email: "ada@example.com")
        #expect(controller.accountText == "ada@example.com")
        #expect(controller.statusBar.accountLabel.toolTip == "ada@example.com")
        controller.showAccount(email: nil)  // logout
        #expect(controller.accountText == "Sin sesión")
        controller.showAccount(email: "   ")
        #expect(controller.accountText == "Sin sesión")
    }

    /// Regresión de la captura: en la ventana real, con la nota larga del 403 y
    /// un email largo, la cuenta queda entera y dentro; cede la nota.
    @Test(arguments: [820.0, 900.0, 1100.0])
    func realWindowKeepsAccountWholeWithLongNote(width: CGFloat) {
        let controller = ExplorerWindowController(viewModel: ExplorerViewModel(projects: []))
        let window = controller.window!
        window.setContentSize(NSSize(width: width, height: 700))
        controller.statusNote = note
        controller.showAccount(email: "cristobal.bustos.long-name@example-company.com")
        window.contentView!.layoutSubtreeIfNeeded()
        let account = controller.statusBar.accountLabel
        let frame = window.contentView!.convert(account.frame, from: account.superview)
        #expect(account.frame.width + 0.5 >= account.intrinsicContentSize.width)
        #expect(frame.maxX <= window.contentView!.bounds.width + 0.5)
    }
}
