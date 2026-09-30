# Spec Auth — design

Ref: requirements.md · `GaiaOidcClient`, `LoopbackCodeReceiver`, `Authorization.Splice` (origen C#).

## Arquitectura (`AuthKit`)

```
ASWebAuthenticationSession
  → LoopbackReceiver (NWListener, 127.0.0.1:0, path /authorize/)
  → TokenClient (URLSession, POST /token, /revoke)
  → CredentialFacade (actor, @Observable) → KeychainStore → GCPClient interceptor
```

- `CredentialFacade`: único punto de verdad. `authorize()`, `splice(_:)`, `revoke()`, `accessToken()` (auto-refresh con `refresh_token`). Emite `Reauthorized` vía `AsyncStream`.
- `KeychainStore`: `kSecClassGenericPassword`, servicio `com.iap-mac.auth`, cuentas `<issuer>:<email>`; guarda `{refresh, idToken, scopes, issuedAt}`. Multi-issuer Gaia + STS.
- `LoopbackReceiver`: `NWListener(tcp, 127.0.0.1:0)`, parse HTTP mínimo (`GET /authorize/?code=…`), timeout 120 s, página de cierre. Sin `HttpListener`/HttpSys (Windows-only).
- Scopes: intenta `[cloud]`; si error `consent_required`, reintenta `[cloud, email]`.
- Splice: `CredentialFacade` nunca se reemplaza; `splice` actualiza `token` in-place dentro del actor → los interceptores existentes siguen válidos.
- WIF (M4): `StsClient` (`AuthPortalCodeFlow` + `IntrospectToken`), `WorkforceIdentity` (`principal://` parser). `GCPClient` marca `isWorkforce` para que OS Login falle tipado.
- Proxy: `ProxyResolver` (`CFNetworkCopyProxiesForURL`) inyectado en `URLSessionConfiguration.connectionProxyDictionary`.
- Concurrencia: todo `async/await` + actor; `CredentialFacade` `Sendable`; cero `shared mutable`.

## Errores tipados
`AuthError.{userCancelled, loopbackTimeout, consentRequired, tokenExpired, network(Error), keychain(OSStatus), workforceNotSupported}`.
