#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

usage() {
    cat <<EOF
Usage: $0

Kill the local SSH tunnel for port $PORT. The remote GPU session keeps
running so you can reconnect later.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

TUNNEL_PID_FILE="$HOME/.opencode-tunnel-$PORT.pid"
REMOTE="$(remote_dir)"

if [[ -f "$TUNNEL_PID_FILE" ]]; then
    PID="$(cat "$TUNNEL_PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "Killed tunnel pid $PID for port $PORT."
    else
        echo "Tunnel pid $PID is not running; removing stale pid file."
    fi
    rm -f "$TUNNEL_PID_FILE"
else
    echo "No tunnel pid file found for port $PORT."
fi

echo
echo "The Count counts the tunnels: zero tunnels left. Ah ah ah! The GPU session remains."
echo "Reconnect:              laptop/connect.sh"
echo "Stop session, free GPU: ssh $LOGIN_NODE 'cd $REMOTE && bash cluster/teardown.sh'"
