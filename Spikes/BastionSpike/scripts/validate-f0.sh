#!/bin/sh
# GH-86 (F0): validación semiautomática A0.2 / A0.4 / A0.6 contra un Bastion real.
# Uso:
#   scripts/validate-f0.sh [--usar-bastionkit] <subscription> <resource-group> <bastion> <vm> [usuario-ssh]
#
# --usar-bastionkit (GH-95): en vez del spike, ejecuta `bastion-check` del
# Package.swift raíz, que monta el túnel con el código de PRODUCCIÓN
# (BastionKit + AzureClient + AzCliTokenSource, proxy del sistema y
# renovación). Mismas opciones y mismas líneas de log: el resto del script no
# cambia, así la batería e2e pre-release (REQ-AZ-10) valida lo que se publica.
#
# Variables: SPIKE_PORT, AZ_PORT, y HOLD_SECS (con usuario SSH: mantiene una
# sesión SSH ociosa ese tiempo para validar keepalive/pings y sesiones largas).
#
# Requiere `az login` hecho. No imprime tokens: comprueba que tampoco estén en el log.
set -eu
cd "$(dirname "$0")/.."

USE_BASTIONKIT=0
if [ "${1:-}" = "--usar-bastionkit" ]; then USE_BASTIONKIT=1; shift; fi

SUB="$1"; RG="$2"; BASTION="$3"; VM="$4"; SSH_USER="${5:-}"
SPIKE_PORT="${SPIKE_PORT:-50022}"
AZ_PORT="${AZ_PORT:-50023}"
HOLD_SECS="${HOLD_SECS:-0}"
OUT="$(mktemp -d /tmp/bastion-f0.XXXXXX)"
LOG="$OUT/spike.log"
echo "Logs en $OUT"

if [ "$USE_BASTIONKIT" = 1 ]; then
    echo "== Implementación: BastionKit (bastion-check, código de producción)"
    ROOT="$(cd ../.. && pwd)"
    swift build --package-path "$ROOT" -c release --product bastion-check >/dev/null
    BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)/bastion-check"
else
    echo "== Implementación: spike F0 (bastion-spike)"
    swift build -c release >/dev/null
    BIN="$(swift build -c release --show-bin-path)/bastion-spike"
fi

wait_port() {
    i=0
    while ! nc -z 127.0.0.1 "$1" 2>/dev/null; do
        i=$((i + 1)); [ "$i" -gt 60 ] && { echo "timeout esperando 127.0.0.1:$1" >&2; return 1; }
        sleep 1
    done
}

# El banner SSH es lo primero que llega tras el 101 (research §3.3 (2)).
banner() {
    (sleep 8) | nc 127.0.0.1 "$1" | head -1 | tr -d '\r'
}

"$BIN" --subscription "$SUB" --resource-group "$RG" --bastion "$BASTION" --vm "$VM" \
    --port 22 --mode ssh --listen-port "$SPIKE_PORT" --double-delete --verbose 2>"$LOG" &
SPIKE_PID=$!
trap 'kill -INT $SPIKE_PID 2>/dev/null || true' EXIT
wait_port "$SPIKE_PORT"

echo "== A0.2 banner vía spike"
SPIKE_BANNER="$(banner "$SPIKE_PORT")"
echo "spike: $SPIKE_BANNER"
case "$SPIKE_BANNER" in SSH-2.0-*) echo "OK banner" ;; *) echo "FALLO banner" ;; esac

if [ -n "$SSH_USER" ]; then
    echo "== A0.2 ssh real (BatchMode: necesita tu clave en la VM)"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OUT/known_hosts" \
        -p "$SPIKE_PORT" "$SSH_USER@127.0.0.1" 'echo ssh-ok; uname -a' || echo "FALLO ssh"
fi

if [ -n "$SSH_USER" ] && [ "$HOLD_SECS" -gt 0 ]; then
    echo "== F3 sesión larga: SSH ocioso ${HOLD_SECS}s (keepalive/pings; R10)"
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$OUT/known_hosts" \
        -p "$SPIKE_PORT" "$SSH_USER@127.0.0.1" "sleep $HOLD_SECS; echo sigue-viva"; then
        echo "OK sesión larga"
    else
        echo "FALLO sesión larga (ver 'túnel caído' en $LOG)"
    fi
fi

echo "== Contraste con az network bastion tunnel"
VM_ID="$(az vm show -g "$RG" -n "$VM" --subscription "$SUB" --query id -o tsv)"
az network bastion tunnel --name "$BASTION" --resource-group "$RG" --subscription "$SUB" \
    --target-resource-id "$VM_ID" --resource-port 22 --port "$AZ_PORT" >"$OUT/az-tunnel.log" 2>&1 &
AZ_PID=$!
if wait_port "$AZ_PORT"; then
    echo "az:    $(banner "$AZ_PORT")"
fi
kill "$AZ_PID" 2>/dev/null || true

echo "== A0.4 cierre: DELETE 200/204 y segundo DELETE 404"
kill -INT "$SPIKE_PID"; wait "$SPIKE_PID" || true
trap - EXIT
grep -E "DELETE /api/tokens → HTTP|segundo DELETE" "$LOG" || echo "FALLO: no hay DELETE en el log"

echo "== Redacción: el token ARM no debe aparecer en el log"
TOKEN="$(az account get-access-token --resource https://management.core.windows.net/ --subscription "$SUB" --query accessToken -o tsv)"
if grep -qF "$TOKEN" "$LOG"; then echo "FALLO: token en el log"; else echo "OK: sin token en el log"; fi
grep -cE "webtunnelv2/[^<]" "$LOG" | sed 's/^/líneas con websocketToken en claro (debe ser 0): /'

echo "Copia (redactada) a specs/azure/f0-findings.md las líneas POST/WS/DELETE de $LOG"
