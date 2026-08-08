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
{
    echo "host=$HOST_SHORT"
    echo "port=$PORT"
    echo "model=$MODEL"
    echo "ready=no"
} > "$CONFIG_STATUS"

echo "=== opencode GPU session on $HOST_SHORT ==="
echo "Model: $MODEL  |  Port: $PORT  |  Status: $CONFIG_STATUS"

if [[ ! -f "$CONFIG_SIF" ]]; then
    echo "ERROR: container image not found at $CONFIG_SIF" >&2
    echo "Build it first: container/build.sh (see README)." >&2
    exit 1
fi

echo "Starting ollama serve inside apptainer..."
apptainer run \
    --nv \
    --env "OLLAMA_HOST=127.0.0.1:$PORT" \
    --env "OLLAMA_MODELS=/models" \
    --env "OLLAMA_CONTEXT_LENGTH=32768" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" \
    >"$CONFIG_LOG" 2>&1 &
SERVE_PID=$!

echo "Waiting for ollama to listen on 127.0.0.1:$PORT..."
ready=0
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$PORT/api/tags" >/dev/null 2>&1; then
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

echo "Pulling model $MODEL (first time only)..."
if ! apptainer exec \
    --env "OLLAMA_HOST=127.0.0.1:$PORT" \
    --env "OLLAMA_MODELS=/models" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" \
    ollama pull "$MODEL"; then
    echo "WARNING: model pull failed; the server is still running." >&2
    echo "Retry later with: apptainer exec <sif> ollama pull $MODEL" >&2
fi

echo "ready=yes" >> "$CONFIG_STATUS"

echo
echo "============================================================"
echo " READY: opencode GPU session live on $HOST_SHORT"
echo " Model: $MODEL  |  Port: $PORT"
echo " From your laptop run: laptop/connect.sh"
echo "============================================================"

wait "$SERVE_PID"
