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

### The local model IDs (nemotron-only, 2026-07-01)

`nemotron-3-nano:4b` is the ONLY local chat model. `local` and `local-heavy`
BOTH map to it (there is no separate heavy local model).

| LiteLLM model_name  | runtime    | served id                          | flags | notes |
|---------------------|------------|------------------------------------|-------|-------|
| `local` / `local-heavy` | ollama | `nemotron-3-nano:4b`             | **default**, `big: false` | The ONLY local chat model + the always-on Ollama FALLBACK (`default`) — what every agent gates to when its runtime is down. `local` and `local-heavy` both map here. ~2.8 GB, stays on Ollama. |
| `local-nemotron3-nano-4b` | ollama | `nemotron-3-nano:4b`          | `big: false`              | Explicit-name alias of `local` (same model). |
| `local-nemotron3-nano-4b-mlx` | lmstudio | `nvidia/nemotron-3-nano-4b` | `big: false` (opt-in) | Same nemotron model on Apple MLX via LM Studio (Phase 25, opt-in; needs `start lmstudio`). |

### The 13 agents (assignments + kinds)

`models.yml` binds **13 agents** — the 9 Hermes profiles (a full
software-engineering team) plus `pi`, `deerflow`, `ace`, and `rlm`
— each via an `assignments:` line (the model) and a `kinds:` entry (the renderer
+ scoped-key env). Any agent with no assignment now renders the **`primary`**
(`claude-opus-sub-max`), which availability-gates to the `default`
(`local`, the always-on Ollama fallback) when Meridian is down. The
nine Hermes profiles all route to a **Claude
subscription via Meridian** and are availability-gated to `local` when
Meridian is down. The same 9-role team is also realized as **Pi personas**
(`bin/pi-as <role>`) and **Claude Code agents** (the `manager` is the MAIN
agent, installed as a `~/.claude/CLAUDE.md` @-import; the other 8 roles are
subagents at `~/.claude/agents/<role>.md`), sharing the `team-protocol` skill.

| Agent | Assigned | Kind | Scoped key |
|-------|----------|------|------------|
| `hermes_manager`            | `claude-opus-sub-xhigh`  | hermes-profile | `HERMES_LITELLM_KEY` (shared by all 9 profiles) |
| `hermes_techlead`           | `claude-opus-sub-max`    | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_ml_engineer`        | `claude-opus-sub-max`    | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_frontend_engineer`  | `claude-opus-sub-max`    | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_backend_engineer`   | `claude-opus-sub-max`    | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_qa_test_engineer`   | `claude-opus-sub-xhigh`  | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_reviewing_engineer` | `claude-opus-sub-max`    | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_sre_engineer`       | `claude-opus-sub-xhigh`  | hermes-profile | `HERMES_LITELLM_KEY` |
| `hermes_incident_manager`   | `claude-opus-sub-xhigh`  | hermes-profile | `HERMES_LITELLM_KEY` |
| `pi`                       | `claude-opus-sub-max` | pi       | `PI_LITELLM_KEY` |
| `deerflow`                 | `claude-opus-sub-max` | deerflow | *(none — master key)* |
| `ace`                      | `claude-opus-sub-xhigh` | ace            | `ACE_LITELLM_KEY` |
| `rlm`                      | `claude-opus-sub-xhigh` | rlm            | `RLM_LITELLM_KEY` |
| `mempalace`                | `local`      | mempalace      | `MEMPALACE_LITELLM_KEY` |

**MemPalace is a partial binding.** `mempalace` (Phase 26) is a
host-side CLI/MCP memory tool, not a chat agent. Its `MEMPALACE_LITELLM_KEY`
(scoped to local models) is used **only** for the *optional* entity-refiner
(`mempalace mine --extract general`); that path defaults to `local` and
is availability-gated like everything else (gates to the default when the
assigned slug isn't servable). MemPalace's **embeddings are NOT a model
binding** — they are **on-device ONNX** (`all-MiniLM-L6-v2` by default, run via
CoreML on the M4 ANE; `embeddinggemma` multilingual opt-in), so they never
touch `models.yml`, LiteLLM, or Ollama. Skip the refiner and MemPalace makes no
LiteLLM call at all.

`local` and `local-heavy` both resolve to `nemotron-3-nano:4b` — the ONLY local
chat model (2026-07-01). The opt-in LM Studio slugs (`local-nemotron3-nano-4b-mlx`
= the same nemotron on Apple MLX, and the `local-lfm2-mlx` LFM2.5 demo) require
`install lmstudio` and are never auto-pulled. Old scoped keys keep resolving
because the canonical IDs are added to the superset **add-only** — nothing is
deleted from an existing key's allowlist.
Use **`local`** in any runnable example. An agent can still be pointed at
a retired slug by hand, but it 503s unless you pull/serve it yourself.

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

## The inference runtimes

LiteLLM fronts several back ends. **At least one must be active** — the end-of-run
`print_inference_hint` (in `installer/lib/lmstudio.sh`) shows up/down state and
the start command for each.

- **Ollama** (host, Homebrew) — **lazy**: Phase 00 sets `OLLAMA_KEEP_ALIVE=30m` so
  the default model stays warm for 30 min of inactivity, then unloads; Phase 01 eager-pulls **only**
  `nemotron-3-nano:4b` + `nomic-embed-text`. Serves the default `local`. Reached
  by LiteLLM at `http://ollama:11434`.
- **LM Studio (MLX)** — **opt-in, no auto-start**. Start the server with
  `vz-ai-stack.sh start lmstudio` (idempotent; warns it idle-spins ~0.8 core, so
  quit when done, and that **no model auto-loads** — assign one in `models.yml` +
  `vz-ai-stack.sh model sync`). `vz-ai-stack.sh stop lmstudio` stops the server.
  Reached at `http://host.docker.internal:${LMS_PORT}/v1` (`LMS_PORT` defaults to
  `1234` — see `LMS_PORT` in `installer/lib/lmstudio.sh`). Serves `local` /
  `local`. The host-side probe uses `http://127.0.0.1:${LMS_PORT}`
  (`LMS_URL`); the container-side route is `host.docker.internal:${LMS_PORT}`.
- **Cloud** (optional) — Anthropic / OpenAI / OpenRouter / Gemini, used **only**
  when you point an agent at a non-local model and set that provider key in
  LiteLLM's env.
- **`openai-compat` (generic OpenAI-compatible cloud route)** — the only runtime
  whose endpoint + key are **data**, not hardcoded. Declare a model in
  `installer/models.yml` with `runtime: openai-compat` (`served` + `api_base` +
  `key_env`, optional integer `rpm`/`tpm`) and `model sync` renders
  `{model: openai/<served>, api_base, api_key: os.environ/<KEY_ENV>}` into
  `litellm/config.yaml` and joins it to the scoped-key superset — so a metered vendor
  like **Sakana Fugu** (`sakana-fugu` / `sakana-fugu-ultra`, `key_env SAKANA_API_KEY`)
  is **assignable** (`vz-ai-stack.sh model assign <agent> sakana-fugu`), not just a
  hand-edited config entry. The `api_key` stays the literal `os.environ/` sentinel
  (never the expanded secret). Availability-gates to `default` (local) when the
  key is absent. The key must also be in `bin/start-litellm.sh`'s `-e` allowlist
  (`bin/start-litellm.sh --recreate` to apply a newly-added one — env is injected at
  container CREATE, not on `docker restart`).
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
    `claude-opus-sub-{low,medium,high,xhigh,max,ultracode}` and
    `claude-sonnet-sub-{low,medium,high,max,ultracode}` (Sonnet omits `xhigh` — it
    falls back to `high`). `ultracode` is the coding-focused highest effort tier
    (above `max`). Open WebUI's default is `claude-opus-sub-max`
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
    **assignable** (`vz-ai-stack.sh model assign pi claude-opus-sub-xhigh`).
    They availability-gate to `default` (local) when Meridian is down.
  - **Current assignments:** every agent runs on the **Claude Opus subscription**
    via Meridian. `pi` and `deerflow` → `claude-opus-sub-max`; `ace` and `rlm` →
    `claude-opus-sub-xhigh`. The 9-role Hermes fleet is all-Opus too — `manager`,
    `qa_test_engineer`, `sre_engineer`, `incident_manager` on `claude-opus-sub-xhigh`
    and `techlead`, `ml_engineer`, `frontend_engineer`, `backend_engineer`,
    `reviewing_engineer` on `claude-opus-sub-max` (see the assignment table above).
    All availability-gate to `default` (local) when Meridian is down.
- **Codex bridge (ChatGPT subscription)** — **opt-in, no API key, ⚠ ToS-gray**.
  The OpenAI analog of Meridian: a host daemon (`bin/start-codex-bridge.sh`,
  launchd-supervised on `127.0.0.1:3457`) running the `openai-oauth` proxy, which
  reuses the OAuth that `codex login` caches in `~/.codex/auth.json`
  (auto-refreshed) to reach GPT-5.x on your **ChatGPT Plus/Pro plan** instead of a
  metered key. LiteLLM dials it exactly like Meridian
  (`http://host.docker.internal:3457/v1`, dummy key). Models: `openai-gpt-5.5-sub`
  / `openai-gpt-5.4-sub` (the `-sub` suffix = subscription, distinct from the
  metered `openai-gpt-5.5` / `openai-gpt-5.4`).
  Enable (one command): `bash bin/start-codex-bridge.sh enable` — codex login (if
  needed) + install + LiteLLM reload; shows a one-time risk banner. Full how-to:
  **[GPT5.md](GPT5.md)**.
  - **⚠ Unlike Meridian** (which uses Anthropic's *official* Agent SDK), this
    wraps the ChatGPT *product* backend (`chatgpt.com/backend-api/codex`) —
    **unofficial** automated use. Real, non-recoverable risk: OpenAI may
    **suspend the ChatGPT account** you use day to day. **Single personal account
    only** — pooling/sharing is a clear ToS violation. It can break without notice
    when OpenAI changes the backend. The metered `OPENAI_API_KEY` path
    (`openai-gpt-5.5`/`5.4`) already works and stays the supported default; this
    only avoids metered cost.
  - **Rate-limited by your plan** (Plus ≈ 15–80 GPT-5.5 msgs / 5h) — a
    secondary/occasional route, not a fleet workhorse. A soft `rpm`/`tpm`
    burst-guard is set on the model entries.
  - **Assignable** (2026-06-22): declared in `installer/models.yml` with `runtime:
    codex-bridge`, so any agent or the whole fleet can be pointed at them —
    `vz-ai-stack.sh model assign all openai-gpt-5.5-sub`. The metered twins use
    `runtime: openai` (`openai-gpt-5.5` / `openai-gpt-5.5-pro` / `openai-gpt-5.4`).
    `effort` (optional, → OpenAI `reasoning_effort` none|low|medium|high|xhigh;
    `xhigh`=max) is set per entry. They **availability-gate to `default`**
    (local) when the bridge is down (codex-bridge) or `OPENAI_API_KEY` is
    absent (openai) — a pending line, never a hard fail, and **never** the metered
    key as a silent fallback. Doctor check 55 reports bridge health (advisory-green
    when not installed; never prints a token).
  - **Loopback-only** (holds a live OAuth — do not expose off-box).

## Workflow

```sh
vz-ai-stack.sh model list                 # READ-ONLY catalog + live agent matrix
vz-ai-stack.sh model list --json          # machine-readable
vz-ai-stack.sh model assign pi local   # re-point one agent (then syncs it)
vz-ai-stack.sh model assign all local       # blanket-assign EVERY agent (before→after + models.yml.bak), then syncs
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

Otherwise the agent is rendered to the Ollama default `local`, and a
line is recorded in `installer/state/models-pending.txt`. This is why
`model sync` never produces a 404/503 on a box where LM Studio is down: the MLX
slug is only ever written once it's confirmed servable. Start LM Studio, load
the model, and re-run `model sync` to promote the pending agents.

## Per-agent selection pipeline

See [DIAGRAMS.md §5a](DIAGRAMS.md#5a-per-agent-model-selection-pipeline-assignment---gate---effective---rendered).
Each agent's live model is resolved in four stages:

1. **assignment** — the model named for the agent in `models.yml`. An agent with
   **no** assignment renders the **`primary`** (`models.yml .primary` =
   `claude-opus-sub-max`), which then flows through the availability-gate
   below; only `default` (`local`) is the always-on Ollama fallback.
2. **availability-gate** — an `lmstudio` model is kept only when LM Studio is up
   on `:${LMS_PORT}` **and** its slug is in `litellm/config.yaml` **and** LiteLLM's
   `/v1/models` lists it; otherwise it gates down to `local` and records a
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
— `basic` is **always** `local` (the default), `reasoning` takes the
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
**availability-gate to `local`**. Bypass with `LMS_SKIP_RAM_PREFLIGHT=1`
(use sparingly — the box crashed from over-commit).

**One MLX model at a time.** The opt-in LM Studio MLX slugs load into RAM;
`lms_load_big` unloads any *other* loaded
model before loading the requested one, then loads with a TTL (`ttl: 1800`) so
LM Studio auto-evicts after idle. Doctor check 38 warns (advisory) if both big
MLX models are resident. In the LM Studio GUI, *Settings → Auto-evict* (JIT +
idle TTL) keeps only one resident.

Ollama is also kept lazy: Phase 00 sets `OLLAMA_KEEP_ALIVE=30m` so the default
model stays warm for 30 min of inactivity, then unloads, and Phase 01 only eager-pulls `nemotron-3-nano:4b`
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
union of the legacy names `{local, local-heavy, local}` **plus every model
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
     my_agent: local
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

**Deliberate exception to per-agent `models.yml` selection.** All of Honcho's LLM
roles (deriver, dialectic, summary, dream) use a single stack-wide model for *all*
memory work (independent of each agent's chat-model assignment), since persona
extraction wants one consistent model. Per platform policy they default to
`claude-opus-sub-xhigh` (Claude subscription via Meridian; LiteLLM falls back
to `local` only if Meridian is down), and are **overridable via the
`HONCHO_MODEL` env var** in the stack `.env`. The memory plane does **not** go
through `models.yml` per-agent availability-gating.

> **Default source.** `installer/phases/03_honcho.sh` writes `HONCHO_MODEL`
> (default `claude-opus-sub-xhigh`) into `honcho/.env` as the per-role
> `*_MODEL_CONFIG__MODEL` keys. Honcho v3 reads those + `LLM_OPENAI_BASE_URL` (the
> older `LLM_OPENAI_MODEL`/`LLM_OPENAI_API_BASE` names are silently ignored). To
> pin a different model, set `HONCHO_MODEL=<slug>` in `.env`, then recreate so the
> env reloads: `docker compose up -d --force-recreate api deriver` from `honcho/`.
>
> *(Was previously pinned to the retired `local-heavy` → `ollama_chat/qwen3.6:27b-q4_K_M`,
> which is not pre-pulled, so every derivation hit the `local-heavy: ["local"]`
> fallback. Now points directly at the served default — no wasted retry.)*
