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
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

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
    echo "model=$MODEL"
    echo "ready=no"
} > "$CONFIG_STATUS"

echo "=== opencode GPU session on $HOST_SHORT ==="
echo "Model: $MODEL  |  Port: $PORT  |  Node IP: $NODE_IP  |  Status: $CONFIG_STATUS"
echo "NOTE: ollama listens on the cluster network so the login node can tunnel to it."
echo "      (The Count needs no invitation to cross — just the right port. Ah ah ah!)"

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

echo "Waiting for ollama on $NODE_IP:$PORT... one... two... three... ah ah ah!"
ready=0
for _ in $(seq 1 60); do
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
    echo "ERROR: ollama did not respond within 300s." >&2
    echo "Log: $CONFIG_LOG" >&2
    exit 1
fi

echo "Checking model $MODEL is present..."
MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${MODEL%:*}/${MODEL#*:}"
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: model $MODEL not found at $CONFIG_MODELS." >&2
    echo "Compute nodes have no internet; pull it on the login node with:" >&2
    echo "  bash cluster/pull-model.sh  (runs automatically from provision.sh)" >&2
    exit 1
fi

echo "ready=yes" >> "$CONFIG_STATUS"

echo
echo "============================================================"
echo " READY: opencode GPU session live on $HOST_SHORT"
echo " Model: $MODEL  |  Port: $PORT"
echo " From your laptop run: laptop/connect.sh"
echo "============================================================"
echo "The Count has counted: one model, one GPU, one port. Ah ah ah!"

wait "$SERVE_PID"
