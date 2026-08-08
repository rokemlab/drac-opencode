#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

usage() {
    cat <<EOF
Usage: $0

One-time setup: sync this repo to the cluster and build the Apptainer image
if it does not exist yet.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v ssh >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: ssh and rsync are both required." >&2
    exit 1
fi

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE="$(remote_dir)"

echo "Syncing $REPO to $LOGIN_NODE:$REMOTE ..."
ssh "$LOGIN_NODE" "mkdir -p '$REMOTE'"
rsync -a --delete --exclude '.git' "$REPO/" "$LOGIN_NODE:$REMOTE/"

SIF_PATH="$(remote_path ollama.sif)"
if ssh "$LOGIN_NODE" "[[ -f '$SIF_PATH' ]]"; then
    echo "Container image already exists at $SIF_PATH"
else
    echo "Container image missing -- building on $LOGIN_NODE (can take several minutes)..."
    ssh "$LOGIN_NODE" "cd '$REMOTE/container' && ./build.sh '$SIF_PATH'"
fi

echo "Ensuring the session model is available on the cluster..."
ssh "$LOGIN_NODE" "cd '$REMOTE' && bash cluster/pull-model.sh"

echo "Setup complete."
