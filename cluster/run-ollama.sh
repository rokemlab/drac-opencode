#!/usr/bin/env bash
set -eo pipefail

# Alliance Canada clusters only define `module` in login/interactive shells.
# Source the CVMFS environment init explicitly so it's available here too.
if [[ -f /cvmfs/soft.computecanada.ca/config/profile/bash.sh ]]; then
    source /cvmfs/soft.computecanada.ca/config/profile/bash.sh
fi

if command -v module >/dev/null 2>&1; then
    set +u
    module load apptainer
    set -u
else
    echo "WARNING: 'module' command still not found after sourcing CVMFS profile." >&2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
PORT_FROM_ENV="${PORT:-}"
source "$SCRIPT_DIR/../config.sh"

# Pick a fresh random port for this session so the served endpoint moves each
# time (other cluster users cannot guess it). An explicitly pinned PORT wins.
if [[ -z "$PORT_FROM_ENV" ]]; then
    PORT=""
    for _ in 1 2 3; do
        cand=$(( 20000 + RANDOM % 30000 ))
        if ! command -v ss >/dev/null 2>&1 || ! ss -ltn 2>/dev/null | grep -q ":$cand "; then
            PORT=$cand
            break
        fi
    done
    if [[ -z "$PORT" ]]; then
        PORT=$(( 20000 + RANDOM % 30000 ))
    fi
fi

mkdir -p "$CONFIG_BASE" "$CONFIG_MODELS"

cleanup() {
    if [[ -f "$CONFIG_STATUS" ]]; then
        grep -v '^ready=' "$CONFIG_STATUS" > "$CONFIG_STATUS.tmp" || true
        echo "ready=no" >> "$CONFIG_STATUS.tmp"
        mv "$CONFIG_STATUS.tmp" "$CONFIG_STATUS"
    fi
}
trap cleanup EXIT
trap 'exit 1' TERM INT HUP

HOST_SHORT="$(hostname)"
NODE_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet / && /scope global/ {print $2}' | cut -d/ -f1 | head -1)"
if [[ -z "$NODE_IP" ]]; then
    NODE_IP="$(hostname -i | awk '{print $1}')"
fi
{
    echo "host=$HOST_SHORT"
    echo "ip=$NODE_IP"
    echo "port=$PORT"
    echo "models=$MODELS"
    echo "ready=no"
} > "$CONFIG_STATUS"

echo "=== opencode GPU session on $HOST_SHORT ==="
echo "Models: $MODELS  |  Port: $PORT  |  Node IP: $NODE_IP  |  Status: $CONFIG_STATUS"
echo "NOTE: ollama listens on the cluster network so the login node can tunnel to it."

if [[ ! -f "$CONFIG_SIF" ]]; then
    echo "ERROR: container image not found at $CONFIG_SIF" >&2
    echo "Build it first: container/build.sh (see README)." >&2
    exit 1
fi

echo "Starting ollama serve inside apptainer..."
apptainer run \
    --nv \
    --env "OLLAMA_HOST=$NODE_IP:$PORT" \
    --env "OLLAMA_MODELS=/models" \
    --env "OLLAMA_CONTEXT_LENGTH=32768" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" \
    >"$CONFIG_LOG" 2>&1 &
SERVE_PID=$!

echo "Waiting for ollama to listen on $NODE_IP:$PORT..."
ready=0
deadline=$(( $(date +%s) + OLLAMA_START_TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
    if curl -sf "http://$NODE_IP:$PORT/api/tags" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$SERVE_PID" 2>/dev/null; then
        echo "ERROR: ollama serve exited early." >&2
        tail -20 "$CONFIG_LOG" >&2
        exit 1
    fi
    sleep 5
done

if [[ $ready -eq 0 ]]; then
    echo "ERROR: ollama did not respond within ${OLLAMA_START_TIMEOUT}s." >&2
    echo "Log: $CONFIG_LOG" >&2
    exit 1
fi

echo "Checking models are present..."
missing=()
for m in $MODELS; do
    MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
    if [[ ! -f "$MANIFEST" ]]; then
        missing+=("$m")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: model(s) not found at $CONFIG_MODELS: ${missing[*]}" >&2
    echo "Compute nodes have no internet; pull them on the login node with:" >&2
    echo "  bash cluster/pull-model.sh  (runs automatically from provision.sh)" >&2
    exit 1
fi

echo "ready=yes" >> "$CONFIG_STATUS"

echo
echo "============================================================"
echo " READY: opencode GPU session live on $HOST_SHORT"
echo " Models: $MODELS  |  Port: $PORT"
echo " From your laptop run: laptop/connect.sh"
echo "============================================================"

wait "$SERVE_PID"
