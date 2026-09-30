# Spec Auth — design

Ref: requirements.md · `GaiaOidcClient`, `LoopbackCodeReceiver`, `Authorization.Splice` (origen C#).

## Arquitectura (`AuthKit`)

```
ASWebAuthenticationSession
  → LoopbackReceiver (NWListener, 127.0.0.1:0, path /authorize/)
  → TokenClient (URLSession, POST /token, /revoke)
  → CredentialFacade (actor, @Observable) → KeychainStore → GCPClient interceptor
```

- `CredentialFacade`: único punto de verdad. `authorize()`, `splice(_:)`, `revoke()` (best-effort contra `/revoke` vía `RevokeClient`, siempre limpia y emite), `storeRefreshed` (exige sesión, guarda refresh rotado), `validAccessToken()` (el refresh automático llega en T-AUTH-4). Emite `Reauthorized` vía `AsyncStream(bufferingNewest(1))`.
- Errores: `AuthError` incluye `network(String)` (transporte) e `invalidResponse`; `consentRequired`/`workforceNotSupported` se producen en T-AUTH-4/M4.
- `KeychainStore`: `kSecClassGenericPassword`, servicio `com.iap-mac.auth`, cuentas `<issuer>:<email>`; guarda `{refresh, idToken, scopes, issuedAt}`. Multi-issuer Gaia + STS.
- `TokenClient`: intercambio `/token` + refresh con formulario de codificación estricta (solo no reservados RFC 3986) y `clientSecret` opcional.
- `LoopbackReceiver`: single-shot (cierra el listener tras entregar), guarda el código si llega antes de `waitForCode`, acumula headers fragmentados, `?error=` falla al momento con `userCancelled` (state/CSRF en T-AUTH-4).
- Scopes: intenta `[cloud]`; si error `consent_required`, reintenta `[cloud, email]`.
- Splice: `CredentialFacade` nunca se reemplaza; `splice` actualiza `token` in-place dentro del actor → los interceptores existentes siguen válidos.
- WIF (M4): `StsClient` (`AuthPortalCodeFlow` + `IntrospectToken`), `WorkforceIdentity` (`principal://` parser). `GCPClient` marca `isWorkforce` para que OS Login falle tipado.
- Proxy: `ProxyResolver` (`CFNetworkCopyProxiesForURL`) inyectado en `URLSessionConfiguration.connectionProxyDictionary`.
- Concurrencia: todo `async/await` + actor; `CredentialFacade` `Sendable`; cero `shared mutable`.

## Errores tipados
`AuthError.{userCancelled, loopbackTimeout, consentRequired, tokenExpired, network(Error), keychain(OSStatus), workforceNotSupported}`.
