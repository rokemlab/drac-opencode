#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config.sh
source "$SCRIPT_DIR/../config.sh"

usage() {
    cat <<EOF
Usage: $0

Run disconnect then teardown in one go: kill the local SSH tunnel and free
the remote GPU allocation.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

REMOTE="$(remote_dir)"

echo "==> Step 1 of 2: disconnect"
bash "$SCRIPT_DIR/disconnect.sh"

echo
echo "==> Step 2 of 2: teardown"
ssh_run "$LOGIN_NODE" "cd '$REMOTE' && bash cluster/teardown.sh"
ssh_close

echo
echo "Done. GPU session stopped."
