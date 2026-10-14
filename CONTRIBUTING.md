# Contributing a IAP Desktop Mac

Gracias por tu interés. Este proyecto es una reimplementación nativa para
macOS de [IAP Desktop](https://github.com/GoogleCloudPlatform/iap-desktop)
(Windows); no es un fork y no está afiliado a Google.

## Metodología: spec-driven

Cada área funcional tiene su carpeta en `specs/<área>/` con tres ficheros:

- `requirements.md` — requisitos en formato EARS (WHEN/WHILE/IF… THEN el
  sistema SHALL…), trazables a `REQ-<ÁREA>-N`.
- `design.md` — arquitectura, tipos, flujo de datos, errores tipados.
- `tasks.md` — tareas concretas (`T-<ÁREA>-N`) con test/criterio de
  aceptación y dependencias entre ellas.

Antes de escribir código para una funcionalidad nueva, mira si ya hay una
spec en `specs/`. Si no la hay y el cambio es significativo, propón una
spec primero (PR separado o al principio del mismo PR) — esto evita
retrabajo y hace que la revisión sea más rápida.

Para contexto de por qué algo es como es, consulta también:

- `docs/feature-parity.md` — matriz de paridad funcional con el original
  (qué se implementa, con qué riesgo, en qué milestone).
- `docs/adr/` — decisiones de arquitectura (ADR) ya tomadas: lenguaje de
  UI, transporte del túnel IAP, estrategia RDP, etc. No las reabras sin
  una razón nueva y documentada.

## Antes de abrir un PR

1. **Build y tests en verde:**

   ```bash
   swift build
   swift test
   ```

   Si usas solo CommandLineTools (sin Xcode completo) y `swift test` falla
   con `TestingMacros plugin not found`, es un problema conocido del
   toolchain, no de tu cambio — ver el workaround en
   [`docs/usage.md`](docs/usage.md) §3.

2. **Nunca commitees credenciales reales**: client secrets OAuth, tokens,
   claves privadas, cuentas de servicio, nombres de proyecto/cuenta reales
   en tests o fixtures. Usa placeholders (`__OAUTH_CLIENT_SECRET__`,
   `GOCSPX-fake-…`) o datos sintéticos, como ya hace el resto del repo.
3. **Sigue el estilo existente**: revisa un archivo similar en el mismo
   módulo antes de añadir uno nuevo. El código está en español/castellano
   en comentarios y commits; los identificadores (tipos, funciones) están
   en inglés, siguiendo la convención ya establecida.
4. **PRs pequeños y enfocados**: una tarea (`T-<ÁREA>-N`) o un bug por PR.
   Si tu cambio toca varias áreas sin relación, divídelo.
5. **Actualiza la spec si cambia el comportamiento**: si tu PR hace que
   `requirements.md`/`design.md` queden desactualizados, actualízalos en el
   mismo PR.

## Estructura del repo

```
Sources/<Módulo>/    código de producto (ver tabla de módulos en README.md)
Tests/<Módulo>Tests/ tests (Swift Testing, @Suite/@Test)
specs/<área>/        requirements.md, design.md, tasks.md
docs/                feature-parity.md, adr/, usage.md
tools/               scripts de build, firma, generación de assets
resources/           Info.plist, entitlements, icono
```

## Reportar bugs / proponer features

Abre un issue describiendo:

- Qué esperabas que pasara vs. qué pasó.
- Pasos para reproducir (versión de macOS, Xcode/CLT, comando exacto).
- Si aplica, qué sección de `specs/` o `docs/feature-parity.md` toca.

## Seguridad

Si encuentras una vulnerabilidad (p. ej. una forma de filtrar tokens, de
saltarte la verificación de host key SSH, o un secreto expuesto), **no
abras un issue público**: contacta primero de forma privada a quien
mantiene el repo (ver el perfil de GitHub del organization/owner) para dar
tiempo a mitigarlo antes de hacerlo público.

## Licencia

Al contribuir aceptas que tu contribución se licencie bajo los mismos
términos del proyecto: [Apache License 2.0](LICENSE).
