#!/bin/sh
# GH-86 (F0): validación semiautomática A0.2 / A0.4 / A0.6 contra un Bastion real.
# Uso:
#   scripts/validate-f0.sh <subscription> <resource-group> <bastion> <vm> [usuario-ssh]
# Requiere `az login` hecho. No imprime tokens: comprueba que tampoco estén en el log.
set -eu
cd "$(dirname "$0")/.."

SUB="$1"; RG="$2"; BASTION="$3"; VM="$4"; SSH_USER="${5:-}"
SPIKE_PORT="${SPIKE_PORT:-50022}"
AZ_PORT="${AZ_PORT:-50023}"
OUT="$(mktemp -d /tmp/bastion-f0.XXXXXX)"
LOG="$OUT/spike.log"
echo "Logs en $OUT"

swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)/bastion-spike"

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
