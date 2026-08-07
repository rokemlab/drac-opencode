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
