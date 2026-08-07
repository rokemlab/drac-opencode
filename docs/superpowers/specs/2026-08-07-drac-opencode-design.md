# drac-opencode: GPU-backed opencode on Alliance Canada Slurm clusters

## Design

**Date:** 2026-08-07
**Status:** Approved

## Goal

Container specifications and scripts to provision an Alliance Canada (Digital
Research Alliance of Canada, "DRAC") GPU node for long-running sessions, serve
a local model on that node with Ollama, expose it to the user's laptop over an
encrypted SSH tunnel, and point `opencode` at it. `opencode` runs on the user's
laptop as a TUI, reading local code, and calls the OpenAI-compatible endpoint
served on the GPU node.

## Target resource

Slurm HPC clusters (Graham, Cedar, Beluga, Narval, ...). Generic across
clusters: GPU type, partition, and time limits are configurable. Compute nodes
are not publicly reachable; only login nodes accept SSH. Therefore the model
port is always reached via an SSH tunnel through the login node.

## Approved approach (A)

tmux session on the login node + `srun --pty` to the compute node + status file
in `$SCRATCH` + laptop-side connect script that opens a ProxyJump SSH tunnel and
merges an OpenAI-compatible provider into the laptop's opencode config.

## High-level flow

1. **Once per cluster/project:** build the Apptainer image -> `ollama.sif`
   (stored in `$SCRATCH/opencode/`).
2. **Per session:** `connect.sh` (laptop) SSHs to the login node and runs
   `provision.sh`, which starts a persistent tmux session. Inside tmux,
   `srun --gpus=1 ... --pty` runs `run-ollama.sh` on the compute node, which
   starts `ollama serve` (localhost-only) in the container and pulls the
   requested model.
3. `run-ollama.sh` writes the compute-node hostname + port + ready flag to a
   status file in `$SCRATCH/opencode/`.
4. `connect.sh` polls that file over SSH, then opens a tunnel
   `ssh -J <login> -N -L $PORT:127.0.0.1:$PORT <compute-host>` that lands on
   the compute node's loopback. Finally it merges an OpenAI-compatible provider
   into the laptop's opencode config pointing at `http://127.0.0.1:$PORT/v1`.
5. `disconnect.sh` (laptop) kills the tunnel; `teardown.sh` (cluster) kills the
   tmux session and releases the GPU allocation.

## Security

- Ollama binds to `127.0.0.1` only. Apptainer uses the shared host network, so
  this is the compute node's loopback. No open ports on any network.
- All access is encrypted SSH. The `-J` ProxyJump means the compute hostname
  only needs to resolve on the login node, and the tunnel is a real SSH session
  into the compute node (reaching the node's loopback via that session).
- The opencode config merge refuses to overwrite an unparseable existing
  config; it backs up the existing file first.

## Container

- Apptainer def file, Bootstrap from the official `ollama/ollama` Docker image
  (bundled CUDA runtime; no separate CUDA install; works across V100/A100-class
  nodes with `--nv`).
- `%environment`: `OLLAMA_HOST=127.0.0.1:11434` (sane default), `OLLAMA_MODELS=/models`.
- `%runscript`: `exec ollama serve`.
- Port is not known at build time, so `run-ollama.sh` overrides it at runtime
  with `apptainer run --env OLLAMA_HOST=127.0.0.1:$PORT ...` (or by exporting
  it on the host before launching, relying on Apptainer's environment
  passthrough).
- Model storage binds to `$SCRATCH/opencode/models:/models` so models survive
  image rebuilds and don't hit home-quota limits.
- Built with `container/build.sh` (run on the login node, which has network
  access; Apptainer cannot run on macOS).

## Directory layout

```
drac-opencode/
├── README.md
├── container/
│   ├── ollama.def            # Apptainer def: Bootstrap docker, From: ollama/ollama
│   └── build.sh              # apptainer build ollama.sif ollama.def
├── cluster/                  # run on the cluster (login + compute)
│   ├── config.sh             # PORT, GPU_COUNT, CPUS, MEM, TIME, MODEL, SIF, status dir
│   ├── provision.sh          # idempotent tmux + srun -> run-ollama.sh
│   ├── run-ollama.sh         # on compute node: status file, serve, model pull, READY banner
│   ├── status.sh             # read/poll the status file
│   └── teardown.sh           # kill tmux, release allocation
├── laptop/                   # run on the user's laptop
│   ├── config.sh             # LOGIN_NODE, USERNAME, PORT, remote repo path
│   ├── setup.sh              # rsync repo to cluster, build SIF if missing
│   ├── connect.sh            # remote provision, poll, tunnel (-J), merge opencode config
│   └── disconnect.sh         # kill tunnel
└── docs/
    └── usage.md              # setup, per-cluster limits, troubleshooting, manual test checklist
```

## Script details

### cluster/config.sh

Single source of truth, sourced by all cluster scripts. Defaults:
`PORT=11434`, `GPU_COUNT=1`, `CPUS=4`, `MEM=24G`, `TIME=24:00:00` (documented
per-cluster max limits in the README), `MODEL=qwen3:14b`, `SESSION=opencode`,
`SIF=$SCRATCH/opencode/ollama.sif`, status file
`$SCRATCH/opencode/status.txt`. All overridable via environment variables.

### cluster/provision.sh

Idempotent: if the tmux session exists it errors with "already running, see
teardown.sh" rather than silently killing. Otherwise creates
`tmux new-session -d -s opencode` and sends
`srun --gpus=$GPU_COUNT --cpus-per-task=$CPUS --mem=$MEM --time=$TIME --pty bash run-ollama.sh`.
Verifies the SIF exists first and prints build instructions if not. Prints
"session started - tail the log with tmux attach -t opencode".

### cluster/run-ollama.sh (compute node)

Writes `hostname`, `port`, `model`, `ready=no` to the status file; starts
`apptainer run --nv --env OLLAMA_HOST=127.0.0.1:$PORT --bind $SCRATCH/opencode/models:/models $SIF`
in the background; polls `curl http://127.0.0.1:$PORT/api/tags` until up; then
`apptainer exec ... ollama pull $MODEL` (progress visible in tmux); flips
`ready=yes`; prints the "READY" banner with the exact laptop command; `wait`s
on the serve process so the allocation stays alive.

### cluster/status.sh

Prints the status file contents; supports a `--wait`/timeout mode used by
`connect.sh`.

### cluster/teardown.sh

Kills the tmux session (which cancels the allocation) and clears the status
file.

### laptop/config.sh

`LOGIN_NODE` (e.g. `narval.calculquebec.ca`), `USERNAME`, `PORT`, remote repo
path. Sourced by laptop scripts.

### laptop/setup.sh

One-time: `rsync -a` the repo to `$SCRATCH/opencode/remote/`; if the SIF is
missing, build it on the login node via `build.sh`.

### laptop/connect.sh

SSHs to the login node to run `provision.sh`; polls the status file via SSH
(timeout ~10 min, matching queue wait); on `ready=yes` opens the tunnel in the
background as a PID-tracked process
(`ssh -J $LOGIN_NODE -N -f -L $PORT:127.0.0.1:$PORT <host>`); waits for `curl`
on the local port; merges the opencode provider, backing up
`~/.config/opencode/opencode.json` first.

### laptop/disconnect.sh

Kills the tracked tunnel PID (leaving the remote session running so the user
can reconnect); prints the reconnect command and the teardown command.

## Error handling

- Missing SIF -> message pointing at `build.sh`.
- `srun` failure -> print `squeue -j` / queue reason.
- Stale status file -> clear and rerun.
- Port already bound on the laptop -> suggest changing `PORT`.
- Model pull failure -> server still serves; retry documented.
- opencode config merge -> refuse to overwrite if unparseable.

## Testing

- `bash -n` syntax pass on all scripts.
- `shellcheck` on all scripts.
- `--help` / `--dry-run` flags on `provision.sh` and `connect.sh` that trace
  the commands without executing.
- Manual test checklist in `docs/usage.md` (real build on login node, real
  allocation, tunnel, `curl` the endpoint, launch opencode). No automated
  integration tests possible without an Alliance allocation.
