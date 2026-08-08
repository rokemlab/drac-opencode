# drac-opencode usage

## Configuration

- `laptop/config.sh` — `LOGIN_NODE`, `PORT`, `MODEL` (default `qwen3:14b`).
- `cluster/config.sh` — `GPU_COUNT`, `CPUS`, `MEM`, `TIME`, `MODEL`, `SESSION`.
  Every value can be set as an environment variable. When running cluster
  scripts directly on the login node, e.g.
  `MODEL=qwen3:32b TIME=48:00:00 bash cluster/provision.sh`. On the laptop,
  `connect.sh` uses only `LOGIN_NODE` and `PORT` from `laptop/config.sh`; the
  model comes from the cluster status file, so set `MODEL` in
  `cluster/config.sh`.

Keep `PORT` in sync between `laptop/config.sh` and `cluster/config.sh`.

## Configuring opencode

opencode runs on your laptop and talks to the Ollama endpoint on the GPU node
through the SSH tunnel. It learns about that endpoint through a `drac-ollama`
provider in your opencode config, `~/.config/opencode/opencode.json`.

### What `connect.sh` does automatically

Every run of `laptop/connect.sh` merges a minimal `drac-ollama` provider into
`~/.config/opencode/opencode.json`:

- The provider points at `http://127.0.0.1:$PORT/v1` (the tunneled endpoint).
- The model key is whatever `MODEL` the cluster session is serving (from
  `cluster/config.sh`, e.g. `qwen3:14b`), named `"DRAC <model>"`.
- Your existing config is backed up to `opencode.json.bak.pre-drac` before the
  merge. If the existing file is not valid JSON, `connect.sh` refuses to touch
  it and exits.

Exactly what it writes (for the default `PORT=11434`, `MODEL=qwen3:14b`):

```json
{
  "provider": {
    "drac-ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DRAC Ollama",
      "options": {
        "baseURL": "http://127.0.0.1:11434/v1"
      },
      "models": {
        "qwen3:14b": {
          "name": "DRAC qwen3:14b"
        }
      }
    }
  }
}
```

Note: `connect.sh` replaces the whole `drac-ollama` block on every run, so any
fields you add to it by hand (like the ones below) are wiped the next time you
connect. Customize it after connecting, or keep your customizations in a
project-level `opencode.json` if they must survive.

### Manual configuration

You can also write the provider by hand. The model id is
`drac-ollama/<model>` — e.g. `drac-ollama/qwen3:14b` — which is what you
select in opencode's model picker or set as the default `model`.

A full recommended block, using the same option names as a typical local
provider config:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "drac-ollama/qwen3:14b",
  "provider": {
    "drac-ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DRAC Ollama",
      "options": {
        "baseURL": "http://127.0.0.1:11434/v1",
        "apiKey": "ollama"
      },
      "models": {
        "qwen3:14b": {
          "name": "Qwen3 14B (DRAC GPU)",
          "tool_call": true,
          "reasoning": true,
          "interleaved": {
            "field": "reasoning_content"
          },
          "maxTokens": 8192,
          "limit": {
            "context": 32768,
            "output": 8192
          }
        }
      }
    }
  }
}
```

Field reference:

| Field | Meaning |
| --- | --- |
| `npm` | SDK package that implements the provider (`@ai-sdk/openai-compatible`). |
| `options.baseURL` | Must match the tunnel: `http://127.0.0.1:$PORT/v1`. |
| `options.apiKey` | Dummy key; Ollama ignores it, but some SDKs require one. |
| `models.<model>` | Per-model entry keyed by the Ollama model name (e.g. `qwen3:14b`). |
| `tool_call` | Enable tool calling so opencode can use its tools with this model. |
| `maxTokens` | Maximum output tokens per response. |
| `reasoning` | Mark the model as a reasoning model. |
| `interleaved` | Stream reasoning text (`{"field": "reasoning_content"}`) for models that emit a `reasoning_content` field, e.g. Qwen3 thinking mode. |
| `limit.context` | Context window. 32768 matches the container's `OLLAMA_CONTEXT_LENGTH`. |
| `limit.output` | Output token limit. |

### Selecting the model

- In the TUI, switch models and pick `drac-ollama/qwen3:14b` (listed under the
  provider name "DRAC Ollama").
- To make it the default, set `"model": "drac-ollama/qwen3:14b"` in
  `~/.config/opencode/opencode.json` (or a project `opencode.json`).

### Keeping it working

- opencode reads its config once at startup — quit and restart opencode after
  running `connect.sh` or after editing the config.
- `connect.sh` must have completed and the tunnel must be up for the endpoint
  to respond. `laptop/disconnect.sh` kills the tunnel; the provider stays in
  the config and just fails until you reconnect.
- The port in `options.baseURL` must match `PORT` in `laptop/config.sh` (and
  `cluster/config.sh`).

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
  See [Configuring opencode](#configuring-opencode).

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
