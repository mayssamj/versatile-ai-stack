# Run Claude Code on any model from your LiteLLM (kimi, gpt, glm, …)

`bin/claude-litellm` launches the **Claude Code CLI** routed through this stack's
**LiteLLM** proxy, so the agent runs on any model LiteLLM serves — kimi, GLM, GPT,
DeepSeek, your GPT-5 ChatGPT-sub, Fugu, or (opt-in) a local model — instead of the
default Anthropic cloud models. Every call gets LiteLLM's virtual-key auth, budget cap,
and Phoenix tracing.

## How it works

Claude Code speaks the **Anthropic Messages API** (`POST /v1/messages`). LiteLLM exposes
an Anthropic-compatible `/v1/messages` that translates each request to the backend a
model maps to. The launcher sets a few env vars and execs `claude`:

| Env var | Set to | Purpose |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:4000` | point Claude Code at LiteLLM |
| `ANTHROPIC_AUTH_TOKEN` | scoped LiteLLM key | `Authorization: Bearer` (proxy auth) |
| `ANTHROPIC_MODEL` | a served model name | the main model |
| `ANTHROPIC_SMALL_FAST_MODEL` / `ANTHROPIC_DEFAULT_HAIKU_MODEL` | = main model | background tasks (no 2nd model) |

It `unset`s `ANTHROPIC_API_KEY` (so only the proxy path is used) and **exports** the key
into `claude`'s environment rather than passing it on the command line, so it never
appears in `claude`'s `ps` entry. (The `--check`/`--list` self-tests pass the key to
`curl` via a header arg, briefly visible in `ps` for that call — same as the stack's
other scoped-key curls.)

## ⚠ RAM safety — local models are opt-in

This is a memory-constrained (24GB) box. Every `local-*` model loads **multi-GB weights**
into RAM via Ollama / LM Studio; loading several at once **exhausts memory** (it has
crashed OrbStack here). So the launcher:

- **never picks a model by default** — you name one, nothing loads by surprise;
- **refuses `local-*` models** unless you opt in with `CLAUDE_LITELLM_ALLOW_LOCAL=1`;
- defaults the **background/fast model to your main model**, so it never spins up a second model.

Prefer **cloud** models (they load nothing locally). If you do run a local one, run **one
at a time** and unload others first (`ollama ps` / `ollama stop <m>`; LM Studio in its UI).

## What works inside Claude Code — full matrix

Verified live via `/v1/messages` (✅ = HTTP 200 round-trip; *inferred* = same provider
class as a verified sibling, not re-tested — local ones deliberately not load-tested to
protect RAM):

| Model | Runtime | Status |
|---|---|---|
| `openrouter-kimi`, `-kimi-code` | OpenRouter (metered) | ✅ kimi tested; -code inferred · reasoning model |
| `openrouter-glm`, `-glm-vision` | OpenRouter (metered) | ✅ glm tested; vision inferred · reasoning model |
| `openrouter-gpt`, `-gpt-pro` | OpenRouter (metered) | ✅ gpt tested; pro inferred |
| `openrouter-deepseek`, `-deepseek-flash` | OpenRouter (metered) | ✅ deepseek tested; flash inferred |
| `openrouter-claude-opus`, `-fast` | OpenRouter (metered) | ✅ opus tested; fast inferred · real Claude Opus 4.8 |
| `openai-gpt`, `-gpt-pro` | OpenAI (metered key) | ✅ gpt tested; pro inferred |
| `openai-gpt-sub`, `-gpt-pro-sub` | codex-bridge (ChatGPT sub) | ✅ sub tested; pro-sub inferred · GPT-5 on your subscription |
| `sakana-fugu`, `-ultra` | Sakana (metered) | ✅ fugu tested; ultra inferred |
| `local`, `local-heavy`, `local-nemotron3-nano-4b` | **Ollama** (local) | ✅ `nemotron-3-nano:4b` — all three aliases map to the same (only) local chat model |
| `local-nemotron3-nano-4b-mlx` | **LM Studio** (local, opt-in) | ✅ same nemotron model on Apple MLX (Phase 25) |
| `claude-opus-sub-*`, `claude-sonnet-sub-*` | Meridian (Claude sub) | ❌ 404 — LiteLLM bridges to `/v1/responses`, Meridian only does `/chat/completions` |
| `google-gemini-flash`, `-pro` | Gemini | ❌ 500 — needs `GEMINI_API_KEY`/`GOOGLE_API_KEY` in the stack |
| `embed-*` | embeddings | n/a — not chat models |

> **Why both local backends work but Claude-sub doesn't:** LM Studio (and codex-bridge)
> implement the OpenAI **Responses API** (`/v1/responses`), which LiteLLM's Anthropic
> bridge targets; Meridian doesn't. It's about the backend's API, not "local vs cloud".
>
> **Reasoning models** (kimi/glm/deepseek/gpt-sub) return a `thinking` block then the
> answer `text` block — Claude Code renders both natively.

`claude-litellm --list` prints the live menu; `claude-litellm --check <model>` round-trips one.

## Usage

```bash
claude-litellm openrouter-kimi              # Kimi inside Claude Code
claude-litellm openrouter-glm               # GLM
claude-litellm openai-gpt-sub               # GPT-5 on your ChatGPT subscription
claude-litellm openrouter-claude-opus       # real Claude Opus 4.8 via OpenRouter (metered)
claude-litellm sakana-fugu                  # Sakana Fugu
claude-litellm                              # no default → prints the model menu
claude-litellm --check openrouter-kimi      # self-test one model, don't launch
claude-litellm --list                       # everything you can use
claude-litellm openrouter-gpt -- --resume   # args after `--` pass through to claude

# Local models are opt-in (load into RAM — run one at a time):
CLAUDE_LITELLM_ALLOW_LOCAL=1 claude-litellm local
```

Env overrides: `CLAUDE_LITELLM_MODEL`, `CLAUDE_LITELLM_FAST_MODEL`,
`CLAUDE_LITELLM_ALLOW_LOCAL=1`, `LITELLM_BASE_URL`, `AI_STACK_ENV`.

> **Cost.** Cloud models are **metered**. The background/fast model defaults to your main
> model (no second model). The scoped key is budget-capped (below).

## The scoped key

The launcher reads `CLAUDE_CODE_LITELLM_KEY` from `.env` — a LiteLLM virtual key (alias
`claude-code-launcher`) granted **all served models**, with a `$20/30d` budget cap (only
metered models spend; local is free). Raise the cap or re-scope anytime.

Re-sync the key to whatever models are currently served (after a `model sync`/rename):
```bash
M=$(grep ^LITELLM_MASTER_KEY= ~/ai-stack/.env | cut -d= -f2-)
K=$(grep ^CLAUDE_CODE_LITELLM_KEY= ~/ai-stack/.env | cut -d= -f2-)
MODELS=$(curl -s -H "Authorization: Bearer $M" http://127.0.0.1:4000/v1/models | jq -c '[.data[].id]')
curl -s -H "Authorization: Bearer $M" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:4000/key/update \
  -d "$(jq -nc --argjson m "$MODELS" --arg k "$K" '{key:$k,models:$m}')" | jq -c '{models:(.models|length)}'
```

Raise the budget / first-time mint / revoke:
```bash
curl ... -X POST http://127.0.0.1:4000/key/update   -d "$(jq -nc --arg k "$K" '{key:$k,max_budget:100}')"
curl ... -X POST http://127.0.0.1:4000/key/generate -d '{"models":[],"max_budget":20,"budget_duration":"30d","key_alias":"claude-code-launcher"}'  # then put .key in .env
curl ... -X POST http://127.0.0.1:4000/key/delete   -d "{\"keys\":[\"$K\"]}"
```

> **Pinned, not auto-reconciled.** Unlike the fleet keys, this key is *not* rewritten by
> `model sync`. After a model rename you'll get a `403` / "not in the models this key can
> use" warning — run the re-sync one-liner (`--list` is the diagnostic).

## Troubleshooting

- **Everything 404/500s or `--list` says "non-JSON"** → LiteLLM's virtual-key store is
  down. That store is the **`honcho-database`** container (a Postgres, despite the name).
  Restore it from the **main** checkout: `docker start honcho-database-1 honcho-redis-1 && docker restart litellm`.
- **`claude-*-sub` 404s** → expected (Meridian lacks `/v1/responses`); use a cloud or local model.
- **`google-gemini-*` 500s** → set `GEMINI_API_KEY`/`GOOGLE_API_KEY` in the stack.
- **Don't put `ANTHROPIC_BASE_URL` in `~/.claude/settings.json` globally** — that reroutes
  *every* Claude Code session (including your normal cloud one). This launcher is per-invocation.

## Rollback

Remove `bin/claude-litellm`, revoke the key (above), and delete the
`CLAUDE_CODE_LITELLM_KEY` line from `.env`. Nothing else in the stack depends on it.
