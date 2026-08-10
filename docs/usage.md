# drac-opencode usage

## Configuration

One shared `config.sh` at the repo root, sourced by both the laptop and the
cluster scripts. `laptop/setup.sh` rsyncs it to the cluster, so both sides
always use the same values.

- Laptop side: `LOGIN_NODE`, `REMOTE_DIR`, `MODELS` (default
  `olmo-3:7b-instruct olmo-3:7b-think`), `SSH_SOCK`, `SSH_PERSIST`,
  `DRY_RUN_PORT` (default `11435`, only used by `connect.sh --dry-run` for
  display).
- Cluster side: `GPU_CONFIG`, `CPUS`, `MEM`, `TIME`, `MODELS`, `SESSION`.
- Timeouts (seconds): `READY_TIMEOUT` (1200), `OLLAMA_START_TIMEOUT` (300),
  `PULL_SERVE_TIMEOUT` (120).

Every value can be set as an environment variable. When running cluster
scripts directly on the login node, e.g.
`MODELS="olmo-3:7b-instruct olmo-3:7b-think" TIME=48:00:00 bash cluster/provision.sh`.

`PORT` is chosen at random for each session and recorded in the cluster status
file, so you never set it by hand. (For testing you can pin it from the login
node: `PORT=7777 bash cluster/provision.sh`.)

### Multiple models, one session

`MODELS` is a space-separated list; every model in it is pulled on setup and
served by the single Ollama server, all on the same random port. Ollama loads
whichever model a request names, swapping models in and out of GPU memory as
needed. Add or remove a model by editing `MODELS` (or overriding it on the
command line, e.g. `MODELS="olmo-3:7b-instruct" ./laptop/up.sh`) and
re-running `up.sh`. `MODEL` is deprecated; if set (and `MODELS` is not), it is
used as a one-element list.

## One-shot commands

`laptop/up.sh` runs setup then connect in one go (sync repo, ensure the image
and model, provision a session, open the tunnel):

```bash
./laptop/up.sh
```

It holds the tunnel open in the foreground, just like `connect.sh` — run it in
one terminal and opencode in a second. `--dry-run` is passed through to
`connect.sh`.

`laptop/down.sh` runs disconnect then remote teardown in one go (kill the
local tunnel, free the GPU allocation):

```bash
./laptop/down.sh
```

Both are safe to re-run; each step already handles the "nothing to do" case.

## Configuring opencode

opencode runs on your laptop and talks to the Ollama endpoint on the GPU node
through the SSH tunnel. It learns about that endpoint through a `drac-ollama`
provider in your opencode config, `~/.config/opencode/opencode.json`.

### What `connect.sh` does automatically

Every run of `laptop/connect.sh` merges a minimal `drac-ollama` provider into
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

Exactly what it writes (`MODELS=olmo-3:7b-instruct olmo-3:7b-think`; the port
is whatever the session rolled, not a fixed default):

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

- In the TUI, switch models and pick `drac-ollama/olmo-3:7b-instruct` or
  `drac-ollama/olmo-3:7b-think` (listed under the provider name "DRAC
  Ollama").
- The `reasoner` agent (chat/analysis only, no tools) is available as an agent
  in opencode once `connect.sh` has run.
- To make a model the default, set `"model": "drac-ollama/<model>"` in
  `~/.config/opencode/opencode.json` (or a project `opencode.json`).

### Keeping it working

- opencode reads its config once at startup — quit and restart opencode after
  running `connect.sh` or after editing the config.
- `connect.sh` writes the config and then opens the tunnel in the foreground,
  so run it in one terminal and `opencode` in a second. The tunnel must be up
  for the endpoint to respond. `laptop/disconnect.sh` kills the tunnel; the
  provider stays in the config and just fails until you reconnect.
- The session port is chosen at random each time the session starts and is
  recorded in the cluster status file (`port=`), alongside the served model
  list (`models=`). `connect.sh` reads them and writes `options.baseURL` and
  the model entries, so you never set them by hand.

### One key+Duo per session

All the laptop scripts share a single SSH connection using OpenSSH connection
multiplexing. The first `ssh`/`rsync` to the login node authenticates and
becomes the master; every subsequent call within `SSH_PERSIST` seconds reuses
it. So a full `up.sh` run prompts once (the tunnel reuses the same connection,
no second prompt), and `down.sh` reuses it too — or opens one fresh connection
if the master has expired.

- `SSH_SOCK` — master socket path (default `~/.cache/drac-opencode/mux-%C.sock`).
- `SSH_PERSIST` — seconds the master stays alive after its last use (default 600).

After `down.sh` the master is closed explicitly; if you never run it, the
master expires on its own after `SSH_PERSIST` seconds.

### Security note

While a session is running, the Ollama API on the compute node listens on the
cluster-internal network (not just localhost), so the login node can forward to
it. Other cluster users can reach that API for the lifetime of the session and
could run inference on the GPU, pull/delete models, or send abusive prompts.
Teardown closes the port. The serving port is randomized per session, so other
users can't easily find the endpoint. Only run sessions you're actively using.

## Per-cluster notes

- Max `TIME` limits vary by cluster/partition (check with
  `sacctmgr show qos format=name,maxtresperuser` or `squeue --account`).
  Default `TIME=24:00:00` is safe on all general partitions.
- Narval and Beluga (A100 40GB) run `qwen3:14b` comfortably; Graham/Cedar
  (V100/P100) also fit it.
- If `apptainer` is not on PATH on the login node, try `module load apptainer`.

## Troubleshooting

- `apptainer: command not found` — load the module, see above.
- Expect one Alliance key + Duo prompt per session, from the first `ssh` call
  (or `up.sh`). Every later call, including the tunnel, reuses the shared
  connection (see "One key+Duo per session" above) — no second prompt and no
  compute-node host-key confirmation.
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
- [ ] `./laptop/up.sh` prompts for the key + Duo exactly **once**, prints the
      `READY` banner, and opens the tunnel (no second prompt at tunnel time).
- [ ] In a second terminal, `curl http://127.0.0.1:$PORT/api/tags` lists the
      model on the laptop.
- [ ] `curl http://127.0.0.1:$PORT/v1/models` returns an OpenAI-style model list.
- [ ] `opencode.json` lists both `olmo-3:7b-instruct` and `olmo-3:7b-think`
      under `drac-ollama`, and the `reasoner` agent is present.
- [ ] `opencode` starts and the `drac-ollama` provider/model is selectable.
- [ ] `./laptop/disconnect.sh` kills the tunnel; endpoint no longer responds.
- [ ] `./laptop/down.sh` tears down without another prompt (reuses the master),
      and `ssh <login> 'bash <remote>/cluster/teardown.sh'` frees the GPU
      (`squeue -u $USER` is empty for the session).
