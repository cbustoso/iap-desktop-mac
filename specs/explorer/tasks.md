# Spec Explorer — tasks

- [ ] T-EXP-1 `GCPClient`: `listProjects` + `aggregatedListInstances` (parcial, 403/404 tolerados). Test: mock HTTP con proyecto roto. → REQ-1
- [ ] T-EXP-2 `ProjectWorkspace` actor + `TraitDetector`. Test: agrupación por zona + filtro `Disks==null`. → REQ-1
- [ ] T-EXP-3 Picker añadir/eliminar + refresco total/por nodo. UI test. → REQ-2
- [ ] T-EXP-4 Cloud Console + configurar IAP (deep-links). Test: URLs generadas. → REQ-2
- [ ] T-EXP-5 Estados + eventos sesión/VM. Test: cambio de estado actualiza icono. → REQ-3
- [ ] T-EXP-6 Filtros + colapsados persistidos. Test: filtro texto/OS + persistencia. → REQ-4

Secuencia: T-EXP-1 → 2 → 3 → 5 → 6 → 4.
