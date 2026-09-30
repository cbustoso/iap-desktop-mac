# Spec Auth — tasks (→ issues Linear)

- [ ] T-AUTH-1 `AuthKit` skeleton: `CredentialFacade` actor + `KeychainStore` + errores tipados. Test: round-trip Keychain en CI (keychain efímero). → REQ-1,6
- [ ] T-AUTH-2 `LoopbackReceiver` (`NWListener` 127.0.0.1:0, parse code, timeout). Test: servidor local + redirect simulado. → REQ-1
- [ ] T-AUTH-3 PKCE S256 (`verifier/challenge`, intercambio `/token`). Test: vector RFC 7636 + mock `/token`. → REQ-1
- [ ] T-AUTH-4 Login UI (`ASWebAuthenticationSession` + scopes mínimos + reintento consent). UI test: flujo feliz con mock IdP. → REQ-1
- [ ] T-AUTH-5 Splice + `Reauthorized` (cambio de cuenta sin romper `GCPClient`). Test: dos splices seguidos, interceptores vivos. → REQ-2
- [ ] T-AUTH-6 Revoke + logout (borrado Keychain). Test: revoke mock + Keychain vacío. → REQ-3
- [ ] T-AUTH-7 WIF/STS (M4). → REQ-4
- [ ] T-AUTH-8 Proxy + degradación mTLS (M4). → REQ-5
- [ ] T-AUTH-9 Redacción de secretos en OSLog + auditoría "sin tokens en logs". Test: assert sobre formateo. → REQ-6

Secuencia: T-AUTH-1 → 2 → 3 → 4 → 5 → 6 → 9; 7–8 en M4.
