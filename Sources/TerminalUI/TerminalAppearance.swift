import AppKit
import Foundation
import SwiftTerm

// GH-82: legibilidad del terminal. SwiftTerm, por defecto, pinta el texto en
// gris al ~54 % sobre el fondo del sistema y con la paleta "Terminal.app"
// apagada: se ve pálido frente a Terminal.app. Aquí se fija un tema explícito
// (paleta de 16 colores + primer plano/fondo/cursor/selección), la fuente mono
// del sistema y un relleno alrededor de la rejilla.

/// Color sRGB de 8 bits por canal (valor puro, comparable en tests).
public struct TerminalRGB: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xff), UInt8((hex >> 8) & 0xff), UInt8(hex & 0xff))
    }

    public var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// Color del motor SwiftTerm (16 bits por canal: `v * 257` es exacto).
    public var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }

    /// Luminancia relativa WCAG 2.x.
    public var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Ratio de contraste WCAG entre dos colores (1...21).
    public func contrastRatio(against other: TerminalRGB) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Temas disponibles. `rawValue` es lo que se persiste en Settings.
public enum TerminalThemeID: String, CaseIterable, Codable, Sendable {
    /// Oscuro de alto contraste: fondo negro puro, ANSI brillantes.
    case pro
    /// Claro: fondo blanco, ANSI oscurecidos para que se lean sobre blanco.
    case light

    public static let defaultValue: TerminalThemeID = .pro

    public var displayName: String {
        switch self {
        case .pro: "Pro (oscuro)"
        case .light: "Claro"
        }
    }

    public var theme: TerminalTheme {
        switch self {
        case .pro: .pro
        case .light: .light
        }
    }
}

/// Paleta completa de un tema.
public struct TerminalTheme: Equatable, Sendable {
    public let id: TerminalThemeID
    public let foreground: TerminalRGB
    public let background: TerminalRGB
    public let cursor: TerminalRGB
    public let selection: TerminalRGB
    /// 16 colores ANSI: 0-7 normales, 8-15 brillantes.
    public let ansi: [TerminalRGB]

    public var isDark: Bool { background.relativeLuminance < 0.5 }

    /// Alto contraste sobre negro puro. Los normales ya son vivos; los
    /// brillantes (que SwiftTerm usa también para el texto en negrita con
    /// color) suben casi al máximo, para que la negrita se distinga.
    public static let pro = TerminalTheme(
        id: .pro,
        foreground: TerminalRGB(hex: 0xF2F2F2),
        background: TerminalRGB(hex: 0x000000),
        cursor: TerminalRGB(hex: 0xFFFFFF),
        selection: TerminalRGB(hex: 0x3A4F7A),
        ansi: [
            TerminalRGB(hex: 0x000000), TerminalRGB(hex: 0xE5484D),
            TerminalRGB(hex: 0x3FD24F), TerminalRGB(hex: 0xE5C02B),
            TerminalRGB(hex: 0x4A8DFF), TerminalRGB(hex: 0xD45BE0),
            TerminalRGB(hex: 0x2CC7D6), TerminalRGB(hex: 0xD9D9D9),
            TerminalRGB(hex: 0x808080), TerminalRGB(hex: 0xFF6E6E),
            TerminalRGB(hex: 0x6EFF7A), TerminalRGB(hex: 0xFFF06E),
            TerminalRGB(hex: 0x7FB2FF), TerminalRGB(hex: 0xFF8CFF),
            TerminalRGB(hex: 0x6EF5FF), TerminalRGB(hex: 0xFFFFFF),
        ])

    /// Claro: texto casi negro y ANSI oscurecidos (amarillo/cian ilegibles
    /// sobre blanco en la paleta clásica).
    public static let light = TerminalTheme(
        id: .light,
        foreground: TerminalRGB(hex: 0x111111),
        background: TerminalRGB(hex: 0xFFFFFF),
        cursor: TerminalRGB(hex: 0x000000),
        selection: TerminalRGB(hex: 0xB4D5FE),
        ansi: [
            TerminalRGB(hex: 0x000000), TerminalRGB(hex: 0xB3141A),
            TerminalRGB(hex: 0x1C7A24), TerminalRGB(hex: 0x8A6A00),
            TerminalRGB(hex: 0x1F4FC2), TerminalRGB(hex: 0x8E2C9A),
            TerminalRGB(hex: 0x0E7480), TerminalRGB(hex: 0x6E6E6E),
            TerminalRGB(hex: 0x545454), TerminalRGB(hex: 0xD62A2F),
            TerminalRGB(hex: 0x24942E), TerminalRGB(hex: 0xA68000),
            TerminalRGB(hex: 0x2F66E0), TerminalRGB(hex: 0xA93DB8),
            TerminalRGB(hex: 0x128A98), TerminalRGB(hex: 0x2B2B2B),
        ])
}

/// Aspecto efectivo de una pestaña de terminal.
public struct TerminalAppearance: Equatable, Sendable {
    public static let fontSizeRange = 8...72
    public static let defaultFontSize = 13
    /// Nombre que selecciona la fuente mono del sistema (SF Mono).
    public static let systemMonospacedFamily = "SF Mono"
    /// Relleno (puntos) entre el borde de la pestaña y la rejilla.
    public static let padding: CGFloat = 8

    /// Familia pedida; `nil`/vacía = SF Mono.
    public var fontFamily: String?
    public var fontSize: Int {
        didSet { fontSize = Self.clamp(fontSize) }
    }
    public var themeID: TerminalThemeID

    public init(
        fontFamily: String? = nil,
        fontSize: Int = TerminalAppearance.defaultFontSize,
        themeID: TerminalThemeID = .defaultValue
    ) {
        self.fontFamily = fontFamily
        self.fontSize = Self.clamp(fontSize)
        self.themeID = themeID
    }

    public static let `default` = TerminalAppearance()

    public var theme: TerminalTheme { themeID.theme }

    static func clamp(_ size: Int) -> Int {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// Fuente a usar: la familia pedida si existe y es de ancho fijo; si no,
    /// SF Mono (`monospacedSystemFont`); Menlo si aquella no estuviera.
    /// Una familia proporcional descuadraría la rejilla, así que se descarta.
    public func resolvedFont() -> NSFont {
        let size = CGFloat(fontSize)
        if let family = fontFamily?.trimmingCharacters(in: .whitespaces), !family.isEmpty,
            family.caseInsensitiveCompare(Self.systemMonospacedFamily) != .orderedSame,
            let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? NSFont(name: family, size: size),
            font.isFixedPitch
        {
            return font
        }
        return Self.systemMonospacedFont(size: size)
    }

    static func systemMonospacedFont(size: CGFloat) -> NSFont {
        let system = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if system.isFixedPitch { return system }
        return NSFont(name: "Menlo-Regular", size: size) ?? system
    }
}

/// Persistencia del aspecto en el mismo formato que `UserDefaultsSettingsStore`
/// (valor JSON en `Data` por clave), para que el panel de Settings y el
/// terminal lean y escriban las mismas claves (`TerminalFontFamily`,
/// `TerminalFontSize`, `TerminalTheme`).
///
/// Solo valores no sensibles: familia, tamaño y tema.
@MainActor
public final class TerminalAppearanceStore {
    public static let fontFamilyKey = "TerminalFontFamily"
    public static let fontSizeKey = "TerminalFontSize"
    public static let themeKey = "TerminalTheme"
    /// Suite de settings de nivel "universe" del perfil por defecto (mismo
    /// nombre que `ProfileEnvironment.settingsSuite(component: "universe")`).
    public static let defaultSuiteName = "com.iapdesktop.mac.settings.universe"

    /// Se publica tras cada `save` (en el main actor).
    public static let didChangeNotification = Notification.Name("TerminalAppearanceStore.didChange")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public convenience init(suiteName: String = TerminalAppearanceStore.defaultSuiteName) {
        self.init(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    /// Aspecto guardado; claves ausentes o ilegibles caen al valor por defecto.
    public func load() -> TerminalAppearance {
        let family: String? = value(forKey: Self.fontFamilyKey)
        let size: Int? = value(forKey: Self.fontSizeKey)
        let theme = (value(forKey: Self.themeKey) as String?).flatMap(TerminalThemeID.init(rawValue:))
        return TerminalAppearance(
            fontFamily: family,
            fontSize: size ?? TerminalAppearance.defaultFontSize,
            themeID: theme ?? .defaultValue)
    }

    public func save(_ appearance: TerminalAppearance) {
        set(appearance.fontSize, forKey: Self.fontSizeKey)
        set(appearance.themeID.rawValue, forKey: Self.themeKey)
        if let family = appearance.fontFamily, !family.isEmpty {
            set(family, forKey: Self.fontFamilyKey)
        } else {
            defaults.removeObject(forKey: Self.fontFamilyKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Lee el formato de `UserDefaultsSettingsStore` (JSON en `Data`) y, por
    /// tolerancia, un valor plano del mismo tipo.
    private func value<Value: Decodable>(forKey key: String) -> Value? {
        if let data = defaults.data(forKey: key) {
            return try? JSONDecoder().decode(Value.self, from: data)
        }
        return defaults.object(forKey: key) as? Value
    }

    private func set<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

extension TerminalView {
    /// Aplica tema y fuente. Instala la paleta ANSI después de primer
    /// plano/fondo: SwiftTerm recalcula la tabla de 256 colores con ellos.
    @MainActor
    func apply(_ terminalAppearance: TerminalAppearance) {
        let theme = terminalAppearance.theme
        let font = terminalAppearance.resolvedFont()
        if font != self.font { self.font = font }
        nativeForegroundColor = theme.foreground.nsColor
        nativeBackgroundColor = theme.background.nsColor
        layer?.backgroundColor = theme.background.nsColor.cgColor
        caretColor = theme.cursor.nsColor
        selectedTextBackgroundColor = theme.selection.nsColor
        // Negrita con color → variante brillante, y además fuente bold.
        useBrightColors = true
        // Box-drawing (U+2500-257F) y bloques (U+2580-259F) dibujados como
        // trazos alineados a la celda: líneas continuas en `pstree`/`tree`
        // aunque la fuente no tenga el glifo o deje huecos entre filas.
        customBlockGlyphs = true
        installColors(theme.ansi.map(\.terminalColor))
        // Scroller y controles nativos acordes al tema.
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }
}
