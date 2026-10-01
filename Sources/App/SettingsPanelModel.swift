// Modelo del panel de Settings (CBU-53): tipos UI puros, sin persistencia.
// La persistencia vive en SettingsStore; el cableado en
// ApplicationSettingsDataSource.
import ExplorerUI
import Foundation

/// Fuente de datos del panel (ámbitos + carga/guardado por ámbito).
/// Ligada al MainActor como su único implementador (UI AppKit).
@MainActor
protocol SettingsPanelDataSource {
    func availableScopes() -> [SettingsPanelScope]
    func loadSettings(at panelScope: SettingsPanelScope) throws -> SettingsPanelSnapshot
    func saveSettings(_ snapshot: SettingsPanelSnapshot) throws
}

/// Foto editable de un ámbito: un campo por descriptor.
struct SettingsPanelSnapshot: Sendable {
    var scope: SettingsPanelScope
    var fields: [SettingsPanelField]
}

/// Un campo con su valor efectivo, el heredado y si hay override local.
struct SettingsPanelField: Sendable, Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var help: String
    var kind: SettingsFieldKind
    var value: SettingsFieldValue
    var inheritedValue: SettingsFieldValue
    var isOverridden: Bool
}

/// Presentación de un campo en el panel.
enum SettingsFieldKind: Sendable, Hashable {
    case text
    case secret
    case integer(ClosedRange<Int>)
    case toggle
}

/// Valor editable de un campo. Los secretos viajan como texto y solo se
/// persisten en Keychain (nunca en logs: no hay CustomStringConvertible).
enum SettingsFieldValue: Sendable, Hashable {
    case text(String)
    case integer(Int)
    case toggle(Bool)
}
