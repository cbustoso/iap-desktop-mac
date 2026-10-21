# Spike F0 (GH-86): túnel nativo a Azure Bastion

Ejecutable SwiftPM **independiente** (no forma parte del `Package.swift` raíz ni
del build del App) que reimplementa en Swift `az network bastion tunnel`
siguiendo el protocolo de `specs/azure/azure-bastion-research.md` §3.3:

1. **Auth solo con `az login`** (§0.1): `az account get-access-token --resource
   https://management.core.windows.net/ [--tenant T] --output json`, cacheado en
   memoria por tenant. Tenant de la suscripción vía `az account list`.
2. **ARM (única llamada)**: `GET …/bastionHosts/{name}?api-version=2024-01-01` →
   `sku.name`, `properties.enableTunneling`, `properties.dnsName`.
3. **Por cada conexión TCP aceptada** en `127.0.0.1:<listen-port>`:
   `POST https://{dnsName}/api/tokens` (form: `resourceId`, `protocol=tcptunnel`,
   `workloadHostPort`, `aztoken` [+ `token` y `X-Node-Id` si hay sesión previa]) →
   `{authToken, nodeId, websocketToken}` →
   `wss://{dnsName}/webtunnelv2/{websocketToken}?X-Node-Id={nodeId}` con
   `Origin: https://{dnsName}`, sin subprotocolo ni `Authorization` → bytes TCP
   crudos en frames binarios (≤ 4096 B por lectura).
4. **Cierre**: al no quedar conexiones (o con Ctrl+C) un único
   `DELETE https://{dnsName}/api/tokens/{authToken}` con `X-Node-Id`.

Los logs (stderr) nunca muestran `aztoken`, `authToken` ni `websocketToken`
(`<redacted:N>`); el UPN de `--list-accounts` va enmascarado.

## Código

| Pieza | Archivo |
|---|---|
| (a)(b) `az` + caché por tenant | `Sources/BastionSpikeCore/AzCli.swift` |
| (c)(d) GET Bastion, POST/DELETE `/api/tokens`, sesión | `Sources/BastionSpikeCore/BastionAPI.swift` |
| (e) WebSocket (WebSocketKit) | `Sources/BastionSpikeCore/TunnelSocket.swift` |
| Bombeo TCP ↔ WS | `Sources/BastionSpikeCore/TunnelPump.swift` |
| (f) Listener 127.0.0.1 (Network.framework) | `Sources/BastionSpikeCore/LocalListener.swift` |
| (g) Modo RDP | `Sources/BastionSpikeCore/RDPLauncher.swift` |
| (h) Logs redactados | `Sources/BastionSpikeCore/SpikeLog.swift` |
| (i) CLI y orquestación | `Sources/BastionSpikeCore/SpikeOptions.swift`, `SpikeRunner.swift` |

## Build y tests (sin credenciales)

```bash
cd Spikes/BastionSpike
swift build
swift test
# Solo CommandLineTools (sin Xcode): "TestingMacros plugin not found" →
swift test -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

Los tests usan un WebSocket falso en memoria (framing ≤ 4096 B, eco troceado,
frame de texto → error, cierre), un servidor `/webtunnelv2` NIO real en
loopback (headers del upgrade en el wire), HTTP falso (form, encadenado,
DELETE único + 404), `az` falso (argumentos, caché, sin sesión) y redacción.

## Preparación en Azure (una vez, por el dueño)

1. **Azure CLI y sesión**
   ```bash
   brew install azure-cli
   az login                       # o: az login --tenant <tenant-id>
   az account list --output table
   ```
2. **Bastion SKU Standard o Premium con native client** (Basic y Developer no
   sirven para `tunnel`). Portal → Bastion → *Configuration* → Tier *Standard* y
   **Native client support** activado, o:
   ```bash
   az network bastion update -g <rg> -n <bastion> --sku Standard --enable-tunneling true
   az network bastion show -g <rg> -n <bastion> \
     --query "{sku:sku.name, tunneling:enableTunneling, dns:dnsName}" -o table
   ```
   Coste ≈ 0,29 USD/h (Standard) mientras exista: bórralo al terminar
   (research §6.2).
3. **Roles mínimos** para tu usuario: **Reader** sobre la VM, su NIC y el
   Bastion (y la VNet si está peered). Ejemplo:
   ```bash
   ME=$(az ad signed-in-user show --query id -o tsv)
   for ID in $(az vm show -g <rg> -n <vm> --query id -o tsv) \
             $(az vm show -g <rg> -n <vm> --query "networkProfile.networkInterfaces[0].id" -o tsv) \
             $(az network bastion show -g <rg> -n <bastion> --query id -o tsv); do
     az role assignment create --assignee "$ME" --role Reader --scope "$ID"
   done
   ```
4. **NSG de la VM**: permitir 22/3389 desde `AzureBastionSubnet`.

## Prueba e2e

Variables para copiar y pegar:

```bash
SUB=<subscription-id>; RG=<rg-del-bastion>; BASTION=<bastion>; VM=<vm>
cd Spikes/BastionSpike && swift build -c release
BIN=$(swift build -c release --show-bin-path)/bastion-spike
```

0. Sesión `az` vista por el spike:
   ```bash
   $BIN --list-accounts
   ```
1. **SSH (A0.1, A0.2)** — terminal 1:
   ```bash
   $BIN --subscription $SUB --resource-group $RG --bastion $BASTION --vm $VM \
        --port 22 --mode ssh --listen-port 50022 --verbose
   ```
   terminal 2:
   ```bash
   ssh -p 50022 <usuario>@127.0.0.1
   sftp -P 50022 <usuario>@127.0.0.1      # segunda conexión: POST encadenado (token + X-Node-Id)
   ```
   Ctrl+C en la terminal 1 → `DELETE /api/tokens → HTTP 200|204`.
2. **RDP (A0.3)** (VM Windows):
   ```bash
   $BIN --subscription $SUB --resource-group $RG --bastion $BASTION --vm <vm-windows> \
        --mode rdp --listen-port 53389 --user <usuario>
   ```
   Genera un `.rdp` temporal (`full address:s:127.0.0.1:53389`) y lo abre con
   Windows App si está instalada; si no, imprime la ruta.
3. **DELETE doble (A0.4)**: añade `--double-delete`; al Ctrl+C debe verse el
   primer DELETE 200/204 y `segundo DELETE (A0.4): alreadyGone` (404).
4. **Puerto custom y sesión larga (A0.5)**: `--port 2222` (u otro puerto que
   escuche la VM) y una sesión SSH abierta > 60 min (p. ej. `ssh … 'while :; do
   date; sleep 300; done'`). Anota si el token ARM se renueva (cada conexión nueva
   pide token a `az`; caché con 5 min de margen) y si el WS se corta.
5. **Contraste con el CLI** (mismo destino, otro puerto):
   ```bash
   az network bastion tunnel --name $BASTION --resource-group $RG --subscription $SUB \
     --target-resource-id $(az vm show -g $RG -n $VM --subscription $SUB --query id -o tsv) \
     --resource-port 22 --port 50023
   ssh -p 50023 <usuario>@127.0.0.1
   ```
   Ambos deben dar el mismo banner `SSH-2.0-…` y la misma host key.
6. **Todo junto**: `scripts/validate-f0.sh $SUB $RG $BASTION $VM [<usuario>]`
   (banner vía spike y vía `az`, ssh real si pasas usuario, DELETE doble y
   comprobación de que el token ARM no está en el log).

## Qué registrar en `specs/azure/f0-findings.md` (A0.6)

- Líneas `POST`/`WS`/`DELETE` del log `--verbose` (ya redactadas) y códigos HTTP.
- Si el `aztoken` con `--resource https://management.core.windows.net/` fue
  aceptado (A0.1, decisión §0.1).
- Banner y host key vía spike vs `az network bastion tunnel`.
- Resultado RDP con Windows App; puerto custom; comportamiento > 60 min.
- Cualquier diferencia con §3.3 (headers extra exigidos, frames de texto,
  pings del servidor, tamaño máximo de frame).

## Validar el código de producción (GH-95)

`scripts/validate-f0.sh --usar-bastionkit …` ejecuta las mismas comprobaciones
con `bastion-check`, un binario del `Package.swift` raíz que monta el túnel con
`BastionKit` (proxy del sistema, renovación de sesión, errores tipados) en vez
del código del spike. Así la lógica del protocolo vive en un solo sitio y la
batería e2e pre-release valida lo que se publica. `HOLD_SECS=<n>` (con usuario
SSH) añade una sesión SSH ociosa de `n` segundos para validar keepalive y
sesiones largas. Detalle en `docs/usage.md` §13.11.

