# Checklist de verificación OAuth (GH-73)

Pantalla de consentimiento de Google Cloud → verificación de la app "IAP Desktop for Mac".
Sitio público (repo `cbustoso/iap-desktop-mac-site`, solo documentación, sin código ni secretos).

## 1. URLs del sitio (OAuth consent screen → App information / App domain)

- [ ] Application home page: https://cbustoso.github.io/iap-desktop-mac-site/
- [ ] Privacy policy: https://cbustoso.github.io/iap-desktop-mac-site/privacy
- [ ] Terms of service: https://cbustoso.github.io/iap-desktop-mac-site/terms
- [ ] Las tres responden 200 sin login y enlazan entre sí
- [ ] La privacy policy describe el uso de datos de Google (Limited Use) y el contacto
- [ ] Email de soporte / contacto del desarrollador: cbustoso@ntt-siom.com

## 2. Dominios autorizados

- [ ] `cbustoso.github.io` añadido en *Authorized domains*
- [ ] Propiedad verificada en Google Search Console para `https://cbustoso.github.io/iap-desktop-mac-site/`
      (meta tag o fichero HTML de verificación en el repo del sitio, el que pida Search Console)
- [ ] Nota: el cliente es *Desktop app* con redirect loopback (`http://127.0.0.1:{puerto}/authorize`);
      no requiere dominios de redirect

## 3. Scopes y justificación

| Scope | Tipo | Justificación para el formulario |
|---|---|---|
| `openid` | No sensible | Identificar la sesión iniciada. |
| `https://www.googleapis.com/auth/userinfo.email` | No sensible | Mostrar la cuenta conectada y usarla como identidad para IAP y OS Login. |
| `https://www.googleapis.com/auth/cloud-platform` | Sensible | La app es un cliente de escritorio para Compute Engine vía IAP: lista proyectos/instancias (Resource Manager, Compute), abre túneles IAP TCP (SSH/SFTP/RDP), gestiona claves OS Login/metadata, resetea credenciales Windows y comprueba IAM/firewall para diagnóstico. No existe un scope más reducido que cubra IAP TCP forwarding + Compute + OS Login. |

- [ ] Los scopes de la consola coinciden exactamente con `Sources/AuthKit/AuthorizeURL.swift`
- [ ] Ningún scope adicional pedido en la consola que la app no use

## 4. Vídeo de demostración (YouTube, no listado)

- [ ] Muestra el flujo completo: lanzar app → "Sign in" → pantalla de consentimiento con el
      **client ID visible en la URL** → aceptar → vuelta a la app
- [ ] Muestra el uso de cada scope: lista de proyectos/VMs, conexión SSH por IAP, SFTP, RDP, diagnóstico
- [ ] Muestra la cuenta conectada (email) y el cierre de sesión / borrado de perfil
- [ ] Idioma de la UI en inglés; sin tokens ni secretos en pantalla

## 5. Test users / estado de publicación

- [ ] Mientras está en *Testing*: añadir los test users (máx. 100) que validan la app
- [ ] Pasar a *In production* antes de enviar a verificación
- [ ] Revisar que el límite de usuarios / refresh tokens de 7 días de *Testing* ya no aplica tras publicar

## 6. Envío

- [ ] Nombre de app y logo coinciden con la homepage
- [ ] Justificación de scopes (sección 3) pegada en el formulario
- [ ] Enlace al vídeo demo
- [ ] Responder al correo del equipo de verificación desde la dirección de contacto
- [ ] Sin `client_secret` ni client IDs en el sitio público ni en el repo del sitio (comprobado con grep `GOCSPX` / `apps.googleusercontent`)
