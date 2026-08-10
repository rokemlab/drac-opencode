# Multi-Model drac-opencode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a single drac-opencode session serve multiple Ollama models from one GPU allocation and write them all (plus a `reasoner` agent) into the laptop's `opencode.json`.

**Architecture:** `MODELS` (space-separated list) in `config.sh` is the single source of truth. `pull-model.sh` pulls every listed model into the shared store; `run-ollama.sh` verifies every manifest and reports `models=` in the status file; `connect.sh` reads that list, builds a `drac-ollama` provider with one entry per model via `jq`, and merges the `reasoner` agent from a repo template. Serving/tunnel/SSH-mux plumbing is unchanged — ollama serves any model from one server.

**Tech Stack:** bash (no new dependencies), `jq` (already required), `apptainer`, ollama, OpenSSH mux. Reference spec: `docs/superpowers/specs/2026-08-10-multi-model-design.md`.

## Global Constraints

- Work on the `multi-model` branch (created). Commit after each task; do not touch `main`.
- Follow existing style: `set -euo pipefail` in scripts that have it, config values env-overridable via `: "${VAR:=default}"`, remote commands go through `ssh_run` (mux) in laptop scripts, path helpers `remote_dir`/`remote_path`.
- The shared `config.sh` is sourced by both laptop and cluster scripts; keep its export list consistent with what scripts reference.
- **config.sh working-tree state:** `config.sh` currently carries an uncommitted `: "${MODEL:=olmo-3}"` line (user experiment). Task 1 replaces that whole block, so the superseded value must never appear in any commit — stage `config.sh` normally (no backup/restore dance needed this time).
- `model=` status field becomes `models=`; update every consumer (only `laptop/connect.sh`) and the docs.
- Do not modify historical files under `docs/superpowers/` (2026-08-07 spec/plan).
- All verification is offline (no cluster SSH / 2FA): stub `ssh`, `rsync`, `apptainer`, `curl`, `hostname`, `ip` on `PATH` + temp `HOME` + temp `CONFIG_BASE`.

---

### Task 1: `MODELS` list in config.sh

**Files:**
- Modify: `config.sh:15-16` (MODEL default block), `config.sh:76` (export line)

**Interfaces:**
- Consumes: nothing.
- Produces: exported `MODELS` (space-separated string, default `olmo-3:7b-instruct olmo-3:7b-think`). `MODEL` no longer exported; if the caller sets `MODEL` and `MODELS` is unset, `MODELS` is seeded from it.

- [ ] **Step 1: Write the failing verification commands**

```bash
bash -n config.sh && echo OK
MODELS_DFLT="$(source config.sh && echo "$MODELS")"
[ "$MODELS_DFLT" = "olmo-3:7b-instruct olmo-3:7b-think" ] || echo "FAIL: default is '$MODELS_DFLT'"
(source config.sh; env | grep -q '^MODELS=') || echo "FAIL: MODELS not exported"
[ "$(MODEL=qwen3:14b bash -c 'source config.sh; echo "$MODELS"')" = "qwen3:14b" ] || echo "FAIL: MODEL bridge"
[ "$(MODELS='a:1 b:2' MODEL=qwen3:14b bash -c 'source config.sh; echo "$MODELS"')" = "a:1 b:2" ] || echo "FAIL: MODELS should win over MODEL"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash -n config.sh && echo OK` then the assertions above.
Expected: `MODELS` is unset today, so the default and export assertions FAIL (`MODELS_DFLT` is empty; `MODELS not exported` prints).

- [ ] **Step 3: Implement**

Edit `config.sh`. Replace lines 15-16:

```bash
#: "${MODEL:=qwen3:14b}"
: "${MODEL:=olmo-3}"
```

with:

```bash
# MODELS is the space-separated list of models this session serves. Ollama
# serves them all from one server/port; ollama loads whichever is requested.
# MODEL is deprecated: if MODELS is unset but MODEL is set, seed MODELS from it
# (keeps single-model overrides like "MODEL=qwen3:14b bash cluster/provision.sh"
# working).
if [[ -z "${MODELS:-}" && -n "${MODEL:-}" ]]; then
    MODELS="$MODEL"
fi
: "${MODELS:=olmo-3:7b-instruct olmo-3:7b-think}"
```

Note: the bridge check must run BEFORE the `:=` default (if the default ran first, it would fill `MODELS` and make the bridge dead code, breaking the Step 1 assertion `MODEL=qwen3:14b ... echo "$MODELS"` = `qwen3:14b`).

Edit the export line (currently `export LOGIN_NODE MODEL REMOTE_DIR FAKE_REMOTE`) to:

```bash
export LOGIN_NODE MODELS REMOTE_DIR FAKE_REMOTE
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash -n config.sh` (OK) then the Step 1 assertion block. Expected: no `FAIL:` lines.

- [ ] **Step 5: Commit**

```bash
git add config.sh
git commit -m "Add MODELS list to config; deprecate MODEL"
```

---

### Task 2: `cluster/pull-model.sh` pulls every model

**Files:**
- Modify: `cluster/pull-model.sh:26-31` (usage text), `:47-85` (manifest check + pull)

**Interfaces:**
- Consumes: `MODELS` (space-separated, from Task 1), `CONFIG_MODELS`, `CONFIG_SIF`, `PULL_PORT`, `apptainer`.
- Produces: every model in `MODELS` present under `CONFIG_MODELS`; exit 0 if all present (or pulled), non-zero on any failure. Same CLI as before (no args).

- [ ] **Step 1: Write the failing verification (offline pull harness)**

Create `/tmp/drac-mm/bin/{apptainer,curl}` and a fake SIF:

```bash
rm -rf /tmp/drac-mm && mkdir -p /tmp/drac-mm/bin /tmp/drac-mm/state
cat > /tmp/drac-mm/bin/curl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > /tmp/drac-mm/bin/apptainer <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "run" ]]; then sleep 2; exit 0; fi
if [[ "$1" == "exec" ]]; then
    m=""
    for ((i=1; i<=$#; i++)); do [[ "${!i}" == "pull" ]] && m="${@:i+1:1}"; done
    if [[ -n "$m" ]]; then
        f="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
        mkdir -p "$(dirname "$f")"
        touch "$f"
        echo "pulled:$m"
    fi
fi
exit 0
EOF
chmod +x /tmp/drac-mm/bin/curl /tmp/drac-mm/bin/apptainer
touch /tmp/drac-mm/state/fake.sif
mkdir -p /tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/olmo-3/7b-instruct
touch /tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/olmo-3/7b-instruct
# note: the manifest path must be a regular FILE (the script checks -f), so the
# above touch must land on a file, not re-mkdir the same path.
```

- [ ] **Step 2: Run to verify it fails**

```bash
PATH="/tmp/drac-mm/bin:$PATH" CONFIG_BASE=/tmp/drac-mm/state CONFIG_SIF=/tmp/drac-mm/state/fake.sif \
    MODELS="olmo-3:7b-instruct olmo-3:7b-think" bash cluster/pull-model.sh
```

Expected (against current code): FAIL — current script only handles a single
`$MODEL` (empty here, since only `MODELS` is set), so `olmo-3:7b-think` is
never pulled and per-model presence is not reported.

- [ ] **Step 3: Implement**

Rewrite `cluster/pull-model.sh` from the usage text and the manifest/pull section. Keep lines 1-45 (shebang, CVMFS/module init, config source, usage guard, SIF check, `mkdir -p "$CONFIG_MODELS"`).

New usage text (replace lines 26-31):

```bash
Usage: $0

Ensure every model in MODELS is available on the cluster. Runs on a login
node, which has internet access (compute nodes do not). Pulls any missing
model from MODELS into \$CONFIG_MODELS.

Exit 0 if all models are already present; pulls missing ones otherwise.
```

Replace everything from line 47 (`MANIFEST=...`) to the end with:

```bash
if [[ -z "${MODELS:-}" ]]; then
    echo "ERROR: MODELS is empty; nothing to pull." >&2
    exit 1
fi

missing=()
for m in $MODELS; do
    MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
    if [[ -f "$MANIFEST" ]]; then
        echo "Model $m already present at $CONFIG_MODELS."
    else
        missing+=("$m")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    exit 0
fi

PULL_PORT="${PULL_PORT:-11435}"
echo "Pulling missing models: ${missing[*]} (first time only; can take several minutes)..."
apptainer run \
    --env "OLLAMA_HOST=127.0.0.1:$PULL_PORT" \
    --env "OLLAMA_MODELS=/models" \
    --bind "$CONFIG_MODELS:/models" \
    "$CONFIG_SIF" &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null || true' EXIT

up=0
deadline=$(( $(date +%s) + PULL_SERVE_TIMEOUT ))
while [[ $(date +%s) -lt $deadline ]]; do
    if curl -sf "http://127.0.0.1:$PULL_PORT/api/tags" >/dev/null 2>&1; then
        up=1
        break
    fi
    sleep 2
done

if [[ $up -eq 0 ]]; then
    echo "ERROR: ollama serve did not start on this node." >&2
    exit 1
fi

for m in "${missing[@]}"; do
    echo "Pulling $m ..."
    apptainer exec \
        --env "OLLAMA_HOST=127.0.0.1:$PULL_PORT" \
        --env "OLLAMA_MODELS=/models" \
        --bind "$CONFIG_MODELS:/models" \
        "$CONFIG_SIF" \
        ollama pull "$m"
    MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
    if [[ ! -f "$MANIFEST" ]]; then
        echo "ERROR: pull of $m did not produce a manifest." >&2
        exit 1
    fi
    echo "Model $m ready in $CONFIG_MODELS."
done
```

- [ ] **Step 4: Run to verify it passes**

```bash
bash -n cluster/pull-model.sh
rm -rf /tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/olmo-3/7b-think
PATH="/tmp/drac-mm/bin:$PATH" CONFIG_BASE=/tmp/drac-mm/state CONFIG_SIF=/tmp/drac-mm/state/fake.sif \
    MODELS="olmo-3:7b-instruct olmo-3:7b-think" bash cluster/pull-model.sh
```

Expected: prints `Model olmo-3:7b-instruct already present...`, `Pulling missing models: olmo-3:7b-think`, `pulled:olmo-3:7b-think`, `Model olmo-3:7b-think ready...`, exit 0. Re-run the same command: both "already present", exit 0.

- [ ] **Step 5: Commit**

```bash
git add cluster/pull-model.sh
git commit -m "Pull every model in MODELS"
```

---

### Task 3: `cluster/run-ollama.sh` verifies all models and reports `models=`

**Files:**
- Modify: `cluster/run-ollama.sh:56-62` (status write), `:65` (banner), `:107-114` (manifest check), `:121` (ready banner)

**Interfaces:**
- Consumes: `MODELS` (Task 1), `CONFIG_MODELS`, `CONFIG_SIF`, `CONFIG_STATUS`, `CONFIG_LOG`, `OLLAMA_START_TIMEOUT`, `apptainer`, `curl`.
- Produces: status file field `models=<space-separated MODELS>` (replaces `model=`), plus existing `host=`/`ip=`/`port=`/`ready=`; non-zero exit with a clear message listing any missing model manifest.

- [ ] **Step 1: Write the failing verification (offline run harness)**

```bash
mkdir -p /tmp/drac-mm/bin
cat > /tmp/drac-mm/bin/hostname <<'EOF'
#!/usr/bin/env bash
echo fakehost
EOF
cat > /tmp/drac-mm/bin/ip <<'EOF'
#!/usr/bin/env bash
echo "    inet 10.0.0.5/24 brd 10.0.0.255 scope global dynamic fake0"
EOF
cat > /tmp/drac-mm/bin/curl <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > /tmp/drac-mm/bin/apptainer <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "run" ]]; then sleep 30; exit 0; fi
exit 0
EOF
chmod +x /tmp/drac-mm/bin/*

# pre-seed state needed by the happy path (not guaranteed to persist from
# Task 2's harness): fake SIF plus both manifest FILES (the script checks -f)
mkdir -p /tmp/drac-mm/state && touch /tmp/drac-mm/state/fake.sif
mkdir -p /tmp/drac-mm/state/models
for p in olmo-3/7b-instruct olmo-3/7b-think; do
    mkdir -p "/tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/$(dirname "$p")"
    touch "/tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/$p"
done

assert_status() {
    local f=/tmp/drac-mm/state/status.txt
    grep -q '^models=olmo-3:7b-instruct olmo-3:7b-think$' "$f" || echo "FAIL: models= line"
    grep -q '^ready=yes$' "$f" || echo "FAIL: ready=yes"
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
PATH="/tmp/drac-mm/bin:$PATH" CONFIG_BASE=/tmp/drac-mm/state CONFIG_SIF=/tmp/drac-mm/state/fake.sif \
    MODELS="olmo-3:7b-instruct olmo-3:7b-think" bash cluster/run-ollama.sh; echo "rc=$?"
```

Expected (against current code): FAIL — status file has `model=` (not `models=`), and the manifest check only inspects `$MODEL` (unset → `MODEL#*:` = `olmo-3`, manifest missing → error exit). Either way `assert_status` fails.

- [ ] **Step 3: Implement**

Edit `cluster/run-ollama.sh`.

Status write block (lines 56-62): change `echo "model=$MODEL"` to:

```bash
    echo "models=$MODELS"
```

Banner (line 65): change `echo "Model: $MODEL  |  Port: $PORT ..."` to:

```bash
echo "Models: $MODELS  |  Port: $PORT  |  Node IP: $NODE_IP  |  Status: $CONFIG_STATUS"
```

Manifest check (lines 107-114) — replace the single-model block:

```bash
echo "Checking models are present..."
missing=()
for m in $MODELS; do
    MANIFEST="$CONFIG_MODELS/manifests/registry.ollama.ai/library/${m%:*}/${m#*:}"
    if [[ ! -f "$MANIFEST" ]]; then
        missing+=("$m")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: model(s) not found at $CONFIG_MODELS: ${missing[*]}" >&2
    echo "Compute nodes have no internet; pull them on the login node with:" >&2
    echo "  bash cluster/pull-model.sh  (runs automatically from provision.sh)" >&2
    exit 1
fi
```

Ready banner (line 121): change `echo " Model: $MODEL  |  Port: $PORT"` to:

```bash
echo " Models: $MODELS  |  Port: $PORT"
```

- [ ] **Step 4: Run to verify it passes**

The `assert_status` `ready=yes` check cannot run AFTER the script exits: by design
`cluster/run-ollama.sh` has an EXIT trap that rewrites `ready=no` (the server is
gone once the script exits). So run the script in the background, poll the status
file while it is alive, then kill it.

```bash
bash -n cluster/run-ollama.sh
rm -f /tmp/drac-mm/state/status.txt
PATH="/tmp/drac-mm/bin:$PATH" CONFIG_BASE=/tmp/drac-mm/state CONFIG_SIF=/tmp/drac-mm/state/fake.sif \
    MODELS="olmo-3:7b-instruct olmo-3:7b-think" bash cluster/run-ollama.sh &
RP=$!
ok=0
for i in $(seq 1 40); do
    if grep -q '^ready=yes$' /tmp/drac-mm/state/status.txt 2>/dev/null; then ok=1; break; fi
    sleep 0.5
done
assert_status
[ "$ok" = "1" ] || echo "FAIL: ready=yes never observed during live run"
kill "$RP" 2>/dev/null; wait "$RP" 2>/dev/null
echo "--- missing-manifest error path ---"
rm -rf /tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/olmo-3/7b-think
PATH="/tmp/drac-mm/bin:$PATH" CONFIG_BASE=/tmp/drac-mm/state CONFIG_SIF=/tmp/drac-mm/state/fake.sif \
    MODELS="olmo-3:7b-instruct olmo-3:7b-think" bash cluster/run-ollama.sh 2>&1 | grep -q 'olmo-3:7b-think' && echo "error lists missing model"
f=/tmp/drac-mm/state/models/manifests/registry.ollama.ai/library/olmo-3/7b-think
mkdir -p "$(dirname "$f")" && touch "$f"
```

Expected: `assert_status` silent (status file contains `models=olmo-3:7b-instruct olmo-3:7b-think`); `ready=yes` observed while the backgrounded script is alive; error path prints a message naming `olmo-3:7b-think` (rc non-zero).

- [ ] **Step 5: Commit**

```bash
git add cluster/run-ollama.sh
git commit -m "Verify all MODELS and report models= in the status file"
```

---

### Task 4: `laptop/reasoner.agent.json` template

**Files:**
- Create: `laptop/reasoner.agent.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a JSON object to be merged under `.agent` in `opencode.json` (shape `{"reasoner": {...}}`), consumed by Task 5.

- [ ] **Step 1: Write the failing verification**

```bash
jq -e . laptop/reasoner.agent.json && echo PARSES
```

- [ ] **Step 2: Run to verify it fails**

Expected: file does not exist yet → `jq: No such file or directory`, non-zero.

- [ ] **Step 3: Implement**

Create `laptop/reasoner.agent.json`:

```json
{
  "reasoner": {
    "description": "Deep reasoning with Olmo 3 Think — no tool access, chat/analysis only",
    "mode": "primary",
    "model": "drac-ollama/olmo-3:7b-think",
    "permission": {
      "edit": "deny",
      "bash": "deny",
      "webfetch": "deny",
      "task": "deny"
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
jq -e . laptop/reasoner.agent.json && echo PARSES
jq -r '.reasoner.model' laptop/reasoner.agent.json   # -> drac-ollama/olmo-3:7b-think
```

- [ ] **Step 5: Commit**

```bash
git add laptop/reasoner.agent.json
git commit -m "Add reasoner agent template for connect.sh"
```

---

### Task 5: `laptop/connect.sh` writes all models + the reasoner agent

**Files:**
- Modify: `laptop/connect.sh:43-64` (`configure_opencode`), `:84` (read `models=`), `:90-105` (validation), `:115-119` (dry-run), `:125` (READY banner), `:133` (call site)

**Interfaces:**
- Consumes: `MODELS` (Task 1), `laptop/reasoner.agent.json` (Task 4), status file `models=` (Task 3), `DRY_RUN_PORT`, `SSH_MUX_OPTS`/`ssh_run`, `$SCRIPT_DIR`.
- Produces: `~/.config/opencode/opencode.json` with `drac-ollama` provider containing one model entry per `MODELS` and `.agent.reasoner` from the template; everything else preserved; backup at `$cfg.bak.pre-drac`.

- [ ] **Step 1: Write the failing verification (offline connect harness)**

```bash
rm -rf /tmp/drac-mm/home && mkdir -p /tmp/drac-mm/bin /tmp/drac-mm/home
cat > /tmp/drac-mm/bin/ssh <<'EOF'
#!/usr/bin/env bash
echo "SSH $*" >> "$HOME/ssh-log.txt"
for a in "$@"; do [[ "$a" == "-O" ]] && exit 0; done
case "$*" in
    *"status.sh --wait"*) exit 0 ;;
    *"grep '^host='"*) echo "fakehost" ;;
    *"grep '^ip='"*) echo "10.0.0.5" ;;
    *"grep '^models='"*) echo "olmo-3:7b-instruct olmo-3:7b-think" ;;
    *"grep '^port='"*) echo "23456" ;;
    *" -N -L"*) echo "tunnel"; sleep 20 ;;
    *) exit 0 ;;
esac
EOF
cat > /tmp/drac-mm/bin/rsync <<'EOF'
#!/usr/bin/env bash
echo "RSYNC $*" >> "$HOME/ssh-log.txt"
EOF
chmod +x /tmp/drac-mm/bin/ssh /tmp/drac-mm/bin/rsync

# pre-existing config that must survive the merge
mkdir -p /tmp/drac-mm/home/.config/opencode
cat > /tmp/drac-mm/home/.config/opencode/opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["superpowers@git+https://github.com/obra/superpowers.git"],
  "provider": {
    "anthropic": { "npm": "@ai-sdk/anthropic", "name": "Anthropic" }
  },
  "agent": {
    "coder": { "mode": "primary", "model": "anthropic/sonnet" }
  }
}
EOF
```

- [ ] **Step 2: Run to verify it fails**

```bash
PATH="/tmp/drac-mm/bin:$PATH" HOME=/tmp/drac-mm/home FAKE_REMOTE=/tmp/drac-mm/remote \
    bash laptop/up.sh --dry-run 2>&1 | grep -E "Configuring opencode|configure_opencode"
```

Expected (against current code): FAIL — the dry-run echo still shows the
single-model wording (a bare `MODEL` value from `config.sh`), not both model
names.

- [ ] **Step 3: Implement**

Edit `laptop/connect.sh`.

**a)** `configure_opencode` (lines 43-64). Replace the function with:

```sh
configure_opencode() {
    local port="$1" models="$2"
    local cfg="$HOME/.config/opencode/opencode.json"
    local agent_file="$SCRIPT_DIR/reasoner.agent.json"
    mkdir -p "$(dirname "$cfg")"

    local agent_json="{}"
    if [[ -f "$agent_file" ]]; then
        agent_json="$(cat "$agent_file")"
    else
        echo "WARNING: $agent_file not found; skipping reasoner agent." >&2
    fi

    local new
    new="$(jq -n --arg base "http://127.0.0.1:${port}/v1" --arg models "$models" --argjson agent "$agent_json" \
        '{provider: {("drac-ollama"): {npm: "@ai-sdk/openai-compatible", name: "DRAC Ollama", options: {baseURL: $base}, models: ($models | split(" ") | map({key: ., value: {name: ("DRAC " + .)}}) | from_entries)}}, agent: $agent}')"

    if [[ -f "$cfg" ]]; then
        if ! jq -e . "$cfg" >/dev/null 2>&1; then
            echo "ERROR: $cfg exists but is not valid JSON. Refusing to touch it." >&2
            exit 1
        fi
        cp "$cfg" "$cfg.bak.pre-drac"
        new="$(jq --argjson p "$new" \
            '.provider = ((.provider // {}) | del(.["drac-ollama"]) | . + $p.provider)
             | .agent = ((.agent // {}) | del(.reasoner) | . + $p.agent)' "$cfg")"
    fi

    printf '%s\n' "$new" > "$cfg"
    echo "Updated $cfg (backup at $cfg.bak.pre-drac)"
}
```

**b)** Status read (line 83-85). Replace the `MODEL="$(... '^model=' ...)"` line with a `MODELS` read:

```sh
    MODELS="$(ssh_run "$LOGIN_NODE" "grep '^models=' '$STATUS_REMOTE' | cut -d= -f2")"
```

**c)** Validation — after the existing `PORT` check (lines 101-105), add:

```sh
if [[ -z "$MODELS" ]]; then
    echo "ERROR: could not determine session models (status file missing models=)." >&2
    echo "Re-provision: ssh $LOGIN_NODE 'cd $REMOTE && bash cluster/teardown.sh && bash cluster/provision.sh'" >&2
    exit 1
fi
```

**d)** Dry-run echo (line 115): `echo "==> Configuring opencode for $MODEL via http://127.0.0.1:$PORT/v1"` becomes:

```sh
echo "==> Configuring opencode for $MODELS via http://127.0.0.1:$PORT/v1"
```

**e)** Dry-run block (line 116): `echo "[dry-run] configure_opencode $PORT $MODEL"` becomes:

```sh
    echo "[dry-run] configure_opencode $PORT $MODELS"
```

**f)** READY banner (line 125): `echo "Model: $MODEL  |  Endpoint: http://127.0.0.1:$PORT/v1"` becomes:

```sh
echo "Models: $MODELS  |  Endpoint: http://127.0.0.1:$PORT/v1"
```

**g)** Call site (line 133): `configure_opencode "$PORT" "$MODEL"` becomes:

```sh
configure_opencode "$PORT" "$MODELS"
```

- [ ] **Step 4: Run to verify it passes**

```bash
bash -n laptop/connect.sh laptop/up.sh
echo "--- dry-run lists both models, no ssh calls ---"
PATH="/tmp/drac-mm/bin:$PATH" HOME=/tmp/drac-mm/home FAKE_REMOTE=/tmp/drac-mm/remote \
    bash laptop/up.sh --dry-run 2>&1 | grep -E "Configuring opencode|configure_opencode"
echo "--- real-mode: config written with 2 models + agent, preserving others ---"
PATH="/tmp/drac-mm/bin:$PATH" HOME=/tmp/drac-mm/home FAKE_REMOTE=/tmp/drac-mm/remote bash laptop/up.sh >/dev/null 2>&1 &
sleep 2; pkill -f "sleep 20" 2>/dev/null; pkill -f "bash laptop/up.sh" 2>/dev/null
sleep 1
C=/tmp/drac-mm/home/.config/opencode/opencode.json
[ "$(jq -r '.provider["drac-ollama"].models | keys | sort | join(",")' "$C")" = "olmo-3:7b-instruct,olmo-3:7b-think" ] || echo "FAIL: model entries"
[ "$(jq -r '.agent.reasoner.model' "$C")" = "drac-ollama/olmo-3:7b-think" ] || echo "FAIL: reasoner agent"
[ "$(jq -r '.provider.anthropic.npm' "$C")" = "@ai-sdk/anthropic" ] || echo "FAIL: other provider lost"
[ "$(jq -r '.agent.coder.mode' "$C")" = "primary" ] || echo "FAIL: other agent lost"
[ "$(jq -r '."$schema"' "$C")" = "https://opencode.ai/config.json" ] || echo "FAIL: schema lost"
[ "$(jq -r '.plugin[0]' "$C")" = "superpowers@git+https://github.com/obra/superpowers.git" ] || echo "FAIL: plugin lost"
echo "--- fresh config (no pre-existing file) also gets the agent ---"
rm -rf /tmp/drac-mm/fresh && mkdir -p /tmp/drac-mm/fresh
PATH="/tmp/drac-mm/bin:$PATH" HOME=/tmp/drac-mm/fresh FAKE_REMOTE=/tmp/drac-mm/remote bash laptop/up.sh >/dev/null 2>&1 &
sleep 2; pkill -f "sleep 20" 2>/dev/null; pkill -f "bash laptop/up.sh" 2>/dev/null
sleep 1
jq -r '.agent.reasoner.model' /tmp/drac-mm/fresh/.config/opencode/opencode.json
echo "--- mux opts on every call + down.sh ---"
PATH="/tmp/drac-mm/bin:$PATH" HOME=/tmp/drac-mm/fresh FAKE_REMOTE=/tmp/drac-mm/remote bash laptop/down.sh >/dev/null 2>&1; echo "down rc=$?"
BAD=0
while IFS= read -r line; do
    case "$line" in
        SSH\ -O*) continue ;;
        *"ControlMaster=auto"*) [[ "$line" == *"ControlPath="* && "$line" == *"ControlPersist=600"* ]] || { echo "MISSING: $line"; BAD=1; };;
        *) echo "NO MUX: $line"; BAD=1;;
    esac
done < /tmp/drac-mm/home/ssh-log.txt
echo "mux BAD=$BAD"
```

Expected: dry-run echoes both model names; real-mode `jq` assertions print nothing (all pass); fresh-config `reasoner.model` prints `drac-ollama/olmo-3:7b-think`; `down rc=0`; `mux BAD=0`.

- [ ] **Step 5: Commit**

```bash
git add laptop/connect.sh
git commit -m "Write provider with all MODELS and the reasoner agent"
```

---

### Task 6: Documentation

**Files:**
- Modify: `docs/usage.md` (Configuration, connect.sh behavior, model selection, status field, checklist), `README.md:27`

**Interfaces:**
- Consumes: nothing new; reflects Tasks 1-5.

- [ ] **Step 1: Write the failing verification**

```bash
rg -n 'MODEL' README.md
rg -n 'MODEL=qwen3:14b|MODEL\)' docs/usage.md
rg -n 'model=`' docs/usage.md || true
```

- [ ] **Step 2: Run to verify it fails**

Expected: `README.md:27` still says `(LOGIN_NODE, MODEL)`; `docs/usage.md` still describes a single model / `MODEL` in the Configuration and "what connect.sh writes" sections.

- [ ] **Step 3: Implement**

**README.md** — line 27: `# Configure once: edit config.sh (LOGIN_NODE, MODEL)` → `# Configure once: edit config.sh (LOGIN_NODE, MODELS)`.

**docs/usage.md** — Configuration section (lines 9-13). Replace:

```markdown
- Laptop side: `LOGIN_NODE`, `REMOTE_DIR`, `MODEL` (default `qwen3:14b`),
  `SSH_SOCK`, `SSH_PERSIST`, `DRY_RUN_PORT` (default `11435`, only used by
  `connect.sh --dry-run` for display).
- Cluster side: `GPU_CONFIG`, `CPUS`, `MEM`, `TIME`, `MODEL`, `SESSION`.
- Timeouts (seconds): `READY_TIMEOUT` (1200), `OLLAMA_START_TIMEOUT` (300),
  `PULL_SERVE_TIMEOUT` (120).
```

with:

```markdown
- Laptop side: `LOGIN_NODE`, `REMOTE_DIR`, `MODELS` (default
  `olmo-3:7b-instruct olmo-3:7b-think`), `SSH_SOCK`, `SSH_PERSIST`,
  `DRY_RUN_PORT` (default `11435`, only used by `connect.sh --dry-run` for
  display).
- Cluster side: `GPU_CONFIG`, `CPUS`, `MEM`, `TIME`, `MODELS`, `SESSION`.
- Timeouts (seconds): `READY_TIMEOUT` (1200), `OLLAMA_START_TIMEOUT` (300),
  `PULL_SERVE_TIMEOUT` (120).
```

Add after the "never set the port by hand" paragraph (after line 21):

```markdown
### Multiple models, one session

`MODELS` is a space-separated list; every model in it is pulled on setup and
served by the single Ollama server, all on the same random port. Ollama loads
whichever model a request names, swapping models in and out of GPU memory as
needed. Add or remove a model by editing `MODELS` (or overriding it on the
command line, e.g. `MODELS="olmo-3:7b-instruct" ./laptop/up.sh`) and
re-running `up.sh`. `MODEL` is deprecated; if set (and `MODELS` is not), it is
used as a one-element list.
```

**docs/usage.md** — "What `connect.sh` does automatically" (lines 54-62). Replace the bullets:

```markdown
Every run of `laptop/connect.sh` merges a `drac-ollama` provider into
`~/.config/opencode/opencode.json`:

- The provider points at `http://127.0.0.1:$PORT/v1` (the tunneled endpoint).
- The provider lists one model entry per value in `MODELS` (the models the
  session serves, e.g. `olmo-3:7b-instruct` and `olmo-3:7b-think`), each named
  `"DRAC <model>"`.
- A `reasoner` agent (from `laptop/reasoner.agent.json`) is merged under
  `agent`, using `drac-ollama/olmo-3:7b-think` with tool access denied.
- Your existing config is backed up to `opencode.json.bak.pre-drac` before the
  merge. If the existing file is not valid JSON, `connect.sh` refuses to touch
  it and exits.
```

Replace the "Exactly what it writes" JSON example (lines 64-84):

```markdown
Exactly what it writes (`MODELS=olmo-3:7b-instruct olmo-3:7b-think`; the port
is whatever the session rolled, not a fixed default):
```

```json
{
  "provider": {
    "drac-ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DRAC Ollama",
      "options": {
        "baseURL": "http://127.0.0.1:11435/v1"
      },
      "models": {
        "olmo-3:7b-instruct": {
          "name": "DRAC olmo-3:7b-instruct"
        },
        "olmo-3:7b-think": {
          "name": "DRAC olmo-3:7b-think"
        }
      }
    }
  },
  "agent": {
    "reasoner": {
      "description": "Deep reasoning with Olmo 3 Think — no tool access, chat/analysis only",
      "mode": "primary",
      "model": "drac-ollama/olmo-3:7b-think",
      "permission": {
        "edit": "deny",
        "bash": "deny",
        "webfetch": "deny",
        "task": "deny"
      }
    }
  }
}
```

**docs/usage.md** — "Selecting the model" (lines 147-152). Replace with:

```markdown
- In the TUI, switch models and pick `drac-ollama/olmo-3:7b-instruct` or
  `drac-ollama/olmo-3:7b-think` (listed under the provider name "DRAC
  Ollama").
- The `reasoner` agent (chat/analysis only, no tools) is available as an agent
  in opencode once `connect.sh` has run.
- To make a model the default, set `"model": "drac-ollama/<model>"` in
  `~/.config/opencode/opencode.json` (or a project `opencode.json`).
```

**docs/usage.md** — "Keeping it working" status bullet (lines 162-164). Replace:

```markdown
- The session port is chosen at random each time the session starts and is
  recorded in the cluster status file (`port=`). `connect.sh` reads it and
  writes it into `options.baseURL`, so you never set it by hand.
```

with:

```markdown
- The session port is chosen at random each time the session starts and is
  recorded in the cluster status file (`port=`), alongside the served model
  list (`models=`). `connect.sh` reads them and writes `options.baseURL` and
  the model entries, so you never set them by hand.
```

**docs/usage.md** — Manual test checklist (lines 221-232). Insert after the
`/v1/models` item:

```markdown
- [ ] `opencode.json` lists both `olmo-3:7b-instruct` and `olmo-3:7b-think`
      under `drac-ollama`, and the `reasoner` agent is present.
```

- [ ] **Step 4: Run to verify it passes**

```bash
rg -n 'MODEL' README.md docs/usage.md || echo "no bare MODEL refs"
rg -n 'MODELS' README.md docs/usage.md
```

Expected: README references `MODELS`; `docs/usage.md` documents `MODELS`, the multi-model paragraph, the updated connect.sh behavior/example, `models=` in the status bullet, and the new checklist item. No stale `MODEL`-only references in the docs that describe current behavior (historical `docs/superpowers/*` untouched).

- [ ] **Step 5: Commit**

```bash
git add README.md docs/usage.md
git commit -m "Document the multi-model setup"
```

---

### Task 7: Final offline sweep

**Files:**
- Verify only.

- [ ] **Step 1: Syntax + repo-wide reference check**

```bash
bash -n config.sh laptop/*.sh cluster/*.sh && echo "syntax OK"
rg -n 'model=' --glob '!docs/superpowers/**' . || echo "no model= consumers left"
rg -n '\bMODEL\b' config.sh laptop cluster --glob '*.sh' || echo "no bare MODEL refs in scripts"
```

Expected: `syntax OK`; no `model=` consumers outside historical docs; no bare `MODEL` references in scripts (the deprecated bridge in `config.sh` intentionally names `MODEL`, so that file is expected to match).

- [ ] **Step 2: Re-run Task 5 harness end-to-end once more** (fresh temp dirs) and confirm no `FAIL:` lines and `mux BAD=0`.

- [ ] **Step 3: Final status**

```bash
git status --short && git log --oneline -8
```

Expected: clean tree (no uncommitted changes — the old `config.sh` experiment is superseded by Task 1's commit), `multi-model` branch, Tasks 1-6 commits present.
