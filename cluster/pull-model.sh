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

Ensure every model in MODELS is available on the cluster. Runs on a login
node, which has internet access (compute nodes do not). Pulls any missing
model from MODELS into \$CONFIG_MODELS.

Exit 0 if all models are already present; pulls missing ones otherwise.
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

if [[ -z "${MODELS:-}" ]]; then
    echo "ERROR: MODELS is empty; nothing to pull." >&2
    exit 1
fi

missing=()
for m in $MODELS; do
    MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
    if [[ -f "$MANIFEST" ]]; then
        echo "Model $m already present at $CONFIG_MODELS."
    else
        missing+=("$m")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    exit 0
fi

PULL_PORT="${PULL_PORT:-11435}"
echo "Pulling missing models: ${missing[*]} (first time only; can take several minutes)..."
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

for m in "${missing[@]}"; do
    echo "Pulling $m ..."
    apptainer exec \
        --env "OLLAMA_HOST=127.0.0.1:$PULL_PORT" \
        --env "OLLAMA_MODELS=/models" \
        --bind "$CONFIG_MODELS:/models" \
        "$CONFIG_SIF" \
        ollama pull "$m"
    MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
    if [[ ! -f "$MANIFEST" ]]; then
        echo "ERROR: pull of $m did not produce a manifest." >&2
        exit 1
    fi
    echo "Model $m ready in $CONFIG_MODELS."
done
