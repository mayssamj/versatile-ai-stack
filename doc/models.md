# Model <-> agent binding (`install.sh model`)

`installer/models.yml` is the **single source of truth** for which LLM each
agent uses. `install.sh model {list,assign,sync,superset}` renders every agent's
config and the LiteLLM `model_list` from it.

## The three canonical model IDs

| LiteLLM model_name  | runtime    | served id                          | notes |
|---------------------|------------|------------------------------------|-------|
| `local-gemma4`      | ollama     | `gemma4:e4b`                       | **default** for any unassigned agent. ~9.6GB, stays on Ollama. |
| `local-qwen3.6`     | lmstudio   | `qwen/qwen3.6-27b`                 | ~17.5GB MLX. Big. |
| `local-qwen3-coder` | lmstudio   | `qwen3-coder-30b-a3b-instruct-mlx` | ~17.2GB MLX. Big. |

The legacy slugs (`local`, `local-heavy`, `local-lfm2`, `local-lfm2-mlx`) are
**never deleted** — the canonical IDs are added alongside them (add-only). New
and old coexist; agents can still be pointed at a legacy slug by hand.

## Workflow

```sh
install.sh model list                 # READ-ONLY catalog + live agent matrix
install.sh model list --json          # machine-readable
install.sh model assign pi local-qwen3-coder   # re-point one agent (then syncs it)
install.sh model sync                 # render EVERY agent + the LiteLLM model_list
install.sh model sync pi              # render just one agent
install.sh model sync --dry-run       # print the plan + a config.yaml diff, write nothing
install.sh model sync --no-restart    # don't restart LiteLLM even if config changed
install.sh model superset             # print the canonical scoped-key allowlist
install.sh model superset --json      # machine-readable
```

`model sync` is **opt-in** — it is *not* run by `install all` (like `install
25`). A fresh `install all` works end-to-end with LM Studio NOT running.

### The agent matrix (`model list`)

| column     | meaning |
|------------|---------|
| `ASSIGNED` | the model declared for the agent in `models.yml` |
| `LITELLM`  | is the assigned model_name present in `litellm/config.yaml`? |
| `SERVED`   | does the master key's `/v1/models` list it? (`ok`/`down`; `down` for an lmstudio model is **advisory-yellow**, not an error) |
| `KEY-OK`   | does the agent's scoped key allowlist cover the effective model? |
| `DRIFT`    | does the rendered config match the declared (gated) model? |
| `EFFECTIVE`| what is actually rendered right now (after availability-gating) |

ACE shows `(allowlist-only)` because ACE upstream may ignore `OPENAI_MODEL` —
the binding is enforced only by the scoped-key allowlist, not a model selector.

## Availability gating (why a fresh install stays safe)

An agent assigned an **lmstudio** model is rendered to that MLX slug **only**
when all of these hold:

1. LM Studio's server is up on `:1234`, and
2. the slug is in `litellm/config.yaml`, and
3. LiteLLM actually serves it (master-key `/v1/models` lists it).

Otherwise the agent is rendered to the Ollama default `local-gemma4`, and a
line is recorded in `installer/state/models-pending.txt`. This is why
`model sync` never produces a 404/503 on a box where LM Studio is down: the MLX
slug is only ever written once it's confirmed servable. Start LM Studio, load
the model, and re-run `model sync` to promote the pending agents.

## One-big-MLX RAM policy (24GB box)

`local-qwen3.6` and `local-qwen3-coder` are ~17GB each and **cannot coexist** in
RAM on a 24GB machine. The stack enforces "one big MLX model at a time":

- `lms_load_big` unloads any other loaded model before loading the requested
  one, and loads with a TTL (`ttl: 1800` in `models.yml`) so LM Studio
  auto-evicts it after idle.
- In the **LM Studio GUI**, enable *Settings -> Auto-evict* (JIT loading +
  idle TTL) so a model that hasn't been used is unloaded automatically.
- Doctor check 38 warns (advisory) if both big MLX models are resident.

Ollama is also kept lazy: Phase 00 sets `OLLAMA_KEEP_ALIVE=0` so it never keeps
a model resident between requests, and Phase 01 only eager-pulls `gemma4:e4b`
+ `nomic-embed-text` (qwen3.6 moved to LM Studio; LFM2.5 GGUF is no longer
pre-pulled).

## Scoped keys: the fixed SUPERSET

Every scoped virtual key (Hermes, Pi, ACE, RLM) is minted against the **fixed
superset**:

```
local, local-gemma4, local-heavy, local-lfm2, local-qwen3-coder, local-qwen3.6
```

so `assign`/`sync` can re-point an agent **without ever re-minting** a key. The
canonical IDs are registered in `config.yaml` *before* any key is minted
(superset-before-mint). LiteLLM still enforces the allowlist server-side, so a
cloud model is rejected with HTTP 403. DeerFlow uses the **master key** and has
no scoped allowlist to widen.

## Crash-safe `model sync` order

P0 validate (fail-closed) -> P1 register `model_list` (add-only, atomic) ->
P2 restart LiteLLM **once** iff `config.yaml` changed -> P3 widen scoped-key
allowlists to the superset -> P4 per-agent render (availability-gated) ->
P5 verify. An agent is never left requesting a model its key forbids or the
gateway can't serve.

## Extension recipes

### Add a NEW model

1. Add an entry under `models:` in `installer/models.yml`:
   ```yaml
   models:
     my-new-model:
       runtime: ollama          # or lmstudio
       served: some-ollama-tag  # or the LM Studio served id
       big: false
   ```
2. If it's an lmstudio model that should widen scoped keys, add its
   `model_name` to the `SUPERSET` array in `installer/lib/models.sh` (and to the
   per-phase mint `-d '{"models":[...]}'` lists) so keys cover it.
3. `install.sh model sync` (registers it in `config.yaml`, restarts LiteLLM
   once, widens keys, renders any agent assigned to it).

### Add a NEW agent

1. Add an `assignments:` line + a `kinds:` entry in `models.yml`:
   ```yaml
   assignments:
     my_agent: local-gemma4
   kinds:
     my_agent: { kind: <hermes-profile|pi|deerflow|ace|rlm>, key_env: MY_KEY }
   ```
   Use an existing `kind` whose renderer matches how the agent is configured.
2. If the agent needs a brand-new render shape, add a `case` arm to the
   `render_agent` dispatch in `installer/lib/models.sh` (keep it a simple case —
   not a plugin framework).
3. `install.sh model sync my_agent`.
