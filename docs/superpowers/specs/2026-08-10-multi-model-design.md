# drac-opencode: multi-model setup

## Design

**Date:** 2026-08-10
**Status:** Approved

## Goal

Let a single drac-opencode session serve more than one Ollama model at a time
from the same GPU allocation, so `opencode` on the laptop can switch between
models (e.g. `olmo-3:7b-instruct` for chat and `olmo-3:7b-think` for a
reasoning agent) without re-provisioning. The laptop's `opencode.json` should
end up with one `drac-ollama` provider whose `baseURL` points at the session's
tunneled port, one model entry per served model, plus a `reasoner` agent that
uses the think model with no tool access.

## Background: why this is easy

Ollama natively serves any number of models from one `ollama serve` process.
All models live in the shared bind-mounted store (`$CONFIG_MODELS:/models`),
and the server loads whichever model a request names on demand. The existing
scripts already provision one session, one random port, and one tunnel; the
multi-model change is therefore mostly about *listing* models instead of
naming a single one.

`olmo-3:7b-instruct` and `olmo-3:7b-think` are both standard public Ollama
library tags (`ollama.com/library/olmo-3`), so they are pulled with plain
`ollama pull`; no custom Modelfile/build step is required.

## Decisions (from brainstorming)

1. **One session, both models.** A single GPU allocation, single random port,
   single tunnel. Matches the target `opencode.json`, which uses one
   `baseURL` for both models. Least GPU/Slurm overhead.
2. **`MODELS` list in `config.sh`** is the single source of truth for the model
   list, used by the cluster side (pull/serve) and the laptop side (opencode
   config generation). Env-overridable, like every other config value.
3. **`connect.sh` writes the `reasoner` agent** from a repo template file, so a
   fresh machine gets the full target config automatically.
4. **Approach 1 for the config write:** `jq` builds the provider with one entry
   per model; the agent block is merged from a small repo JSON template
   (`laptop/reasoner.agent.json`). No string templating into JSON.

## Architecture

### `config.sh`

- Replace the single `MODEL` default with a space-separated list:

  ```bash
  : "${MODELS:=olmo-3:7b-instruct olmo-3:7b-think}"
  ```

- One-line backward-compat bridge: if `MODELS` is unset but `MODEL` is set,
  `MODELS="$MODEL"`, so `MODEL=qwen3:14b bash cluster/provision.sh` one-liners
  keep working. `MODEL` is deprecated.
- Export `MODELS` in place of `MODEL` on the export line.

### `cluster/pull-model.sh`

- Loop over `MODELS`; for each model whose manifest is missing under
  `$CONFIG_MODELS`, run `ollama pull` using the existing PULL_PORT helper
  server. Report each model individually ("already present" vs "pulled").
- Exit non-zero on any pull failure (existing `set -e`).
- Update the usage text to say "models" and name `MODELS`.

### `cluster/run-ollama.sh`

- Replace the single-model manifest check with a loop over `MODELS`; on any
  missing manifest, error and list the missing model(s) (same guidance: run
  `cluster/pull-model.sh` from a login node).
- Write `models=<space-separated list>` to the status file instead of
  `model=<model>`.
- Banner echoes the model list. Serving itself is unchanged.

### `laptop/connect.sh`

- Read `models=` from the status file (instead of `model=`) and split on
  spaces; if empty, error as today. In `--dry-run`, use `MODELS` from config.
- `configure_opencode` builds the `drac-ollama` provider with one entry per
  model, and seeds the new config with both the provider and the agent block
  (from `laptop/reasoner.agent.json`), so a fresh `opencode.json` gets the full
  target config in one write:

  ```sh
  new="$(jq -n --arg base "http://127.0.0.1:${port}/v1" --arg models "$MODELS" \
      '{provider: {("drac-ollama"): {
          npm: "@ai-sdk/openai-compatible",
          name: "DRAC Ollama",
          options: {baseURL: $base},
          models: ($models | split(" ") | map({key: ., value: {name: ("DRAC " + .)}}) | from_entries)
      }}}')"
  ```

- When `opencode.json` already exists, merge with `del(.["drac-ollama"])` for
  the provider and `del(.reasoner)` for the agent, then add — preserving every
  other key (`$schema`, `plugin`, other providers and agents) exactly as the
  existing jq merge does.
- Banners and dry-run lines echo the model list. Tunnel, pid file, lsof guard,
  and SSH mux behavior are unchanged.

### New file `laptop/reasoner.agent.json`

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

Merged under `.agent` in the laptop's `opencode.json`, matching the target
config. The `model` reference is intentionally fixed (the think model); it is
not derived from `MODELS`.

### Unchanged files

`cluster/provision.sh` (it already calls `pull-model.sh`, which now loops),
`cluster/teardown.sh`, `cluster/status.sh`, `laptop/setup.sh` (its
`pull-model.sh` call now ensures every model), `laptop/up.sh`,
`laptop/down.sh`, `laptop/disconnect.sh`, `container/`, and the SSH mux
helpers.

## Data flow

1. `laptop/up.sh` → `setup.sh` rsyncs the repo (with `config.sh` containing
   `MODELS`) and calls `pull-model.sh`, which pulls any missing model into
   `$CONFIG_MODELS`.
2. `up.sh` → `connect.sh` runs `provision.sh` (which also calls
   `pull-model.sh`, no-op if present) then `srun` → `run-ollama.sh` on the
   compute node.
3. `run-ollama.sh` verifies every model manifest, starts `ollama serve` on a
   random port, and writes `models=...` (plus `host=`, `ip=`, `port=`) to the
   status file.
4. `connect.sh` reads `models=` and `port=` from the status file, opens the
   tunnel, builds the provider with one entry per model, merges the
   `reasoner` agent, and writes `opencode.json` (backup first, refuse to touch
   unparseable JSON — unchanged behavior).

## Error handling

- Missing manifest at serve time: clear error listing the missing model(s),
  same "pull on a login node" guidance as today.
- Empty `models=` in the status file: existing "could not determine session
  ..." error pattern, updated wording.
- Failed pull: non-zero exit via `set -e`; `provision.sh` propagates it.

## Testing (offline)

- `bash -n` on every changed script.
- Stub ssh/rsync + temp `HOME` + `FAKE_REMOTE` battery, as in prior work:
  - `up.sh --dry-run` lists both models in banners/pid line; no ssh calls.
  - real-mode connect reads `models=` from the stubbed status file; tunnel
    runs; `down.sh` rc=0; every ssh call carries the mux options.
  - `configure_opencode` output (temp `HOME`) contains both model entries
    **and** the `reasoner` agent, and preserves `$schema`/`plugin`.
  - `MODEL=qwen3:14b` bridge: `MODELS` is seeded from `MODEL`; `MODELS` set
    wins.

## Documentation

- `docs/usage.md`: Configuration section lists `MODELS` (default) and notes
  `MODEL` is deprecated; new "Multiple models" paragraph (one session, one
  port, ollama swaps models, add/remove by editing `MODELS`); status file
  field `models=`; reasoner agent documented as written by `connect.sh`; the
  manual checklist gains "both models listed in opencode.json" and "reasoner
  agent present" items.
- `README.md` only if it references `MODEL`/single model wording.
- Historical `docs/superpowers/specs/2026-08-07-*.md` and plans are left
  untouched.

## Out of scope

- Separate sessions/ports per model (rejected in brainstorming).
- Custom-built models via Modelfile (not needed; both models are public tags).
- Managing opencode model/agent entries beyond `drac-ollama` and `reasoner`.

## File-by-file change summary

| File | Change |
| --- | --- |
| `config.sh` | `MODELS` default + `MODEL` bridge; export `MODELS` |
| `cluster/pull-model.sh` | loop over `MODELS`, per-model report, usage text |
| `cluster/run-ollama.sh` | per-model manifest check; status `models=`; banner |
| `laptop/connect.sh` | read `models=`; provider with all models; merge agent template; banners |
| `laptop/reasoner.agent.json` | **new** reasoner agent template |
| `docs/usage.md` | config docs, multi-model paragraph, checklist |
