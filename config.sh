#!/usr/bin/env bash
# Shared configuration for drac-opencode, sourced by both laptop/ and cluster/
# scripts. laptop/setup.sh rsyncs this repo to the cluster, so both sides use
# the same file. Every value can be overridden with an environment variable.

# Laptop-side
: "${LOGIN_NODE:=narval.alliancecan.ca}"
: "${PORT:=11435}"
: "${MODEL:=qwen3:14b}"
: "${REMOTE_DIR:=/home/$USER/drac-opencode}"
: "${FAKE_REMOTE:=}"

# Cluster-side
: "${GPU_CONFIG:=a100:1}"
: "${CPUS:=4}"
: "${MEM:=16G}"
: "${TIME:=8:00:00}"
: "${SESSION:=opencode}"
: "${CONFIG_BASE:=${SCRATCH:-/scratch/$USER}/opencode}"

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
        ssh "${LOGIN_NODE}" 'echo "${SCRATCH:-$HOME}/opencode/remote"'
    fi
}

remote_path() {
    if [[ -n "$FAKE_REMOTE" ]]; then
        echo "$FAKE_REMOTE/$1"
    else
        ssh "${LOGIN_NODE}" "echo \"\${SCRATCH:-\$HOME}/opencode/$1\""
    fi
}

export LOGIN_NODE PORT MODEL REMOTE_DIR FAKE_REMOTE
export GPU_CONFIG CPUS MEM TIME SESSION
export CONFIG_BASE CONFIG_SIF CONFIG_MODELS CONFIG_STATUS CONFIG_LOG
