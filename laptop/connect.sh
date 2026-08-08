#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Provision a GPU session on the cluster, open an SSH tunnel to the Ollama
port, and configure opencode to use it.

  --dry-run   Print the commands without executing them.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required (brew install jq)." >&2
    exit 1
fi

REMOTE="$(remote_dir)"
STATUS_REMOTE="$(remote_path status.txt)"
TUNNEL_PID_FILE="$HOME/.opencode-tunnel-$PORT.pid"

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

configure_opencode() {
    local port="$1" model="$2"
    local cfg="$HOME/.config/opencode/opencode.json"
    mkdir -p "$(dirname "$cfg")"

    local new
    new="$(jq -n --arg base "http://127.0.0.1:${port}/v1" --arg model "$model" \
        '{provider: {("drac-ollama"): {npm: "@ai-sdk/openai-compatible", name: "DRAC Ollama", options: {baseURL: $base}, models: {($model): {name: ("DRAC " + $model)}}}}}')"

    if [[ -f "$cfg" ]]; then
        if ! jq -e . "$cfg" >/dev/null 2>&1; then
            echo "ERROR: $cfg exists but is not valid JSON. Refusing to touch it." >&2
            exit 1
        fi
        cp "$cfg" "$cfg.bak.pre-drac"
        new="$(jq --argjson p "$new" \
            '.provider = ((.provider // {}) | del(.["drac-ollama"]) | . + $p.provider)' "$cfg")"
    fi

    printf '%s\n' "$new" > "$cfg"
    echo "Updated $cfg (backup at $cfg.bak.pre-drac)"
}

echo "==> Starting GPU session on $LOGIN_NODE"
if ! run ssh "$LOGIN_NODE" "cd '$REMOTE' && bash cluster/provision.sh"; then
    echo "provision.sh did not start a new session (may already be running)."
fi

echo "==> Waiting for the Ollama server to rise (queue wait can take minutes)..."
if [[ $DRY_RUN -eq 1 ]]; then
    HOST="dryrun-node"
    COMPUTE_IP="dryrun-ip"
else
    if ! ssh "$LOGIN_NODE" "bash '$REMOTE/cluster/status.sh' --wait 600"; then
        echo "ERROR: session did not become ready in time." >&2
        echo "Inspect: ssh $LOGIN_NODE 'cat \"\$SCRATCH\"/opencode/ollama.log'" >&2
        exit 1
    fi
    HOST="$(ssh "$LOGIN_NODE" "grep '^host=' '$STATUS_REMOTE' | cut -d= -f2")"
    COMPUTE_IP="$(ssh "$LOGIN_NODE" "grep '^ip=' '$STATUS_REMOTE' | cut -d= -f2")"
    MODEL="$(ssh "$LOGIN_NODE" "grep '^model=' '$STATUS_REMOTE' | cut -d= -f2")"
fi

if [[ -z "$HOST" ]]; then
    echo "ERROR: could not determine compute node hostname." >&2
    exit 1
fi

if [[ -z "$COMPUTE_IP" ]]; then
    echo "ERROR: could not determine compute node IP (status file missing ip=)." >&2
    echo "Re-provision: ssh $LOGIN_NODE 'cd $REMOTE && bash cluster/teardown.sh && bash cluster/provision.sh'" >&2
    exit 1
fi

echo "==> Ollama server is on compute node $HOST ($COMPUTE_IP, port $PORT)"

if lsof -i "tcp:$PORT" >/dev/null 2>&1; then
    echo "WARNING: 127.0.0.1:$PORT is already in use locally." >&2
    echo "Set PORT to a free value in laptop/config.sh and cluster/config.sh." >&2
fi

echo "==> Configuring opencode for $MODEL via http://127.0.0.1:$PORT/v1"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] configure_opencode $PORT $MODEL"
    echo "[dry-run] ssh -N -L $PORT:$COMPUTE_IP:$PORT -o ExitOnForwardFailure=yes $LOGIN_NODE"
    echo "[dry-run] pid file would be $TUNNEL_PID_FILE"
fi

echo
echo "READY. Complete the Alliance key + Duo prompt below to open the tunnel,"
echo "then run opencode in a NEW terminal."
echo "The night is young and the model is hungry.  Model: $MODEL  |  Endpoint: http://127.0.0.1:$PORT/v1"
echo "Stop tunnel: laptop/disconnect.sh  |  Free GPU: ssh $LOGIN_NODE 'cd $REMOTE && bash cluster/teardown.sh'"
echo

if [[ $DRY_RUN -eq 1 ]]; then
    exit 0
fi

configure_opencode "$PORT" "$MODEL"

echo "$$" > "$TUNNEL_PID_FILE"
exec ssh -N -L "$PORT:$COMPUTE_IP:$PORT" \
    -o ExitOnForwardFailure=yes "$LOGIN_NODE"
