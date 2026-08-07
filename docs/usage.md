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
