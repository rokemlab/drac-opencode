#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

usage() {
    cat <<EOF
Usage: $0

Stop the drac-opencode session: kill the tmux session (which releases the
GPU allocation) and clear the status file.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
    echo "Killed tmux session '$SESSION'. GPU allocation released."
else
    echo "No tmux session '$SESSION' running."
fi

rm -f "$CONFIG_STATUS"
echo "Cleared status file $CONFIG_STATUS."
