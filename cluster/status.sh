#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

usage() {
    cat <<EOF
Usage: $0 [--wait [SECONDS]]

Print the current drac-opencode session status.

  --wait [SECONDS]   Poll until the session is ready. Default timeout: 600s.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--wait" ]]; then
    timeout="${2:-600}"
    deadline=$(( $(date +%s) + timeout ))
    while ! grep -q '^ready=yes$' "$CONFIG_STATUS" 2>/dev/null; do
        if [[ $(date +%s) -ge $deadline ]]; then
            echo "ERROR: timed out after ${timeout}s waiting for readiness." >&2
            if [[ -f "$CONFIG_STATUS" ]]; then
                echo "Last known status:" >&2
                cat "$CONFIG_STATUS" >&2
            fi
            exit 1
        fi
        sleep 5
    done
fi

if [[ ! -f "$CONFIG_STATUS" ]]; then
    echo "ERROR: no status file at $CONFIG_STATUS" >&2
    echo "Start a session first: provision.sh" >&2
    exit 1
fi

cat "$CONFIG_STATUS"
