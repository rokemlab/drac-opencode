#!/usr/bin/env bash
# Shared configuration for drac-opencode, sourced by both laptop/ and cluster/
# scripts. laptop/setup.sh rsyncs this repo to the cluster, so both sides use
# the same file. Every value can be overridden with an environment variable.

# Laptop-side
: "${LOGIN_NODE:=narval.alliancecan.ca}"
# DRY_RUN_PORT feeds connect.sh --dry-run display only. It is deliberately not
# exported: an exported default would ride provision.sh -> tmux -> srun into
# run-ollama.sh, where PORT_FROM_ENV would treat it as a user pin and skip the
# per-session random roll. A port pinned on the login node (e.g.
# "PORT=7777 bash cluster/provision.sh") is exported by the caller and still
# propagates.
: "${DRY_RUN_PORT:=11435}"
: "${MODEL:=qwen3.6:27b}" # Should also try qwen3.6:27b-coding-mxfp8
: "${REMOTE_DIR:=/home/$USER/drac-opencode}"
: "${FAKE_REMOTE:=}"

# SSH connection sharing: the first connection to the login node authenticates
# once and becomes a master; every ssh/rsync within SSH_PERSIST seconds reuses
# it, so a full up.sh/down.sh run needs only one key+Duo prompt.
: "${SSH_PERSIST:=600}"
SSH_SOCK="${SSH_SOCK:-$HOME/.cache/drac-opencode/mux-%C.sock}"
mkdir -p "$(dirname "$SSH_SOCK")"

# Cluster-side
: "${GPU_CONFIG:=a100:1}"
: "${CPUS:=4}"
: "${MEM:=16G}"
: "${TIME:=8:00:00}"
: "${SESSION:=opencode}"
: "${CONFIG_BASE:=${SCRATCH:-/scratch/$USER}/opencode}"

# Timeouts (seconds)
: "${READY_TIMEOUT:=1200}"
: "${OLLAMA_START_TIMEOUT:=300}"
: "${PULL_SERVE_TIMEOUT:=120}"

CONFIG_SIF="${CONFIG_SIF:-$CONFIG_BASE/ollama.sif}"
CONFIG_MODELS="${CONFIG_MODELS:-$CONFIG_BASE/models}"
CONFIG_STATUS="${CONFIG_STATUS:-$CONFIG_BASE/status.txt}"
CONFIG_LOG="${CONFIG_LOG:-$CONFIG_BASE/ollama.log}"

# Offline testing mode: when FAKE_REMOTE is set, path helpers return local
# paths instead of asking the cluster, so --dry-run works without network.
remote_dir() {
    if [[ -n "$FAKE_REMOTE" ]]; then
        echo "$FAKE_REMOTE"
    elif [[ -n "$REMOTE_DIR" ]]; then
        echo "$REMOTE_DIR"
    else
        ssh_run "${LOGIN_NODE}" 'echo "${SCRATCH:-$HOME}/opencode/remote"'
    fi
}

remote_path() {
    if [[ -n "$FAKE_REMOTE" ]]; then
        echo "$FAKE_REMOTE/$1"
    else
        ssh_run "${LOGIN_NODE}" "echo \"\${SCRATCH:-\$HOME}/opencode/$1\""
    fi
}

# Run ssh over the shared master connection (see SSH_SOCK above).
SSH_MUX_OPTS=(-o ControlMaster=auto -o ControlPath="$SSH_SOCK" -o ControlPersist="$SSH_PERSIST")
ssh_run() {
    ssh "${SSH_MUX_OPTS[@]}" "$@"
}

# Close the shared master connection, if any.
ssh_close() {
    ssh -O exit -o ControlPath="$SSH_SOCK" "$LOGIN_NODE" 2>/dev/null || true
}

# PORT is intentionally NOT exported: its :=11435 default is only a laptop-side
# fallback. An exported default would ride provision.sh -> tmux -> srun into
# run-ollama.sh, where PORT_FROM_ENV would treat it as a user pin and skip the
# per-session random roll. A port pinned on the login node (e.g.
# "PORT=7777 bash cluster/provision.sh") is already exported by the caller and
# still propagates.
export LOGIN_NODE MODEL REMOTE_DIR FAKE_REMOTE
export SSH_SOCK SSH_PERSIST
export GPU_CONFIG CPUS MEM TIME SESSION
export READY_TIMEOUT OLLAMA_START_TIMEOUT PULL_SERVE_TIMEOUT
export CONFIG_BASE CONFIG_SIF CONFIG_MODELS CONFIG_STATUS CONFIG_LOG
