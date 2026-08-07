#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

usage() {
    cat <<EOF
Usage: $0 [--dry-run]

Start a persistent tmux session that runs ollama in a container on a GPU node.

  --dry-run   Print the srun command without starting anything.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ ! -f "$CONFIG_SIF" ]]; then
    echo "ERROR: container image not found at $CONFIG_SIF" >&2
    echo "Build it first: container/build.sh (see README)." >&2
    exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "ERROR: tmux session '$SESSION' is already running." >&2
    echo "Attach: tmux attach -t $SESSION" >&2
    echo "Stop:   cluster/teardown.sh" >&2
    exit 1
fi

SRUN_CMD=(srun --gpus="$GPU_COUNT" --cpus-per-task="$CPUS" --mem="$MEM"
           --time="$TIME" --pty bash "$SCRIPT_DIR/run-ollama.sh")

echo "srun command: ${SRUN_CMD[*]}"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "(dry run -- nothing started)"
    exit 0
fi

tmux new-session -d -s "$SESSION" "${SRUN_CMD[@]}"

echo "Session '$SESSION' started (queue wait may take a while)."
echo "Watch progress: tmux attach -t $SESSION"
echo "Check status:   cluster/status.sh"
