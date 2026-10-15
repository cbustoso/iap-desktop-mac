// GH-82: legibilidad del terminal (tema Pro/claro, fuente, tamaño persistido,
// box-drawing/Unicode). Headless: sin conexión, ventana fuera de pantalla.
import AppKit
import CoreText
import Foundation
import SwiftTerm
import Testing
@testable import ExplorerUI
@testable import TerminalUI

/// Backend sin remoto: el test empuja salida.
/// `@unchecked Sendable`: estado mutable bajo `lock`.
private final class PushBackend: TerminalBackend, @unchecked Sendable {
    let output: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var resizes: [Int] = []

    init() { (output, continuation) = AsyncStream<String>.makeStream() }

    func push(_ text: String) { continuation.yield(text) }
    var resizedColumns: [Int] { lock.withLock { resizes } }

    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int) async throws { lock.withLock { resizes.append(columns) } }
    func close() async { continuation.finish() }
}

/// Suite de UserDefaults desechable (nunca toca los settings reales).
@MainActor
private func scratchStore() -> (TerminalAppearanceStore, UserDefaults, String) {
    let suite = "com.iapdesktop.mac.tests.terminal-appearance.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (TerminalAppearanceStore(defaults: defaults), defaults, suite)
}

@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private func hosted(_ view: NSView, size: NSSize = NSSize(width: 640, height: 400)) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    view.frame = NSRect(origin: .zero, size: size)
    view.autoresizingMask = [.width, .height]
    window.contentView = view
    return window
}

private func rgb(_ color: SwiftTerm.Color) -> [UInt16] { [color.red, color.green, color.blue] }

// MARK: - Temas

@Suite("Temas del terminal (GH-82)")
struct TerminalThemeTests {
    @Test func proIsPureBlackWithHighContrastText() {
        let pro = TerminalTheme.pro
        #expect(pro.background == TerminalRGB(0, 0, 0))
        #expect(pro.isDark)
        #expect(pro.ansi.count == 16)
        // Texto principal: muy por encima de WCAG AAA (7:1).
        #expect(pro.foreground.contrastRatio(against: pro.background) >= 15)
        // Colores ANSI (salvo negro) legibles sobre negro (AA, 4.5:1).
        for index in 1..<16 where index != 8 {
            #expect(pro.ansi[index].contrastRatio(against: pro.background) >= 4.5, "ANSI \(index)")
        }
    }

    @Test func proBrightVariantsAreBrighterThanNormals() {
        // Negrita con color = variante brillante: debe distinguirse.
        let ansi = TerminalTheme.pro.ansi
        for index in 0..<8 {
            #expect(ansi[index + 8].relativeLuminance > ansi[index].relativeLuminance, "ANSI \(index)")
        }
    }

    @Test func lightThemeIsReadableOnWhite() {
        let light = TerminalTheme.light
        #expect(light.background == TerminalRGB(255, 255, 255))
        #expect(!light.isDark)
        #expect(light.ansi.count == 16)
        #expect(light.foreground.contrastRatio(against: light.background) >= 15)
        for index in 1..<7 {
            #expect(light.ansi[index].contrastRatio(against: light.background) >= 4.5, "ANSI \(index)")
            #expect(light.ansi[index + 8].contrastRatio(against: light.background) >= 3, "ANSI \(index + 8)")
        }
    }

    @Test func themeIDsRoundTripAndDefaultToPro() {
        #expect(TerminalThemeID.defaultValue == .pro)
        for id in TerminalThemeID.allCases {
            #expect(TerminalThemeID(rawValue: id.rawValue) == id)
            #expect(id.theme.id == id)
        }
    }

    @Test func rgbMapsExactlyToTerminalColor() {
        #expect(rgb(TerminalRGB(hex: 0xFF8000).terminalColor) == [65535, 32896, 0])
    }
}

// MARK: - Fuente

@Suite("Fuente del terminal (GH-82)")
@MainActor
struct TerminalFontTests {
    @Test func defaultIsSystemMonospacedAtThirteen() {
        let font = TerminalAppearance.default.resolvedFont()
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 13)
        #expect(font == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    @Test func sfMonoNameSelectsSystemMonospaced() {
        let font = TerminalAppearance(fontFamily: "SF Mono", fontSize: 15).resolvedFont()
        #expect(font == NSFont.monospacedSystemFont(ofSize: 15, weight: .regular))
    }

    @Test func installedMonospacedFamilyIsHonored() {
        let font = TerminalAppearance(fontFamily: "Menlo", fontSize: 14).resolvedFont()
        #expect(font.familyName == "Menlo")
        #expect(font.pointSize == 14)
    }

    @Test(arguments: ["Helvetica", "No Such Font 123", "  "])
    func proportionalOrMissingFamilyFallsBackToMonospaced(family: String) {
        let font = TerminalAppearance(fontFamily: family).resolvedFont()
        #expect(font.isFixedPitch)
    }

    @Test func fontSizeIsClampedToSettingsRange() {
        #expect(TerminalAppearance(fontSize: 2).fontSize == 8)
        #expect(TerminalAppearance(fontSize: 500).fontSize == 72)
        var appearance = TerminalAppearance(fontSize: 72)
        appearance.fontSize += 1
        #expect(appearance.fontSize == 72)
    }

    /// Fallback de glifos: para cada muestra hay una fuente (la mono o la de
    /// cascada de CoreText) con glifo real, así que no salen "tofu".
    @Test(arguments: ["├─┬─┐", "└──┘│", "▀▄█░▒▓", "✓✗→←↑↓", "λ é ñ ß", "日本語", "⏎ ⌘ ⌥"])
    func everySampleHasARenderableGlyph(sample: String) {
        let base = TerminalAppearance.default.resolvedFont() as CTFont
        for scalar in sample.unicodeScalars where scalar != " " {
            let text = String(scalar) as CFString
            let font = CTFontCreateForString(base, text, CFRange(location: 0, length: CFStringGetLength(text)))
            var chars = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            let found = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
            #expect(found && glyphs.allSatisfy { $0 != 0 }, "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    }
}

// MARK: - Persistencia

@Suite("Persistencia del aspecto (GH-82)", .serialized)
@MainActor
struct TerminalAppearancePersistenceTests {
    @Test func emptyStoreYieldsDefaults() {
        let (store, _, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(store.load() == .default)
    }

    @Test func savedAppearanceSurvivesANewStore() {
        let (store, defaults, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.save(TerminalAppearance(fontFamily: "Menlo", fontSize: 18, themeID: .light))

        let reopened = TerminalAppearanceStore(defaults: UserDefaults(suiteName: suite)!)
        #expect(reopened.load() == TerminalAppearance(fontFamily: "Menlo", fontSize: 18, themeID: .light))
        // Mismo formato que `UserDefaultsSettingsStore`: JSON en `Data`.
        #expect(defaults.data(forKey: "TerminalFontSize") == Data("18".utf8))
        #expect(defaults.data(forKey: "TerminalTheme") == Data("\"light\"".utf8))
    }

    @Test func readsValuesWrittenBySettingsPanel() throws {
        let (store, defaults, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(20), forKey: TerminalAppearanceStore.fontSizeKey)
        defaults.set(try JSONEncoder().encode("Menlo"), forKey: TerminalAppearanceStore.fontFamilyKey)
        #expect(store.load() == TerminalAppearance(fontFamily: "Menlo", fontSize: 20, themeID: .pro))
    }

    @Test func invalidStoredValuesFallBackToDefaults() {
        let (store, defaults, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set(Data("\"neon\"".utf8), forKey: TerminalAppearanceStore.themeKey)
        defaults.set(Data("not json".utf8), forKey: TerminalAppearanceStore.fontSizeKey)
        defaults.set(Data("400".utf8), forKey: "unrelated")
        #expect(store.load() == .default)

        defaults.set(Data("400".utf8), forKey: TerminalAppearanceStore.fontSizeKey)
        #expect(store.load().fontSize == 72)
    }

    @Test func clearingFamilyRemovesTheKey() {
        let (store, defaults, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.save(TerminalAppearance(fontFamily: "Menlo"))
        store.save(TerminalAppearance(fontFamily: nil))
        #expect(defaults.object(forKey: TerminalAppearanceStore.fontFamilyKey) == nil)
    }
}

// MARK: - Vista y pestañas

@Suite("Aspecto aplicado a la vista (GH-82)", .serialized)
@MainActor
struct TerminalAppearanceViewTests {
    @Test func viewAppliesProThemeColorsAndFont() async {
        let view = TerminalSessionView(backend: PushBackend())
        let window = hosted(view)
        let terminal = view.terminalView.getTerminal()
        #expect(rgb(terminal.backgroundColor) == [0, 0, 0])
        #expect(rgb(terminal.foregroundColor) == rgb(TerminalTheme.pro.foreground.terminalColor))
        #expect(view.terminalView.font == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(view.terminalView.useBrightColors)
        #expect(view.terminalView.customBlockGlyphs)
        window.close()
        await view.close()
    }

    @Test func switchingThemeRecolorsTheView() async {
        let view = TerminalSessionView(backend: PushBackend())
        let window = hosted(view)
        view.selectTheme(.light)
        let terminal = view.terminalView.getTerminal()
        #expect(view.terminalAppearance.themeID == .light)
        #expect(rgb(terminal.backgroundColor) == [65535, 65535, 65535])
        #expect(rgb(terminal.foregroundColor) == rgb(TerminalTheme.light.foreground.terminalColor))
        #expect(view.terminalView.appearance?.name == .aqua)
        window.close()
        await view.close()
    }

    @Test func gridIsInsetByPadding() async {
        let view = TerminalSessionView(backend: PushBackend())
        let window = hosted(view)
        let padding = TerminalAppearance.padding
        #expect(view.terminalView.frame == view.bounds.insetBy(dx: padding, dy: padding))
        window.close()
        await view.close()
    }

    @Test func biggerFontMeansFewerColumnsAndResizesThePty() async {
        let backend = PushBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view)
        view.start()
        let before = view.terminalSize.columns

        view.changeFontSize(by: 6)
        #expect(view.terminalAppearance.fontSize == 19)
        #expect(view.terminalView.font.pointSize == 19)
        view.layoutSubtreeIfNeeded()
        let after = view.terminalSize.columns
        #expect(after < before)
        #expect(await eventually { backend.resizedColumns.last == after })
        window.close()
        await view.close()
    }

    @Test func boxDrawingAndWideCharactersKeepTheGrid() async {
        let backend = PushBackend()
        let view = TerminalSessionView(backend: backend)
        let window = hosted(view)
        view.start()
        backend.push("systemd─┬─sshd───bash\r\n        └─cron\r\n日本x\r\n")
        let terminal = view.terminalView.getTerminal()
        #expect(await eventually { terminal.getCharData(col: 0, row: 2).map { terminal.getCharacter(for: $0) } == "日" })
        // Una celda por trazo de box-drawing: las columnas de `pstree` cuadran.
        #expect(terminal.getCharacter(for: terminal.getCharData(col: 7, row: 0)!) == "─")
        #expect(terminal.getCharacter(for: terminal.getCharData(col: 8, row: 0)!) == "┬")
        #expect(terminal.getCharacter(for: terminal.getCharData(col: 8, row: 1)!) == "└")
        // CJK ocupa dos celdas.
        #expect(terminal.getCharData(col: 0, row: 2)?.width == 2)
        #expect(terminal.getCharacter(for: terminal.getCharData(col: 2, row: 2)!) == "本")
        #expect(terminal.getCharacter(for: terminal.getCharData(col: 4, row: 2)!) == "x")
        window.close()
        await view.close()
    }

    /// Snapshot headless: se renderiza la vista a un bitmap y se muestrean
    /// píxeles (fondo del tema y un bloque rojo ANSI).
    @Test(arguments: TerminalThemeID.allCases)
    func headlessSnapshotUsesThemeColors(themeID: TerminalThemeID) async throws {
        let backend = PushBackend()
        let view = TerminalSessionView(backend: backend, appearance: TerminalAppearance(fontSize: 20, themeID: themeID))
        let window = hosted(view)
        view.start()
        backend.push("\u{1b}[31m████████\u{1b}[0m\r\n")
        let terminal = view.terminalView.getTerminal()
        #expect(await eventually { terminal.getCharData(col: 7, row: 0).map { terminal.getCharacter(for: $0) } == "█" })
        view.layoutSubtreeIfNeeded()
        view.terminalView.needsDisplay = true

        let bounds = view.bounds
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: rep)
        let theme = themeID.theme

        func pixel(_ x: Int, _ y: Int) -> TerminalRGB? {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return TerminalRGB(
                UInt8((color.redComponent * 255).rounded()), UInt8((color.greenComponent * 255).rounded()),
                UInt8((color.blueComponent * 255).rounded()))
        }
        // La gestión de color de AppKit desplaza unos pocos niveles cada
        // canal: se clasifica cada píxel por el color más cercano del tema.
        let palette = [theme.background, theme.foreground] + theme.ansi
        func nearest(_ x: Int, _ y: Int) -> TerminalRGB? {
            guard let p = pixel(x, y) else { return nil }
            func distance(_ c: TerminalRGB) -> Int {
                let (dr, dg, db) = (Int(p.red) - Int(c.red), Int(p.green) - Int(c.green), Int(p.blue) - Int(c.blue))
                return dr * dr + dg * dg + db * db
            }
            return palette.min { distance($0) < distance($1) }
        }
        // Relleno y zona sin texto (abajo a la derecha): fondo del tema.
        #expect(nearest(2, 2) == theme.background)
        #expect(nearest(rep.pixelsWide - 40, rep.pixelsHigh - 20) == theme.background)
        // Algún píxel de la primera fila es rojo del tema (normal o brillante:
        // el desplazamiento de color puede acercarlo a cualquiera de los dos).
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let rowY = Int((TerminalAppearance.padding + 10) * scale)
        let redFound = stride(from: 0, to: rep.pixelsWide / 2, by: 2).contains {
            [theme.ansi[1], theme.ansi[9]].contains(nearest($0, rowY))
        }
        #expect(redFound)
        window.close()
        await view.close()
    }
}

@Suite("Aspecto compartido entre pestañas (GH-82)", .serialized)
@MainActor
struct TerminalAppearanceTabTests {
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

    @Test func changeInOneTabIsPersistedAndAppliedToAll() async {
        let (store, _, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let tabs = TerminalTabManager(host: explorer().sessionTabs, appearanceStore: store)
        let first = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: PushBackend())
        let second = tabs.open(instanceID: "p/z/vm-2", title: "vm-2", backend: PushBackend())

        first.changeFontSize(by: 2)
        first.selectTheme(.light)
        let expected = TerminalAppearance(fontSize: 15, themeID: .light)
        #expect(store.load() == expected)
        #expect(second.terminalAppearance == expected)
        #expect(second.terminalView.font.pointSize == 15)
        await tabs.closeAll()
    }

    @Test func newTabsReadTheStoredAppearance() async {
        let (store, _, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.save(TerminalAppearance(fontSize: 16, themeID: .light))
        let tabs = TerminalTabManager(host: explorer().sessionTabs, appearanceStore: store)
        let view = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: PushBackend())
        #expect(view.terminalAppearance == TerminalAppearance(fontSize: 16, themeID: .light))

        // Cambio hecho fuera (panel de Settings) + recarga explícita.
        store.save(TerminalAppearance(fontSize: 11))
        tabs.reloadAppearance()
        #expect(view.terminalAppearance.fontSize == 11)
        #expect(view.terminalAppearance.themeID == .pro)
        await tabs.closeAll()
    }

    @Test func keyEquivalentsChangeSizeOnlyWithTerminalFocused() async throws {
        let (store, _, suite) = scratchStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let tabs = TerminalTabManager(host: explorer().sessionTabs, appearanceStore: store)
        let view = tabs.open(instanceID: "p/z/vm-1", title: "vm-1", backend: PushBackend())
        let window = hosted(view)

        func command(_ key: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
        }
        window.makeFirstResponder(nil)
        #expect(!view.performKeyEquivalent(with: try command("=")))
        #expect(store.load().fontSize == 13)

        window.makeFirstResponder(view.terminalView)
        #expect(view.performKeyEquivalent(with: try command("=")))
        #expect(view.performKeyEquivalent(with: try command("+")))
        #expect(store.load().fontSize == 15)
        #expect(view.performKeyEquivalent(with: try command("-")))
        #expect(store.load().fontSize == 14)
        #expect(view.performKeyEquivalent(with: try command("0")))
        #expect(store.load().fontSize == 13)
        window.close()
        await tabs.closeAll()
    }
}
