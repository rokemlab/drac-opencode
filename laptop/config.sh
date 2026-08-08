#!/usr/bin/env bash
# Laptop-side configuration for drac-opencode. Source from other laptop
# scripts. Every value can be overridden with an environment variable.

: "${LOGIN_NODE:=narval.alliancecan.ca}"
: "${PORT:=11435}"
: "${MODEL:=qwen3:14b}"
: "${REMOTE_DIR:=/home/arokem/drac-opencode}"
: "${FAKE_REMOTE:=}"

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
