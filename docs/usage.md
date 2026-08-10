# drac-opencode usage

## Configuration

One shared `config.sh` at the repo root, sourced by both the laptop and the
cluster scripts. `laptop/setup.sh` rsyncs it to the cluster, so both sides
always use the same values.

- Laptop side: `LOGIN_NODE`, `REMOTE_DIR`, `MODEL` (default `qwen3:14b`).
- Cluster side: `GPU_CONFIG`, `CPUS`, `MEM`, `TIME`, `MODEL`, `SESSION`.

Every value can be set as an environment variable. When running cluster
scripts directly on the login node, e.g.
`MODEL=qwen3:32b TIME=48:00:00 bash cluster/provision.sh`.

`PORT` is chosen at random for each session and recorded in the cluster status
file, so you never set it by hand.

## Configuring opencode

opencode runs on your laptop and talks to the Ollama endpoint on the GPU node
through the SSH tunnel. It learns about that endpoint through a `drac-ollama`
provider in your opencode config, `~/.config/opencode/opencode.json`.

### What `connect.sh` does automatically

Every run of `laptop/connect.sh` merges a minimal `drac-ollama` provider into
`~/.config/opencode/opencode.json`:

- The provider points at `http://127.0.0.1:$PORT/v1` (the tunneled endpoint).
- The model key is whatever `MODEL` the cluster session is serving (from
  `config.sh`, e.g. `qwen3:14b`), named `"DRAC <model>"`.
- Your existing config is backed up to `opencode.json.bak.pre-drac` before the
  merge. If the existing file is not valid JSON, `connect.sh` refuses to touch
  it and exits.

Exactly what it writes (`MODEL=qwen3:14b`; the port is whatever the session
rolled, not a fixed default):

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
        "baseURL": "http://127.0.0.1:11435/v1",
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
- `connect.sh` writes the config and then opens the tunnel in the foreground,
  so run it in one terminal and `opencode` in a second. The tunnel must be up
  for the endpoint to respond. `laptop/disconnect.sh` kills the tunnel; the
  provider stays in the config and just fails until you reconnect.
- The session port is chosen at random each time the session starts and is
  recorded in the cluster status file (`port=`). `connect.sh` reads it and
  writes it into `options.baseURL`, so you never set it by hand.

> *The Count counts the handshake: one key, one Duo prompt, one tunnel — ah ah ah!
> Bar it with `laptop/disconnect.sh` when the counting is done.*

### Security note

While a session is running, the Ollama API on the compute node listens on the
cluster-internal network (not just localhost), so the login node can forward to
it. Other cluster users can reach that API for the lifetime of the session and
could run inference on the GPU, pull/delete models, or send abusive prompts.
Teardown closes the port. The serving port is randomized per session, so other
users can't easily find the endpoint. Only run sessions you're actively using.

> *The Count counts his sessions: one at a time, ah ah ah! Keep a session alive
> only as long as you're actually using it.*

## Per-cluster notes

- Max `TIME` limits vary by cluster/partition (check with
  `sacctmgr show qos format=name,maxtresperuser` or `squeue --account`).
  Default `TIME=24:00:00` is safe on all general partitions.
- Narval and Beluga (A100 40GB) run `qwen3:14b` comfortably; Graham/Cedar
  (V100/P100) also fit it.
- If `apptainer` is not on PATH on the login node, try `module load apptainer`.

## Troubleshooting

- `apptainer: command not found` — load the module, see above.
- Expect one Alliance key + Duo prompt from `connect.sh` (the login node). The
  tunnel is a single ssh to the login node (`ssh -N -L $PORT:<node-ip>:$PORT`),
  which forwards to Ollama on the compute node over the cluster network — no
  second prompt and no compute-node host-key confirmation.
- `session did not become ready` — `ssh <login> 'tail -n 40 $SCRATCH/opencode/ollama.log'`
- `127.0.0.1:$PORT is already in use` — the rolled session port is taken
  locally; re-run `connect.sh` to get a fresh one.
- Model pull times out / model missing — compute nodes have no internet; models
  are pulled on the login node by `cluster/pull-model.sh` (run automatically by
  `setup.sh` and `provision.sh`). Retry manually:
  `ssh <login> 'cd <remote> && bash cluster/pull-model.sh'`.
- opencode shows no `drac-ollama` models — check the endpoint:
  `curl http://127.0.0.1:$PORT/v1/models`, then re-run `./laptop/connect.sh`.
  See [Configuring opencode](#configuring-opencode).

## Manual test checklist

Run these once on a real cluster after setup to validate the whole stack:

- [ ] `laptop/setup.sh` completes and `ollama.sif` exists on the cluster.
- [ ] `ssh <login> 'bash <remote>/cluster/provision.sh --dry-run'` prints the srun command.
- [ ] `./laptop/connect.sh` prints the `READY` banner and opens the tunnel
      (complete the key + Duo prompt in that terminal).
- [ ] In a second terminal, `curl http://127.0.0.1:$PORT/api/tags` lists the
      model on the laptop.
- [ ] `curl http://127.0.0.1:$PORT/v1/models` returns an OpenAI-style model list.
- [ ] `opencode` starts and the `drac-ollama` provider/model is selectable.
- [ ] `./laptop/disconnect.sh` kills the tunnel; endpoint no longer responds.
- [ ] `ssh <login> 'cd <remote> && bash cluster/teardown.sh'` frees the GPU
      (`squeue -u $USER` is empty for the session).
