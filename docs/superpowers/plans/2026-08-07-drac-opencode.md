# drac-opencode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Container specs and scripts to run opencode with a GPU-backed Ollama model on Alliance Canada Slurm clusters, reached from the user's laptop over an encrypted SSH tunnel.

**Architecture:** An Apptainer image (based on the official `ollama/ollama` Docker image) serves Ollama on a compute node, localhost-only. A persistent tmux session on the login node holds an `srun` allocation; a wrapper writes a status file to `$SCRATCH/opencode/status.txt`. A laptop script provisions the session, reads the status file over SSH, opens a ProxyJump tunnel (`ssh -J <login> -L $PORT:127.0.0.1:$PORT <compute-host>`), and merges an OpenAI-compatible provider into `~/.config/opencode/opencode.json`.

**Tech Stack:** Bash 4+ scripts, Apptainer (def file + build), Slurm (`srun`, `tmux`), SSH (`-J`, `-L`), `rsync`, `jq`, Ollama.

## Global Constraints

- All cluster scripts source `cluster/config.sh`; all laptop scripts source `laptop/config.sh`. Do not duplicate configuration.
- Defaults, verbatim: `PORT=11434`, `GPU_COUNT=1`, `CPUS=4`, `MEM=24G`, `TIME=24:00:00`, `MODEL=qwen3:14b`, `SESSION=opencode`.
- Status file format is exactly: `host=<hostname>`, `port=<port>`, `model=<model>`, `ready=no` / `ready=yes` (appended). `status.sh` readiness check greps `^ready=yes$`.
- All cluster-side paths derive from `CONFIG_BASE` (`$SCRATCH/opencode`): `CONFIG_SIF=…/ollama.sif`, `CONFIG_MODELS=…/models`, `CONFIG_STATUS=…/status.txt`, `CONFIG_LOG=…/ollama.log`.
- Apptainer container runs with `--nv`, `--env OLLAMA_HOST=127.0.0.1:$PORT`, `--env OLLAMA_MODELS=/models`, `--env OLLAMA_CONTEXT_LENGTH=32768`, `--bind $CONFIG_MODELS:/models`. `OLLAMA_HOST` must bind loopback only (security requirement).
- Every script supports `-h`/`--help`. `cluster/provision.sh` and `laptop/connect.sh` support `--dry-run`.
- No code comments beyond the shebang/usage lines unless functionally necessary.
- Apptainer cannot run on macOS; `bash -n` and `shellcheck` are the local verification tools.

---

### Task 1: Container definition and build script

**Files:**
- Create: `container/ollama.def`
- Create: `container/build.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `container/build.sh [OUTPUT.sif]` — builds an Apptainer image from `container/ollama.def`, default output `$PWD/ollama.sif`. Exits 1 with a clear message if `apptainer` is not found.

- [ ] **Step 1: Create `container/ollama.def`**

```apptainer
Bootstrap: docker
From: ollama/ollama:latest

%environment
    export OLLAMA_HOST=127.0.0.1:11434
    export OLLAMA_MODELS=/models
    export OLLAMA_CONTEXT_LENGTH=32768

%runscript
    exec ollama serve
```

- [ ] **Step 2: Create `container/build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEF_FILE="$SCRIPT_DIR/ollama.def"
OUT="${1:-$PWD/ollama.sif}"

usage() {
    cat <<EOF
Usage: $0 [OUTPUT.sif]

Build the Apptainer image for GPU-backed Ollama on Alliance Canada clusters.

Arguments:
  OUTPUT.sif   Output image path (default: $PWD/ollama.sif)

Run this on an Alliance Canada login node (apptainer is not available on
macOS). The login node has internet access to fetch the base image.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v apptainer >/dev/null 2>&1; then
    echo "ERROR: apptainer not found in PATH." >&2
    echo "Run this on an Alliance Canada login node (e.g. narval, graham)." >&2
    echo "If apptainer is not on PATH, try: module load apptainer" >&2
    exit 1
fi

echo "Building $OUT from $DEF_FILE (downloads base image; can take several minutes)..."
apptainer build "$OUT" "$DEF_FILE"
echo "Done: $OUT"
```

- [ ] **Step 3: Make executable and verify syntax**

Run:
```bash
chmod +x container/build.sh
bash -n container/ollama.def
```
(Note: `bash -n` on the def file is only a placeholder syntax check; Apptainer validates it at build time on the cluster.)
Run:
```bash
bash -n container/build.sh
```
Expected: no output, exit code 0.

- [ ] **Step 4: Verify help and error handling**

Run:
```bash
./container/build.sh --help
```
Expected: prints usage, exit 0.
Run:
```bash
PATH=/usr/bin:/bin ./container/build.sh
```
Expected: "ERROR: apptainer not found in PATH." and exit 1.

- [ ] **Step 5: Commit**

```bash
git add container/ollama.def container/build.sh
git commit -m "Add apptainer ollama container and build script"
```

---

### Task 2: Cluster configuration and status script

**Files:**
- Create: `cluster/config.sh`
- Create: `cluster/status.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `cluster/config.sh` exports `PORT GPU_COUNT CPUS MEM TIME MODEL SESSION CONFIG_BASE CONFIG_SIF CONFIG_MODELS CONFIG_STATUS CONFIG_LOG`; all overridable via env. `cluster/status.sh` prints the status file; `cluster/status.sh --wait [SECONDS]` polls until `ready=yes` (default timeout 600s), exits 1 on timeout.

- [ ] **Step 1: Create `cluster/config.sh`**

```bash
#!/usr/bin/env bash
# Cluster-side configuration for drac-opencode. Source from other cluster
# scripts. Every value can be overridden with an environment variable.

: "${PORT:=11434}"
: "${GPU_COUNT:=1}"
: "${CPUS:=4}"
: "${MEM:=24G}"
: "${TIME:=24:00:00}"
: "${MODEL:=qwen3:14b}"
: "${SESSION:=opencode}"
: "${CONFIG_BASE:=${SCRATCH:-/scratch/$USER}/opencode}"

CONFIG_SIF="${CONFIG_SIF:-$CONFIG_BASE/ollama.sif}"
CONFIG_MODELS="${CONFIG_MODELS:-$CONFIG_BASE/models}"
CONFIG_STATUS="${CONFIG_STATUS:-$CONFIG_BASE/status.txt}"
CONFIG_LOG="${CONFIG_LOG:-$CONFIG_BASE/ollama.log}"

export PORT GPU_COUNT CPUS MEM TIME MODEL SESSION
export CONFIG_BASE CONFIG_SIF CONFIG_MODELS CONFIG_STATUS CONFIG_LOG
```

- [ ] **Step 2: Create `cluster/status.sh`**

```bash
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
```

- [ ] **Step 3: Verify syntax and help**

Run:
```bash
chmod +x cluster/status.sh
bash -n cluster/config.sh
bash -n cluster/status.sh
```
Expected: no output for both.
Run:
```bash
./cluster/status.sh --help
```
Expected: prints usage, exit 0.

- [ ] **Step 4: Commit**

```bash
git add cluster/config.sh cluster/status.sh
git commit -m "Add cluster config and status scripts"
```

---

### Task 3: Compute-node runner

**Files:**
- Create: `cluster/run-ollama.sh`

**Interfaces:**
- Consumes: `cluster/config.sh` exports (Task 2); `$CONFIG_SIF` must exist (built in Task 1).
- Produces: writes `$CONFIG_STATUS` (`host=`, `port=`, `model=`, `ready=no` then appends `ready=yes`); writes serve output to `$CONFIG_LOG`; keeps the allocation alive by `wait`-ing on the serve process. Consumed by `cluster/status.sh` and `laptop/connect.sh`.

- [ ] **Step 1: Create `cluster/run-ollama.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

mkdir -p "$CONFIG_BASE" "$CONFIG_MODELS"

HOST_SHORT="$(hostname)"
{
    echo "host=$HOST_SHORT"
    echo "port=$PORT"
    echo "model=$MODEL"
    echo "ready=no"
} > "$CONFIG_STATUS"

echo "=== opencode GPU session on $HOST_SHORT ==="
echo "Model: $MODEL  |  Port: $PORT  |  Status: $CONFIG_STATUS"

if [[ ! -f "$CONFIG_SIF" ]]; then
    echo "ERROR: container image not found at $CONFIG_SIF" >&2
    echo "Build it first: container/build.sh (see README)." >&2
    exit 1
fi

echo "Starting ollama serve inside apptainer..."
apptainer run \
    --nv \
    --env "OLLAMA_HOST=127.0.0.1:$PORT" \
    --env "OLLAMA_MODELS=/models" \
    --env "OLLAMA_CONTEXT_LENGTH=32768" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" \
    >"$CONFIG_LOG" 2>&1 &
SERVE_PID=$!

echo "Waiting for ollama to listen on 127.0.0.1:$PORT..."
ready=0
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$PORT/api/tags" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$SERVE_PID" 2>/dev/null; then
        echo "ERROR: ollama serve exited early." >&2
        tail -20 "$CONFIG_LOG" >&2
        exit 1
    fi
    sleep 5
done

if [[ $ready -eq 0 ]]; then
    echo "ERROR: ollama did not respond within 300s." >&2
    echo "Log: $CONFIG_LOG" >&2
    exit 1
fi

echo "Pulling model $MODEL (first time only)..."
if ! apptainer exec \
    --env "OLLAMA_HOST=127.0.0.1:$PORT" \
    --env "OLLAMA_MODELS=/models" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" \
    ollama pull "$MODEL"; then
    echo "WARNING: model pull failed; the server is still running." >&2
    echo "Retry later with: apptainer exec <sif> ollama pull $MODEL" >&2
fi

echo "ready=yes" >> "$CONFIG_STATUS"

echo
echo "============================================================"
echo " READY: opencode GPU session live on $HOST_SHORT"
echo " Model: $MODEL  |  Port: $PORT"
echo " From your laptop run: laptop/connect.sh"
echo "============================================================"

wait "$SERVE_PID"
```

- [ ] **Step 2: Verify syntax**

Run:
```bash
chmod +x cluster/run-ollama.sh
bash -n cluster/run-ollama.sh
```
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add cluster/run-ollama.sh
git commit -m "Add compute-node ollama runner script"
```

---

### Task 4: Provision and teardown

**Files:**
- Create: `cluster/provision.sh`
- Create: `cluster/teardown.sh`

**Interfaces:**
- Consumes: `cluster/config.sh` exports; `$CONFIG_SIF` must exist.
- Produces: `cluster/provision.sh` creates a tmux session named `$SESSION` running `srun --gpus=$GPU_COUNT --cpus-per-task=$CPUS --mem=$MEM --time=$TIME --pty bash run-ollama.sh`; exits 1 if session already exists or SIF missing. `cluster/teardown.sh` kills the tmux session and removes `$CONFIG_STATUS`.

- [ ] **Step 1: Create `cluster/provision.sh`**

```bash
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
```

- [ ] **Step 2: Create `cluster/teardown.sh`**

```bash
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
```

- [ ] **Step 3: Verify syntax, help, and dry-run**

Run:
```bash
chmod +x cluster/provision.sh cluster/teardown.sh
bash -n cluster/provision.sh
bash -n cluster/teardown.sh
```
Expected: no output for both.
Run:
```bash
mkdir -p /tmp/drac-test/opencode && touch /tmp/drac-test/opencode/ollama.sif
CONFIG_BASE=/tmp/drac-test/opencode ./cluster/provision.sh --dry-run
```
Expected: prints `srun command: srun --gpus=1 --cpus-per-task=4 --mem=24G --time=24:00:00 --pty bash <abs>/cluster/run-ollama.sh` then `(dry run -- nothing started)`.
Run:
```bash
./cluster/teardown.sh --help
```
Expected: prints usage, exit 0.

- [ ] **Step 4: Commit**

```bash
git add cluster/provision.sh cluster/teardown.sh
git commit -m "Add session provision and teardown scripts"
```

---

### Task 5: Laptop configuration and one-time setup

**Files:**
- Create: `laptop/config.sh`
- Create: `laptop/setup.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `laptop/config.sh` exports `LOGIN_NODE PORT REMOTE_DIR FAKE_REMOTE MODEL` and defines helpers `remote_dir` (prints remote repo dir) and `remote_path <name>` (prints `$SCRATCH/opencode/<name>` on the cluster). When `FAKE_REMOTE` is set, both helpers return local paths without SSH so `--dry-run` works offline. `laptop/setup.sh` rsyncs the repo to the cluster and builds the SIF if missing.

- [ ] **Step 1: Create `laptop/config.sh`**

```bash
#!/usr/bin/env bash
# Laptop-side configuration for drac-opencode. Source from other laptop
# scripts. Every value can be overridden with an environment variable.

: "${LOGIN_NODE:=narval.calculquebec.ca}"
: "${PORT:=11434}"
: "${MODEL:=qwen3:14b}"
: "${REMOTE_DIR:=}"
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
```

- [ ] **Step 2: Create `laptop/setup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

usage() {
    cat <<EOF
Usage: $0

One-time setup: sync this repo to the cluster and build the Apptainer image
if it does not exist yet.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v ssh >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: ssh and rsync are both required." >&2
    exit 1
fi

REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE="$(remote_dir)"

echo "Syncing $REPO to $LOGIN_NODE:$REMOTE ..."
ssh "$LOGIN_NODE" "mkdir -p '$REMOTE'"
rsync -a --delete --exclude '.git' "$REPO/" "$LOGIN_NODE:$REMOTE/"

SIF_PATH="$(remote_path ollama.sif)"
if ssh "$LOGIN_NODE" "[[ -f '$SIF_PATH' ]]"; then
    echo "Container image already exists at $SIF_PATH"
else
    echo "Container image missing -- building on $LOGIN_NODE (can take several minutes)..."
    ssh "$LOGIN_NODE" "cd '$REMOTE/container' && ./build.sh '$SIF_PATH'"
fi

echo "Setup complete."
```

- [ ] **Step 3: Verify syntax, help, and offline dry-run**

Run:
```bash
chmod +x laptop/setup.sh
bash -n laptop/config.sh
bash -n laptop/setup.sh
```
Expected: no output for both.
Run:
```bash
./laptop/setup.sh --help
```
Expected: prints usage, exit 0.
Run (offline path helper smoke test):
```bash
FAKE_REMOTE=/tmp/drac-test/remote bash -c 'source laptop/config.sh; remote_dir; remote_path status.txt'
```
Expected:
```
/tmp/drac-test/remote
/tmp/drac-test/remote/status.txt
```

- [ ] **Step 4: Commit**

```bash
git add laptop/config.sh laptop/setup.sh
git commit -m "Add laptop config and cluster setup script"
```

---

### Task 6: Laptop connect and disconnect

**Files:**
- Create: `laptop/connect.sh`
- Create: `laptop/disconnect.sh`

**Interfaces:**
- Consumes: `laptop/config.sh` helpers `remote_dir`, `remote_path` (Task 5); `cluster/provision.sh`, `cluster/status.sh` (Tasks 2, 4); the status file from Task 3; `jq` and `lsof` on the laptop.
- Produces: `laptop/connect.sh` runs provision remotely, waits for readiness, opens the tunnel as a background process, records its PID in `$HOME/.opencode-tunnel-$PORT.pid`, verifies `http://127.0.0.1:$PORT/api/tags`, and merges the `drac-ollama` provider into `~/.config/opencode/opencode.json` (backing up first; refuses to touch unparseable JSON). `laptop/disconnect.sh` kills the PID from the pid file.

- [ ] **Step 1: Create `laptop/connect.sh`**

```bash
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

echo "==> Waiting for the Ollama server (queue wait can take minutes)..."
if [[ $DRY_RUN -eq 1 ]]; then
    HOST="dryrun-node"
else
    if ! ssh "$LOGIN_NODE" "bash '$REMOTE/cluster/status.sh' --wait 600"; then
        echo "ERROR: session did not become ready in time." >&2
        echo "Inspect: ssh $LOGIN_NODE 'cat '\"\$SCRATCH\"/opencode/ollama.log'"'" >&2
        exit 1
    fi
    HOST="$(ssh "$LOGIN_NODE" "grep '^host=' '$STATUS_REMOTE' | cut -d= -f2")"
    MODEL="$(ssh "$LOGIN_NODE" "grep '^model=' '$STATUS_REMOTE' | cut -d= -f2")"
fi

if [[ -z "$HOST" ]]; then
    echo "ERROR: could not determine compute node hostname." >&2
    exit 1
fi

echo "==> Ollama server is on compute node $HOST (port $PORT)"

if lsof -i "tcp:$PORT" >/dev/null 2>&1; then
    echo "WARNING: 127.0.0.1:$PORT is already in use locally." >&2
    echo "Set PORT to a free value in laptop/config.sh and cluster/config.sh." >&2
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] ssh -J $LOGIN_NODE -N -L $PORT:127.0.0.1:$PORT -o ExitOnForwardFailure=yes $HOST &"
    echo "999999" > "$TUNNEL_PID_FILE"
else
    ssh -J "$LOGIN_NODE" -N -L "$PORT:127.0.0.1:$PORT" -o ExitOnForwardFailure=yes "$HOST" &
    TUNNEL_PID=$!
    echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
    echo "==> Tunnel open on 127.0.0.1:$PORT (pid $TUNNEL_PID)"
fi

echo "==> Verifying local endpoint..."
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] curl http://127.0.0.1:$PORT/api/tags"
else
    ok=0
    for _ in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:$PORT/api/tags" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    if [[ $ok -eq 0 ]]; then
        echo "ERROR: tunneled endpoint not reachable at 127.0.0.1:$PORT." >&2
        exit 1
    fi
fi

echo "==> Configuring opencode for $MODEL via http://127.0.0.1:$PORT/v1"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] configure_opencode $PORT $MODEL"
else
    configure_opencode "$PORT" "$MODEL"
fi

echo
echo "READY. Run: opencode"
echo "Model: $MODEL  |  Endpoint: http://127.0.0.1:$PORT/v1"
echo "Stop tunnel: laptop/disconnect.sh  |  Free GPU: ssh $LOGIN_NODE 'cd $REMOTE && bash cluster/teardown.sh'"
```

- [ ] **Step 2: Create `laptop/disconnect.sh`**

```bash
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
echo "The remote GPU session is still running."
echo "Reconnect:              laptop/connect.sh"
echo "Stop session, free GPU: ssh $LOGIN_NODE 'cd $REMOTE && bash cluster/teardown.sh'"
```

- [ ] **Step 3: Verify syntax, help, and offline dry-run**

Run:
```bash
chmod +x laptop/connect.sh laptop/disconnect.sh
bash -n laptop/connect.sh
bash -n laptop/disconnect.sh
```
Expected: no output for both.
Run (offline dry-run — no cluster access required):
```bash
FAKE_REMOTE=/tmp/drac-test/remote ./laptop/connect.sh --dry-run
```
Expected: prints `[dry-run] ssh <login> "cd '/tmp/drac-test/remote' && bash cluster/provision.sh"`, then `==> Waiting...`, `==> Ollama server is on compute node dryrun-node (port 11434)`, `[dry-run] ssh -J ...`, `==> Configuring opencode...` with `[dry-run] configure_opencode 11434 qwen3:14b`, then the READY block. No real SSH, no config file changes.

- [ ] **Step 4: Verify the opencode config merge logic locally**

Verify the exact jq pipeline `configure_opencode` uses (builds the provider object, then merges it into an existing config, preserving other providers):
Run:
```bash
jq -n --arg base "http://127.0.0.1:11434/v1" --arg model "qwen3:14b" '{provider: {("drac-ollama"): {npm: "@ai-sdk/openai-compatible", name: "DRAC Ollama", options: {baseURL: $base}, models: {($model): {name: ("DRAC " + $model)}}}}}' > /tmp/drac-test/provider.json
jq --argjson p "$(cat /tmp/drac-test/provider.json)" '.provider = ((.provider // {}) | del(.["drac-ollama"]) | . + $p.provider)' <<< '{"provider":{"anthropic":{"options":{"baseURL":"https://example"}}}}'
```
Expected: a merged object with both `anthropic` (untouched) and `drac-ollama` providers, `drac-ollama.options.baseURL` equal to `http://127.0.0.1:11434/v1`, and model key `qwen3:14b`.

- [ ] **Step 5: Commit**

```bash
git add laptop/connect.sh laptop/disconnect.sh
git commit -m "Add laptop connect and disconnect scripts"
```

---

### Task 7: README and usage documentation

**Files:**
- Create: `README.md`
- Create: `docs/usage.md`

**Interfaces:**
- Consumes: all scripts (Tasks 1-6).
- Produces: setup/usage instructions and the manual test checklist.

- [ ] **Step 1: Create `README.md`**

```markdown
# drac-opencode

Run `opencode` with a GPU-backed local model on Digital Research Alliance of
Canada (Alliance Canada) Slurm clusters. Ollama serves the model on a compute
node; a script on your laptop opens an encrypted SSH tunnel to it and points
opencode at the endpoint.

## How it works

1. **Once per cluster:** `laptop/setup.sh` syncs the repo to the cluster and
   builds an Apptainer image (`ollama.sif`) from `container/ollama.def`.
2. **Each session:** `laptop/connect.sh` starts a persistent tmux session on
   the login node, which runs `srun` to grab a GPU node and launches `ollama
   serve` inside the container (localhost-only, model stored on `$SCRATCH`).
   The laptop then opens `ssh -J <login> -L $PORT:127.0.0.1:$PORT <node>`,
   verifies the endpoint, and adds a `drac-ollama` provider to opencode.
3. **When done:** `laptop/disconnect.sh` kills the tunnel; 
   `ssh <login> 'cd <remote> && bash cluster/teardown.sh'` frees the GPU.

## Quick start

```bash
# 1. On your laptop: configure
#    Edit laptop/config.sh: LOGIN_NODE, PORT, MODEL
./laptop/setup.sh                             # sync repo + build image (once)

# 2. On your laptop: connect and run
./laptop/connect.sh
opencode                                    # select the drac-ollama model
```

## Requirements

- An Alliance Canada account with an allocation (RAC/RAS) that includes GPU nodes.
- `ssh`, `rsync`, `jq` on your laptop.
- `apptainer` on the cluster login node (try `module load apptainer` if needed).

See `docs/usage.md` for details, per-cluster notes, troubleshooting, and the
manual test checklist.
```

- [ ] **Step 2: Create `docs/usage.md`**

```markdown
# drac-opencode usage

## Configuration

- `laptop/config.sh` — `LOGIN_NODE`, `PORT`, `MODEL` (default `qwen3:14b`).
- `cluster/config.sh` — `GPU_COUNT`, `CPUS`, `MEM`, `TIME`, `MODEL`, `SESSION`.
  Every value can also be set as an environment variable on the command line,
  e.g. `MODEL=qwen3:32b TIME=48:00:00 ./laptop/connect.sh`.

Keep `PORT` in sync between `laptop/config.sh` and `cluster/config.sh`.

## Per-cluster notes

- Max `TIME` limits vary by cluster/partition (check with
  `sacctmgr show qos format=name,maxtresperuser` or `squeue --account`).
  Default `TIME=24:00:00` is safe on all general partitions.
- Narval and Beluga (A100 40GB) run `qwen3:14b` comfortably; Graham/Cedar
  (V100/P100) also fit it.
- If `apptainer` is not on PATH on the login node, try `module load apptainer`.

## Troubleshooting

- `apptainer: command not found` — load the module, see above.
- `session did not become ready` — `ssh <login> 'tail -n 40 $SCRATCH/opencode/ollama.log'`
- `127.0.0.1:$PORT is already in use` — pick a free port in both config files.
- Model pull failed but server runs — `apptainer exec <sif> ollama pull <model>`
- opencode shows no `drac-ollama` models — check the endpoint:
  `curl http://127.0.0.1:$PORT/v1/models`, then re-run `./laptop/connect.sh`.

## Manual test checklist

Run these once on a real cluster after setup to validate the whole stack:

- [ ] `laptop/setup.sh` completes and `ollama.sif` exists on the cluster.
- [ ] `ssh <login> 'bash <remote>/cluster/provision.sh --dry-run'` prints the srun command.
- [ ] `./laptop/connect.sh` reaches the `READY` banner.
- [ ] `curl http://127.0.0.1:$PORT/api/tags` lists the model on the laptop.
- [ ] `curl http://127.0.0.1:$PORT/v1/models` returns an OpenAI-style model list.
- [ ] `opencode` starts and the `drac-ollama` provider/model is selectable.
- [ ] `./laptop/disconnect.sh` kills the tunnel; endpoint no longer responds.
- [ ] `ssh <login> 'cd <remote> && bash cluster/teardown.sh'` frees the GPU
      (`squeue -u $USER` is empty for the session).
```

- [ ] **Step 3: Verify README commands are accurate**

Run:
```bash
git status
```
Expected: `git status` shows `README.md`, `docs/usage.md` as untracked.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/usage.md
git commit -m "Add README and usage documentation"
```

---

## Final verification

- [ ] `bash -n` passes on every script: `container/build.sh`, `cluster/config.sh`, `cluster/status.sh`, `cluster/run-ollama.sh`, `cluster/provision.sh`, `cluster/teardown.sh`, `laptop/config.sh`, `laptop/setup.sh`, `laptop/connect.sh`, `laptop/disconnect.sh`.
- [ ] If `shellcheck` is installed, run `shellcheck` on every `.sh` file; all pass clean.
- [ ] `FAKE_REMOTE=/tmp/drac-test/remote ./laptop/connect.sh --dry-run` and `CONFIG_BASE=/tmp/drac-test/opencode ./cluster/provision.sh --dry-run` both complete successfully.
- [ ] Repo has 7 logical commits, one per task.
