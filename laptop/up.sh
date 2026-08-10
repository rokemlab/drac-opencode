#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Run setup then connect in one go: sync the repo, ensure the image and model
exist, provision a GPU session, open the SSH tunnel, and configure opencode.

  --dry-run   Print the connect commands without executing them.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

echo "==> Step 1 of 2: setup"
bash "$SCRIPT_DIR/setup.sh"

echo
echo "==> Step 2 of 2: connect"
exec bash "$SCRIPT_DIR/connect.sh" "$@"
