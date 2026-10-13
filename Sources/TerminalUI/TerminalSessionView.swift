import AppKit
import Foundation
import SwiftTerm

/// Vista de una sesión de terminal: `TerminalView` (SwiftTerm) conectada a un
/// `TerminalBackend`.
///
/// - Salida remota → `feed(text:)` en el main actor, en orden.
/// - Teclas y cambios de tamaño → una única cola hacia el backend, para que
///   las pulsaciones nunca se reordenen entre sí ni respecto a los resize.
/// - Al cerrarse el backend, la vista queda en solo lectura (`hasEnded`).
///
/// No registra ni expone el contenido de la sesión (REQ-SSH-7).
@MainActor
public final class TerminalSessionView: NSView {
    public let terminalView: TerminalView
    public private(set) var hasEnded = false
    /// Se llama una vez cuando el backend termina (exit remoto o caída).
    public var onEnded: (@MainActor () -> Void)?
    /// Título OSC fijado por el shell remoto (p. ej. `user@host: ~`).
    public var onTitleChange: (@MainActor (String) -> Void)?
    /// GH-64 (REQ-CLOSE-3.2): cuándo llegó la última salida remota y cuándo el
    /// usuario pulsó Enter sobre una línea vacía. Solo marcas de tiempo, nunca
    /// contenido; las usa `SessionCloseConfirmer` (heurística aproximada).
    public internal(set) var lastOutputAt: Date?
    public internal(set) var lastEmptyEnterAt: Date?
    private var typedSinceEnter = false
    /// `TerminalTabManager` ya notificó el fin de esta pestaña.
    var endNotified = false

    private let backend: any TerminalBackend
    private let outbound: AsyncStream<Outbound>.Continuation
    private var pump: Task<Void, Never>?
    private var feeder: Task<Void, Never>?
    private var lastSize: (columns: Int, rows: Int)?

    private enum Outbound: Sendable {
        case data([UInt8])
        case resize(columns: Int, rows: Int)
    }

    public init(backend: any TerminalBackend, frame: NSRect = NSRect(x: 0, y: 0, width: 640, height: 400)) {
        self.backend = backend
        terminalView = TerminalView(frame: NSRect(origin: .zero, size: frame.size))
        let (queue, continuation) = AsyncStream<Outbound>.makeStream()
        outbound = continuation
        super.init(frame: frame)

        terminalView.autoresizingMask = [.width, .height]
        terminalView.terminalDelegate = self
        addSubview(terminalView)

        // Cola única hacia el backend: no captura `self`.
        pump = Task { [backend] in
            for await operation in queue {
                switch operation {
                case .data(let bytes):
                    try? await backend.write(Data(bytes))
                case .resize(let columns, let rows):
                    try? await backend.resize(columns: columns, rows: rows)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Empieza a mostrar la salida remota.
    public func start() {
        guard feeder == nil else { return }
        let output = backend.output
        feeder = Task { [weak self] in
            for await text in output {
                self?.lastOutputAt = Date()
                self?.terminalView.feed(text: text)
            }
            self?.markEnded()
        }
    }

    /// Tamaño actual del terminal en celdas.
    public var terminalSize: (columns: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }

    /// Cierre limpio: deja de enviar, cierra el backend y para la salida.
    public func close() async {
        outbound.finish()
        await backend.close()
        feeder?.cancel()
        markEnded()
    }

    /// Enter (CR) sin nada tecleado desde el anterior = "línea vacía": la salida
    /// que siga es el prompt, no un comando en curso.
    func noteInput(_ data: ArraySlice<UInt8>) {
        for byte in data {
            if byte == 0x0d || byte == 0x0a {
                if !typedSinceEnter { lastEmptyEnterAt = Date() }
                typedSinceEnter = false
            } else {
                typedSinceEnter = true
            }
        }
    }

    private func markEnded() {
        guard !hasEnded else { return }
        hasEnded = true
        outbound.finish()
        onEnded?()
    }
}

// SwiftTerm no anota `TerminalViewDelegate` con `@MainActor`, pero siempre lo
// invoca desde la vista (main thread): `@preconcurrency` lo comprueba en runtime.
extension TerminalSessionView: @preconcurrency TerminalViewDelegate {
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !hasEnded else { return }
        noteInput(data)
        outbound.yield(.data(Array(data)))
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        if let lastSize, lastSize == (newCols, newRows) { return }
        lastSize = (newCols, newRows)
        guard !hasEnded else { return }
        outbound.yield(.resize(columns: newCols, rows: newRows))
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func scrolled(source: TerminalView, position: Double) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// Copia iniciada por el usuario (selección / OSC 52) al portapapeles.
    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
