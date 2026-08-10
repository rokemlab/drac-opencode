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
source "$SCRIPT_DIR/../config.sh"

usage() {
    cat <<EOF
Usage: $0

Ensure the session model is available on the cluster. Runs on a login node,
which has internet access (compute nodes do not). Pulls \$MODEL into
\$CONFIG_MODELS if it is not already present.

Exit 0 if the model is already present; pulls it otherwise.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -f "$CONFIG_SIF" ]]; then
    echo "ERROR: container image not found at $CONFIG_SIF" >&2
    echo "Build it first: container/build.sh (see README)." >&2
    exit 1
fi

mkdir -p "$CONFIG_MODELS"

MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${MODEL%:*}/${MODEL#*:}"
if [[ -f "$MANIFEST" ]]; then
    echo "Model $MODEL already present at $CONFIG_MODELS."
    exit 0
fi

PULL_PORT="${PULL_PORT:-11435}"
echo "Pulling $MODEL (first time only; can take several minutes)..."
apptainer run \
    --env "OLLAMA_HOST=127.0.0.1:$PULL_PORT" \
    --env "OLLAMA_MODELS=/models" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null || true' EXIT

up=0
deadline=$(( $(date +%s) + PULL_SERVE_TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
    if curl -sf "http://127.0.0.1:$PULL_PORT/api/tags" >/dev/null 2>&1; then
        up=1
        break
    fi
    sleep 2
done

if [[ $up -eq 0 ]]; then
    echo "ERROR: ollama serve did not start on this node." >&2
    exit 1
fi

apptainer exec \
    --env "OLLAMA_HOST=127.0.0.1:$PULL_PORT" \
    --env "OLLAMA_MODELS=/models" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" \
    ollama pull "$MODEL"

echo "Model $MODEL ready in $CONFIG_MODELS."
