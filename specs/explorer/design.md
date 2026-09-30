# Spec Explorer — design

## Arquitectura (`App` + `GCPClient` + `SettingsStore`)

```
ResourceManagerClient ──┐
ComputeClient (aggregatedList) ──┴→ ProjectWorkspace (actor, caché) → ExplorerViewModel (@Observable)
→ SwiftUI OutlineGroup (fallback NSOutlineView si rendimiento) → Detail panels
```

- `ProjectWorkspace` (actor): `root()`, `zones(project)`, `node(locator)`, `setActive`; caché con `AsyncLock` Swift (`SerialActor`); precarga zonas en paralelo (`TaskGroup`).
- `ExplorerViewModel`: `filterText`, `showLinux/showWindows`, `collapsedProjects` (persistido en `SettingsStore`), `selectedNode`; filtrado en memoria idéntico al original (texto a nivel nodo, OS a nivel zona).
- `GCPClient`: `listProjects`, `aggregatedListInstances(project)` con `returnPartialSuccess`; `TraitDetector` (Windows/Linux por `disks[].licenses`, guestOsFeatures).
- Errores: proyecto inaccesible → nodo `.unreachable(403/404)` con reintento.
- Concurrencia: `TaskGroup` para proyectos; UI solo lee snapshots `Sendable`.
