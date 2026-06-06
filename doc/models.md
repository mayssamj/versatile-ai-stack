# Model <-> agent binding (`vz-ai-stack.sh model`)

`installer/models.yml` is the **single source of truth** for which LLM each
agent uses. `vz-ai-stack.sh model {list,assign,sync,discover,add,superset}` renders
every agent's config and the LiteLLM `model_list` from it.

> Diagrams for everything below live in
> [DIAGRAMS.md](DIAGRAMS.md#5a-per-agent-model-selection-pipeline-assignment---gate---effective---rendered):
> §5a selection pipeline, §5b inference topology, §5c discover/add/sync,
> §5d the RAM-budget preflight, §5e Honcho memory.

## `models.yml` is the single source of truth

One file — `installer/models.yml` — declares **both** every agent's model
binding **and** the canonical entries of the LiteLLM `model_list`. Nothing else
hand-edits an agent's model; `vz-ai-stack.sh model {list,assign,sync,discover,add,superset}`
renders it all from this file.

### The three canonical model IDs

| LiteLLM model_name  | runtime    | served id                          | flags | notes |
|---------------------|------------|------------------------------------|-------|-------|
| `local-gemma4`      | ollama     | `gemma4:e4b`                       | **default**, `big: false` | for any unassigned agent. ~9.6GB, stays on Ollama. |
| `local-qwen3.6`     | lmstudio   | `qwen/qwen3.6-27b`                 | `big: true`, `ttl: 1800`  | ~17.5GB MLX. Cannot coexist with `local-qwen3-coder` on 24GB. |
| `local-qwen3-coder` | lmstudio   | `qwen3-coder-30b-a3b-instruct-mlx` | `big: true`, `ttl: 1800`  | ~17.2GB MLX. Cannot coexist with `local-qwen3.6` on 24GB. |

### The 14 agents (assignments + kinds)

`models.yml` binds **14 agents** — the 9 Hermes profiles (a full
software-engineering team) plus `pi`, `deerflow`, `ace`, `rlm`, and `mempalace`
— each via an `assignments:` line (the model) and a `kinds:` entry (the renderer
+ scoped-key env). Any agent with no assignment falls back to the `default`
(`local-gemma4`). The nine Hermes profiles all route to a **Claude
subscription via Meridian** and are availability-gated to `local-gemma4` when
Meridian is down. The same 9-role team is also realized as **Pi personas**
(`bin/pi-as <role>`) and **Claude Code subagents** (`~/.claude/agents`),
sharing the `team-protocol` skill.

| Agent | Assigned | Kind | Scoped key |
|-------|----------|------|------------|
| `hermes_manager`            | `claude-opus-4.8-sub-high`   | hermes-profile | `HERMES_LITELLM_KEY` (shared by all 9 profiles) |
| `hermes_techlead`           | `claude-opus-4.8-sub-high`   | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_ml_engineer`        | `claude-opus-4.8-sub-high`   | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_frontend_engineer`  | `claude-sonnet-4.6-sub-high` | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_backend_engineer`   | `claude-sonnet-4.6-sub-high` | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_qa_test_engineer`   | `claude-sonnet-4.6-sub-high` | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_reviewing_engineer` | `claude-sonnet-4.6-sub-high` | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_sre_engineer`       | `claude-sonnet-4.6-sub-high` | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_incident_manager`   | `claude-sonnet-4.6-sub-high` | hermes-profile | `HERMES_LITELLM_KEY` |
| `pi`                       | `claude-opus-4.8-sub-max` | pi       | `PI_LITELLM_KEY` |
| `deerflow`                 | `claude-opus-4.8-sub-max` | deerflow | *(none — master key)* |
| `ace`                      | `local-gemma4`      | ace            | `ACE_LITELLM_KEY` |
| `rlm`                      | `local-gemma4`      | rlm            | `RLM_LITELLM_KEY` |
| `mempalace`                | `local-gemma4`      | mempalace      | `MEMPALACE_LITELLM_KEY` |

**MemPalace is a partial binding.** `mempalace` (Phase 26, opt-in) is a
host-side CLI/MCP memory tool, not a chat agent. Its `MEMPALACE_LITELLM_KEY`
(scoped to local models) is used **only** for the *optional* entity-refiner
(`mempalace mine --extract general`); that path defaults to `local-gemma4` and
is availability-gated like everything else (gates to the default when the
assigned slug isn't servable). MemPalace's **embeddings are NOT a model
binding** — they are **on-device ONNX** (`all-MiniLM-L6-v2` by default, run via
CoreML on the M4 ANE; `embeddinggemma` multilingual opt-in), so they never
touch `models.yml`, LiteLLM, or Ollama. Skip the refiner and MemPalace makes no
LiteLLM call at all.

The legacy slugs (`local`, `local-heavy`, `local-lfm2`, `local-lfm2-mlx`) are
**never deleted** — the canonical IDs are added alongside them (add-only). New
and old coexist; agents can still be pointed at a legacy slug by hand.

## LiteLLM is the only hub (`litellm:4000`)

Every chat and embedding call funnels through **one** LiteLLM gateway at
`http://litellm:4000`. Agents hold only a **scoped virtual key**, never a
provider key — the real Anthropic/OpenAI/OpenRouter/Gemini keys live **only** in
LiteLLM's own environment. No agent, sandbox, or scoped key ever carries a
provider key. LiteLLM enforces the per-key allowlist server-side, so a request
for a cloud model under a local-only key is rejected with **HTTP 403**.

The base URL differs by where the caller sits (same gateway, different DNS):

| Caller | Dial point |
|--------|------------|
| Mac / containers on the `ai-stack` network | `http://litellm:4000` |
| Pi sandbox (host-side) | `http://host.docker.internal:4000` |
| Honcho (multi-network) | `http://litellm.ai-stack:4000` (fully-qualified) |

See [DIAGRAMS.md §5b](DIAGRAMS.md#5b-multi-engine-inference-topology--one-hub-three-runtimes).

## The four runtimes

LiteLLM fronts four back ends. **At least one must be active** — the end-of-run
`print_inference_hint` (in `installer/lib/lmstudio.sh`) shows up/down state and
the start command for each.

- **Ollama** (host, Homebrew) — **lazy**: Phase 00 sets `OLLAMA_KEEP_ALIVE=0` so
  no model stays resident between requests; Phase 01 eager-pulls **only**
  `gemma4:e4b` + `nomic-embed-text`. Serves the default `local-gemma4`. Reached
  by LiteLLM at `http://ollama:11434`.
- **LM Studio (MLX)** — **opt-in, no auto-start**. Reached at
  `http://host.docker.internal:${LMS_PORT}/v1` (`LMS_PORT` defaults to `1234` —
  see `LMS_PORT` in `installer/lib/lmstudio.sh`). Serves `local-qwen3.6` /
  `local-qwen3-coder`. The host-side probe uses `http://127.0.0.1:${LMS_PORT}`
  (`LMS_URL`); the container-side route is `host.docker.internal:${LMS_PORT}`.
- **Cloud** (optional) — Anthropic / OpenAI / OpenRouter / Gemini, used **only**
  when you point an agent at a non-local model and set that provider key in
  LiteLLM's env.
- **Meridian (Claude subscription)** — **opt-in, no API key**. A host daemon
  (`bin/start-meridian.sh`, launchd-supervised on `127.0.0.1:3456`) that reuses
  your `claude login` OAuth — auto-refreshed — and runs the Claude Code agent
  loop (internal mode). LiteLLM dials it exactly like LM Studio
  (`http://host.docker.internal:3456/v1`). The `-sub-` suffix marks the
  SUBSCRIPTION routes, distinct from the metered API-key `claude-opus-4.7` /
  `claude-sonnet-4.6`. This is how Open WebUI chats/codes on your **Pro/Max
  subscription** rather than a metered API key.
  Install: `npm install -g @rynfar/meridian && bash bin/start-meridian.sh install`.
  - **Effort ladder (one model per level):**
    `claude-opus-4.8-sub-{low,medium,high,xhigh,max}` and
    `claude-sonnet-4.6-sub-{low,medium,high,max}` (Sonnet omits `xhigh` — it
    falls back to `high`). Open WebUI's default is `claude-opus-4.8-sub-max`
    (`DEFAULT_MODELS` in `bin/start-openwebui.sh`). Pick effort by picking the
    model — per-chat effort can't be sent from Open WebUI (`drop_params`).
  - **How effort is wired:** Opus 4.8 depth is `output_config.effort`
    (low/medium/high/xhigh/max), NOT a token budget (`budget_tokens` is rejected
    on 4.7+). Each model sets `extra_body: { effort: <level> }`; **verified on
    the wire** that LiteLLM forwards it as `body.effort`, which Meridian reads
    and passes into the Agent SDK `query({effort})`. ⚠️ The plumbing is proven,
    but a low-vs-max output-token A/B showed **no measurable difference** (Meridian's
    internal mode hides thinking, so thinking tokens aren't reflected in
    `completion_tokens` — effort may apply without a visible signal). Reasoning
    TEXT also does not render in Open WebUI through this bridge.
  - **Thinking** is forced on by default (`~/.config/meridian/sdk-features.json`,
    `thinking: enabled` per adapter — seeded by `start-meridian.sh install`).
  - **Billing (Pro):** as of 2026-06-15 third-party Agent-SDK usage (Meridian)
    draws from a separate capped monthly credit (~$20 on Pro), then API rates;
    `max`/`xhigh` burn it fastest. **Loopback-only** (holds a live OAuth + can
    run host tools — do not expose off-box).
  - These models are declared in **`installer/models.yml`** with `runtime:
    meridian` (+ an `effort:` field) — `model sync` renders them into
    `litellm/config.yaml`, joins them to the scoped-key superset, and makes them
    **assignable** (`vz-ai-stack.sh model assign pi claude-opus-4.8-sub-xhigh`).
    They availability-gate to `default` (local-gemma4) when Meridian is down.
  - **Current assignments:** `pi` (coding) and `deerflow` (research) →
    `claude-opus-4.8-sub-max`. The 9-role Hermes fleet runs on the subscription too
    — the three senior roles (`hermes_manager`, `hermes_techlead`, `hermes_ml_engineer`)
    on `claude-opus-4.8-sub-high`, the other six on `claude-sonnet-4.6-sub-high` (see
    the assignment table above). All availability-gate to `default` (local-gemma4)
    when Meridian is down. ACE/RLM stay local.

## Workflow

```sh
vz-ai-stack.sh model list                 # READ-ONLY catalog + live agent matrix
vz-ai-stack.sh model list --json          # machine-readable
vz-ai-stack.sh model assign pi local-qwen3-coder   # re-point one agent (then syncs it)
vz-ai-stack.sh model assign all local-gemma4       # blanket-assign EVERY agent (before→after + models.yml.bak), then syncs
vz-ai-stack.sh model sync                 # render EVERY agent + the LiteLLM model_list
vz-ai-stack.sh model sync pi              # render just one agent
vz-ai-stack.sh model sync --dry-run       # print the plan + a config.yaml diff, write nothing
vz-ai-stack.sh model sync --no-restart    # don't restart LiteLLM even if config changed
vz-ai-stack.sh model discover             # READ-ONLY LM Studio library catalog (server may be down)
vz-ai-stack.sh model add <slug> [as <name>]        # declare an LM Studio library model, then sync
vz-ai-stack.sh model superset             # print the DERIVED scoped-key allowlist
vz-ai-stack.sh model superset --json      # machine-readable
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

## Per-agent selection pipeline

See [DIAGRAMS.md §5a](DIAGRAMS.md#5a-per-agent-model-selection-pipeline-assignment---gate---effective---rendered).
Each agent's live model is resolved in four stages:

1. **assignment** — the model named for the agent in `models.yml`.
2. **availability-gate** — an `lmstudio` model is kept only when LM Studio is up
   on `:${LMS_PORT}` **and** its slug is in `litellm/config.yaml` **and** LiteLLM's
   `/v1/models` lists it; otherwise it gates down to `local-gemma4` and records a
   pending entry. An `ollama` model is never gated — it renders as-is.
3. **effective** — what we *will* render (assigned, or the gated-down default).
4. **rendered** — what is *actually* wired. `model list` shows the live matrix
   (`ASSIGNED` / `LITELLM` / `SERVED` / `KEY-OK` / `DRIFT` / `EFFECTIVE`); if
   rendered ≠ effective it flags **DRIFT** — re-run `model sync <agent>`.

The renderer dispatches by `kind`: `render_hermes` (OpenShell `config set`),
`render_pi` (`PI_DEFAULT_MODEL`), `render_deerflow`, `render_ace`
(allowlist-only), `render_rlm`, `render_mempalace` (writes the refiner's model
for the optional `--extract general` path; embeddings are on-device ONNX and
out of band). **DeerFlow is special**: it writes **two tiers**
— `basic` is **always** `local-gemma4` (the default), `reasoning` takes the
gated effective model — and it uses the **master key** (no scoped allowlist), so
the scoped-key widening (P3 below) does not apply to it.

## Overkill protection — the RAM-budget preflight (F1)

See [DIAGRAMS.md §5d](DIAGRAMS.md#5d-ram-budget-preflight--the-overkill-guard-that-refuses-an-over-commit).
The box once swap-thrash-LOCKED from a big-MLX over-commit, so before loading a
big model `lms_load_big` runs `lms_ram_preflight`, which **refuses** the load
when, *strictly*:

```
cap + padded_model + headroom > total RAM
```

(equality **loads** — the operator is `>`, not `>=`). The terms:

| Term | Value | Source |
|------|-------|--------|
| `headroom` | **5 GiB** = `5368709120` B | `LMS_RAM_HEADROOM_BYTES` |
| unknown-size fallback | **18 GiB** = `19327352832` B | `LMS_BIG_FALLBACK_BYTES` (used when on-disk size ≤ 0) |
| resident pad | **+15%** on disk size | `LMS_MODEL_PAD_PCT` |
| `cap` | OrbStack reserved VM memory | `~/.orbstack/vmconfig.json` `memory_mib` (fallback `max(8 GiB, total/2)`) |
| `total` | physical RAM | `sysctl hw.memsize` |

It **degrades OPEN** (allows, with a note) on *any* measurement failure — e.g.
`hw.memsize` unreadable — so it never fails closed. A refusal makes the agent
**availability-gate to `local-gemma4`**. Bypass with `LMS_SKIP_RAM_PREFLIGHT=1`
(use sparingly — the box crashed from over-commit).

**One big MLX at a time.** `local-qwen3.6` and `local-qwen3-coder` are ~17GB each
and **cannot coexist** on a 24GB box. `lms_load_big` unloads any *other* loaded
model before loading the requested one, then loads with a TTL (`ttl: 1800`) so
LM Studio auto-evicts after idle. Doctor check 38 warns (advisory) if both big
MLX models are resident. In the LM Studio GUI, *Settings → Auto-evict* (JIT +
idle TTL) keeps only one resident.

Ollama is also kept lazy: Phase 00 sets `OLLAMA_KEEP_ALIVE=0` so it never keeps
a model resident between requests, and Phase 01 only eager-pulls `gemma4:e4b`
+ `nomic-embed-text` (qwen3.6 moved to LM Studio; LFM2.5 GGUF is no longer
pre-pulled).

See `installer/lib/lmstudio.sh` lines 19-21 (constants) and 204-218 (the rule).

## Discover / add / sync across engines

See [DIAGRAMS.md §5c](DIAGRAMS.md#5c-model-discovery--add--sync-lifecycle-lm-studio-library---modelsyml---litellm).

- **`model discover`** — READ-ONLY: reads the on-disk LM Studio library catalog
  (`lms ls --json`, LLMs + embeddings + sizes), which works with the server
  **down**. Marks which entries are already **DECLARED** by exact served-id
  match. Loads nothing; never auto-starts LM Studio.
- **`model add <slug> [as <name>]`** — declares an existing library LLM into
  `models.yml` (infers `big` from on-disk size vs the `MODEL_BIG_GB` threshold,
  default 8GB; unknown size → `big: true`, RAM-cautious), **never loads** it,
  then runs `sync`.
- **`model sync`** — the crash-safe 6-phase reconcile: **P0** validate
  (fail-closed) → **P1** register `model_list` (add-only, atomic) → **P2**
  restart LiteLLM **once** iff `config.yaml` changed → **P3** widen scoped keys
  to the **derived** superset → **P4** render agents (availability-gated) →
  **P5** verify (drift + key coverage; advisory).

## Scoped keys: the DERIVED superset

Every scoped virtual key (Hermes, Pi, ACE, RLM, MemPalace) is minted against the
**superset** so `assign`/`add`/`sync` can re-point an agent **without ever
re-minting** a key. The canonical IDs are registered in `config.yaml` *before*
any key is minted (superset-before-mint).

The superset is **not** a hardcoded list — it is **DERIVED** (the sorted-unique
union of the legacy names `{local, local-heavy, local-lfm2}` **plus every model
key in `models.yml`**), computed by `superset_members()` and printed by
`vz-ai-stack.sh model superset`. So a `model add`-ed slug is automatically covered
— **do not hand-edit any array**. The hardcoded `LEGACY_SUPERSET` (the 6-name
array in `installer/lib/models.sh`) is **only** the fallback used when
`models.yml` is absent/unparseable.

LiteLLM still enforces the allowlist server-side, so a cloud model under a
local-only key is rejected with HTTP 403. DeerFlow uses the **master key** and
has no scoped allowlist to widen. Doctor check 40 (`40_models_binding.sh`) turns
RED if a scoped key drifts below the superset.

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
2. Scoped keys cover it automatically — the superset is **derived** from
   `models.yml` (see "Scoped keys: the DERIVED superset" above), so there is
   **no array to edit**. For an LM Studio library model, prefer
   `vz-ai-stack.sh model add <slug>` (or `model assign`), which extends the derived
   superset for you. The `LEGACY_SUPERSET` array in `installer/lib/models.sh` is
   only the fallback used when `models.yml` is missing.
3. `vz-ai-stack.sh model sync` (registers it in `config.yaml`, restarts LiteLLM
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
3. `vz-ai-stack.sh model sync my_agent`.

## Per-agent memory (Honcho)

See [DIAGRAMS.md §5e](DIAGRAMS.md#5e-honcho-agent-memory--derivation-via-litellm-not-to-be-confused-with-11-memory-profiles).
Honcho gives each agent/peer a **namespace-isolated** memory. Its *deriver*
extracts user representations from messages and runs them through LiteLLM at
`http://litellm.ai-stack:4000/v1` (so derivation cost shows up in Phoenix).
`AUTH_USE_AUTH=false`; data persists in `data/honcho` Postgres and never leaves
the machine.

**Deliberate exception to per-agent `models.yml` selection.** The deriver uses a
single stack-wide model for *all* derivation (independent of each agent's
chat-model assignment), since persona extraction wants one consistent model. It
defaults to the canonical stack default — `models.yml .default` (`local-gemma4`,
served by Ollama) — like every other service, and is **overridable via the
`HONCHO_DERIVER_MODEL` env var** in the stack `.env`. The memory plane does
**not** go through `models.yml` per-agent availability-gating.

> **Default source.** `installer/phases/03_honcho.sh` reads
> `HONCHO_DERIVER_MODEL` (falling back to `models.yml .default`) and writes it to
> `honcho/.env` as `LLM_OPENAI_MODEL`. To use a heavier model for richer
> personas, set `HONCHO_DERIVER_MODEL=local-qwen3.6` (or pull `qwen3.6:27b` and
> use `local-heavy`) in `.env`, then `docker compose up -d deriver` from
> `honcho/` to recreate the container so it reloads the env.
>
> *(Was previously pinned to `local-heavy` → `ollama_chat/qwen3.6:27b-q4_K_M`,
> which is not pre-pulled, so every derivation hit the `local-heavy: ["local"]`
> fallback. Now points directly at the served default — no wasted retry.)*
