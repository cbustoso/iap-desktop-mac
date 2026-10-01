// Ámbito del panel de Settings (CBU-53): espejo UI de SettingsScope,
// sin acoplar ExplorerUI a la persistencia.
public enum SettingsPanelScope: Hashable, Sendable {
    case universe
    case project(String)
    case zone(project: String, zone: String)
    case instance(project: String, zone: String, instance: String)
}
