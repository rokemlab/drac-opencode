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
   serve` inside the container (model stored on `$SCRATCH`). The laptop then
   adds a `drac-ollama` provider to opencode and opens a single ssh tunnel to
   the login node (`ssh -N -L $PORT:<node-ip>:$PORT <login>`), which forwards
   to the Ollama port on the compute node over the cluster network — one
   key+Duo login prompt, then run `opencode` in a second terminal. The port is
   chosen at random for each session, so the endpoint moves every time.
3. **When done:** `laptop/disconnect.sh` kills the tunnel; 
   `ssh <login> 'cd <remote> && bash cluster/teardown.sh'` frees the GPU.
   For both at once, use `laptop/down.sh`.

## Quick start

```bash
# Configure once: edit config.sh (LOGIN_NODE, MODELS)

# Every session, in one shot: sync repo + provision + tunnel (one terminal)
./laptop/up.sh
opencode                       # select the drac-ollama model (second terminal)

# When done:
./laptop/down.sh               # kill tunnel + free the GPU
```

The granular steps are still available: `laptop/setup.sh` (sync repo, build the
image), `laptop/connect.sh` (provision + open the tunnel, run in one terminal),
`laptop/disconnect.sh` (kill just the tunnel), and
`ssh <login> 'cd <remote> && bash cluster/teardown.sh'` (free just the GPU).

## Requirements

- An Alliance Canada account with an allocation (RAC/RAS) that includes GPU nodes.
- `ssh`, `rsync`, `jq` on your laptop.
- `apptainer` on the cluster login node (try `module load apptainer` if needed).

See `docs/usage.md` for details, per-cluster notes, troubleshooting, and the
manual test checklist.
