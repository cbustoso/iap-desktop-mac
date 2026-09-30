# Spec Explorer — requirements (EARS)

Ref: `docs/feature-parity.md` §2 · Linear CBU-16 (epic CBU-6). Origen: `Application/ToolWindows/ProjectExplorer/*`, `Core/ProjectModel/*`.

## REQ-EXP-1 — Jerarquía Cloud → Proyecto → Zona → Instancia
- WHEN la app arranca o el usuario refresca THEN el sistema SHALL cargar proyectos vía ResourceManager en paralelo y zonas/instancias vía `instances.aggregatedList` (`returnPartialSuccess=true`).
- El sistema SHALL filtrar instancias sin discos (`Disks==null`) y detectar traits (OS, etc.).
- WHEN un proyecto devuelve 403/404 THEN el sistema SHALL mostrarlo como inaccesible con lista vacía (no fallar todo).

## REQ-EXP-2 — Añadir/eliminar/refrescar
- El usuario SHALL poder añadir proyecto (picker con validación), eliminarlo, refrescar todo o un nodo, abrir en Cloud Console y configurar acceso IAP (deep-link).

## REQ-EXP-3 — Estado y eventos
- Cada instancia SHALL mostrar OS + estado (Running + conectada). El árbol SHALL reaccionar a `SessionStarted/Ended` e `InstanceStateChangedEvent`.

## REQ-EXP-4 — Filtros (paridad estricta)
- El sistema SHALL filtrar por texto de instancia (case-insensitive) y toggles Linux/Windows (a nivel zona, como el original).
- El sistema SHALL persistir proyectos colapsados (equivale a `CollapsedProjects` CSV → `SettingsStore`).
- Favoritos/búsqueda global: fuera de paridad (P2 opcional, no M1).

## Trazabilidad
REQ-EXP-1 → T-EXP-1,2 · REQ-EXP-2 → T-EXP-3,4 · REQ-EXP-3 → T-EXP-5 · REQ-EXP-4 → T-EXP-6.
