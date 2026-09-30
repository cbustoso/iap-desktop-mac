# Spec Auth — requirements (EARS)

Ref: `docs/feature-parity.md` §1 · ADR-0001 · Linear CBU-15 (epic CBU-5).

## REQ-AUTH-1 — OAuth installed-app + PKCE loopback
- WHEN el usuario inicia sesión THEN el sistema SHALL abrir `ASWebAuthenticationSession` contra `https://oauth2.googleapis.com/` con PKCE S256 (`code_verifier` 43–128 chars, `code_challenge = BASE64URL(SHA256(verifier))`).
- WHEN el IdP redirige THEN el sistema SHALL escuchar en loopback `http://127.0.0.1:{puerto-efímero}/authorize/` (preferir `127.0.0.1` sobre `localhost` por coherencia IPv4/IPv6) y extraer `code`.
- WHEN recibe `code` THEN el sistema SHALL intercambiarlo en `POST /token` y almacenar `refresh_token + id_token` solo en Keychain.
- El sistema SHALL pedir scope mínimo `Cloud` y ampliar a `Cloud+Email` solo si el servidor exige consentimiento adicional (evita consent-unbundling, cf. `GaiaOidcClient`).

## REQ-AUTH-2 — Multi-cuenta (una activa, splice sin romper clientes)
- WHILE existe una sesión activa y el usuario cambia de cuenta THEN el sistema SHALL hacer `splice` (copiar nuevo token en la fachada existente, no reemplazar el objeto) y emitir evento `Reauthorized` para que `GCPClient` refresque sin romper sockets.
- WHEN cambia el issuer Gaia↔STS THEN el sistema SHALL descartar la credencial offline anterior.

## REQ-AUTH-3 — Revocación y logout
- WHEN el usuario cierra sesión THEN el sistema SHALL llamar `POST /revoke`, borrar Keychain y notificar `Reauthorized`.

## REQ-AUTH-4 — WIF (M4, fuera de M1 pero diseñado ahora)
- El sistema SHALL soportar issuer STS (`https://sts.googleapis.com/`), flujo auth-portal, `IntrospectToken` y `principal://…` → identidad workforce. OS Login SHALL rechazar sesiones workforce con error tipado.

## REQ-AUTH-5 — mTLS/proxy (M4, degradación v1)
- WHEN no hay identidad de dispositivo macOS THEN el sistema SHALL degradar a endpoint público y registrar el motivo (sin fallo).
- El sistema SHALL respetar el proxy del sistema (`CFNetworkCopyProxiesForURL` + PAC) para `https://oauth2/sts` y `wss://` (HTTP CONNECT). NTLM fuera de alcance.

## REQ-AUTH-6 — Seguridad y observabilidad
- El sistema SHALL NOT escribir tokens en disco plano ni en logs. OSLog SHALL redactar tokens.
- Todo acceso a credenciales SHALL pasar por `CredentialFacade` (actor).

## Trazabilidad
REQ-AUTH-1 → T-AUTH-1..4 · REQ-AUTH-2 → T-AUTH-5 · REQ-AUTH-3 → T-AUTH-6 · REQ-AUTH-4 → T-AUTH-7 (M4) · REQ-AUTH-5 → T-AUTH-8 (M4) · REQ-AUTH-6 → todos + tests T-AUTH-9.
