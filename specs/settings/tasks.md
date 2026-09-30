# Spec Settings — tasks (→ issues Linear)

- [ ] T-SET-1 `Setting<T>` + `SettingsStore` protocolo + `MergedSettingsStore`
      (overlay/policy, matriz especificado×válido). Depende de: nada. Test: portar la
      matriz de casos de `MergedSettingsStore` (4 combinaciones overlay + 2 de policy) +
      `clear()` lanza `mergedStoreNotClearable`. Criterio: cero lógica de persistencia
      real en este target (solo estructuras + fusión in-memory). → REQ-1
- [ ] T-SET-2 `UserDefaultsSettingsStore` + `KeychainSettingsStore` (secretos nunca en
      `UserDefaults`/logs). Depende de: T-SET-1. Test: round-trip UserDefaults efímero +
      round-trip Keychain (keychain de test, paridad `KeychainStoreTests` de `AuthKit`).
      Criterio: `KeychainSettingsStore.write` de un valor sensible no aparece en
      `UserDefaults`. → REQ-2,7
- [ ] T-SET-3 `MDMSettingsStore` (solo lectura, managed preferences) + composición
      `MergedSettingsStore([user, mdm], .policy)` + `isPolicyPresent`. Depende de:
      T-SET-1, T-SET-2. Test: mock de managed preferences con/sin política, assert
      `isReadOnly` y `write` ignorado en la capa MDM. → REQ-2
- [ ] T-SET-4 `SettingsRepository` (actor): `universeStore/projectStore/zoneStore/
      instanceStore` en cascada `.overlay`, reutilizando `ProjectLocator/ZoneLocator/
      InstanceLocator` de `ExplorerUI`. Depende de: T-SET-1, T-SET-2. Test: 4 niveles con
      valores intercalados (solo Universo, Universo+Zona, los 4 niveles) verifican
      resolución en cascada y que escribir en un nivel no afecta a otros. → REQ-3,4
- [ ] T-SET-5 Overlay efímero de URL (`ephemeralOverlay`, paridad
      `IapRdpUrlSettingsStore`) sin persistir. Depende de: T-SET-4. Test: overlay sobre
      instancia existente vs instancia no encontrada (fallback solo-URL). → REQ-3,4
- [ ] T-SET-6 Esquema `ConnectionSettings` (RDP ~24 + SSH ~6 + App ~2) con enums
      congelados (`RdpColorDepth`, `RdpTransport`, `RdpRedirect*`, etc. en `RDPBridge`;
      `SshTransport`/`SshPublicKeyAuthentication` en `SSHKit`). Depende de: T-SET-1.
      Test: cada setting expone key/category/default estables; validadores de rango
      (puerto, timeout) rechazan valores fuera de rango. Criterio: ningún enum usa
      `default:` que oculte un caso no migrado. → REQ-5
- [ ] T-SET-7 Esquema `SshPlatformSettings` (~5, paridad `SshSettingsRepository`:
      `publicKeyValidity/publicKeyType/usePersistentKey/enableLocalePropagation/
      enableFileAccess`). Depende de: T-SET-1, T-SET-6 (comparte `SshKeyType`). Test:
      default de `publicKeyType` condicionado por `SettingsSchemaVersion` (T-SET-9). →
      REQ-5
- [ ] T-SET-8 Esquema `TerminalSettings` (~11: copy/paste, scroll, fuente, colores ARGB,
      `CaretStyle`). Depende de: T-SET-1. Test: `fontFamily` valida fuente monoespaciada
      disponible; `fontSize`/colores validan rango. → REQ-5
- [ ] T-SET-9 `SettingsSchemaVersion` (enum congelado) + migración de defaults sin tocar
      perfiles existentes (ejemplo: `SshKeyType` default RSA-3072 → ECDSA P-384). Depende
      de: T-SET-6, T-SET-7. Test: perfil creado en esquema N conserva default antiguo;
      perfil nuevo usa default de esquema N+1; valor persistido con caso retirado del
      enum lanza `unknownEnumValue` (no default silencioso). → REQ-6
- [ ] T-SET-10 Redacción de secretos en OSLog al volcar `ISettingsCollection` para
      diagnóstico + auditoría "sin passwords en logs". Depende de: T-SET-2. Test: assert
      sobre formateo/dump, paridad `T-AUTH-9`. → REQ-7

Secuencia: T-SET-1 → 2 → 3 → 4 → 5; en paralelo (tras T-SET-1) → 6 → 7 → 9, 8 → 9; 10 en
paralelo tras T-SET-2. No bloquea a `specs/ssh`/`specs/tunnel`: solo consume los enums
que esos módulos ya definen (`SshKeyType`, `SessionTransportType`).
