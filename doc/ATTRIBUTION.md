# Attribution, sources & licenses

Upstream source link, license, and Terms-of-Service / usage notes for **every
third-party tech piece** in this stack — software *and* model weights. For what
each piece does see [COMPONENTS.md](COMPONENTS.md); for why-this-not-that see
[ALTERNATIVES.md](ALTERNATIVES.md).

> ⚠️ **Not legal advice.** Licenses change and some entries below are version-specific
> (especially model weights). Verify against the actual `LICENSE` file / model card /
> ToS page before relying on any of this for compliance. Researched 2026-05-31.

---

## ⚠️ Licenses that need attention (not plain permissive OSS)

Most of the stack is MIT / Apache-2.0. These are the exceptions — they carry
commercial, copyleft, source-available, or undeclared terms that matter if this is
**business/commercial use** (e.g. on a work machine):

| Piece | License | Why it matters |
|---|---|---|
| **OrbStack** (container runtime) | Proprietary, freemium | Free tier is **personal / non-commercial only**. Business use **requires a paid license** (Pro ~$8/user/mo, or Enterprise). |
| **LiquidAI LFM2** (`local-lfm2` model — **deprecated**, no longer auto-pulled; manual `ollama pull` only) | LFM Open License v1.0 | Free commercial use **only if org revenue < $10M USD**; at/above that you must negotiate a commercial agreement with Liquid AI. |
| **Arize Phoenix** (tracing) | Elastic-2.0 | Source-available, **not OSI**. Can't offer it to third parties as a hosted/managed service; can't circumvent license keys. Self-host/internal use OK. |
| **FalkorDB** (graph DB) | SSPL-1.0 | MongoDB's Server Side Public License. Offering it *as a service* triggers full-stack source-disclosure (or buy a commercial license). Internal use OK. |
| **byterover** (`brv` memory CLI) | Elastic-2.0 | Same ELv2 restrictions as Phoenix. Local/internal use OK. |
| **Honcho** (memory) | AGPL-3.0 | Network copyleft — deploying as a service can trigger source-disclosure for the combined work. (Plastic Labs' managed service has separate commercial terms.) |
| **Unsloth** (fine-tuning) | Apache-2.0 core **+ AGPL-3.0 Studio UI** | The **Studio UI** component is AGPL-3.0 (network copyleft); the core library is Apache-2.0. |
| **Open WebUI** | Custom (BSD-3 + branding clause) | Can't alter/remove "Open WebUI" branding above **50 users / 30 days** without an enterprise license. |
| **autoreason** (Nous, reference clone) | **None declared** | No `LICENSE` file ⇒ default copyright (**all rights reserved**). Reference only — do not redistribute or derive. |
| **LiteLLM** | MIT **+ commercial `enterprise/`** | The MIT core is fine; code under `enterprise/` needs a paid LiteLLM enterprise license. |
| **Google Gemma 1–3** (model) | Gemma Terms of Use | Custom terms: prohibited-use policy + must flow restrictions downstream. **Gemma 4+ switched to Apache-2.0** — verify the exact model card. |
| **Telegram Bot API** | Telegram Bot Developer Terms | Running `@vz_hermes_controller_bot` binds you to Telegram's Bot Developer Terms + general ToS. |
| **Blaxel** (cloud, keys-only) | Proprietary SaaS | Hosted only; governed by Blaxel's Standard Terms + AUP + Privacy Policy. Usage-based paid. |

Everything else is permissive (MIT / Apache-2.0 / ISC / BSL-1.0) — see the full tables below.

---

## Inference & gateway
| Component | Upstream | License | Notes |
|---|---|---|---|
| **Ollama** | https://github.com/ollama/ollama | MIT | Server is MIT; **model weights it pulls carry their own licenses** (see *Model weights* below). |
| **LiteLLM** | https://github.com/BerriAI/litellm | MIT (+ commercial `enterprise/`) | Core proxy MIT; enterprise dir + BerriAI cloud are separate commercial terms. Home: https://litellm.ai |

## Observability & security
| Component | Upstream | License | Notes |
|---|---|---|---|
| **Arize Phoenix** | https://github.com/Arize-ai/phoenix | **Elastic-2.0** | Source-available (not OSI). Self-host OK; no hosted-service resale; no license-key circumvention. Hosted Arize AX has separate ToS. |
| **LLM Guard** | https://github.com/protectai/llm-guard | MIT | Protect AI (was `laiyer-ai`). MIT code; bundled HuggingFace scanner models carry their own licenses. |

## Memory & storage
| Component | Upstream | License | Notes |
|---|---|---|---|
| **Honcho** | https://github.com/plastic-labs/honcho | **AGPL-3.0** | Network copyleft. Managed service (honcho.dev) has separate cloud ToS. |
| **Qdrant** | https://github.com/qdrant/qdrant | Apache-2.0 | Engine permissive. Qdrant Cloud has its own Service Agreement + DPA. |
| **FalkorDB** | https://github.com/FalkorDB/FalkorDB | **SSPL-1.0** | MongoDB SSPL — service-resale triggers full-stack disclosure. Managed FalkorDB Cloud separate. |

## Agent runtimes & frameworks
| Component | Upstream | License | Notes |
|---|---|---|---|
| **OpenShell** | https://github.com/NVIDIA/OpenShell | Apache-2.0 | NVIDIA. Runtime is pure OSS; optional NemoClaw managed-inference is separate NVIDIA terms. |
| **Hermes Agent** | https://github.com/NousResearch/hermes-agent | MIT | Nous Research. PyPI `hermes-agent`. (Hosted Nous Portal/API is separate terms.) |
| **Pi (Earendil)** | https://github.com/earendil-works/pi | MIT | Packages under `@earendil-works/*` (e.g. `pi-coding-agent`). |
| **AutoFyn** | https://github.com/SignalPilot-Labs/AutoFyn | Apache-2.0 | Framework Apache-2.0; it drives Anthropic Claude, whose API terms apply at runtime. |
| **DeerFlow** | https://github.com/bytedance/deer-flow | MIT | ByteDance. |

## User interfaces
| Component | Upstream | License | Notes |
|---|---|---|---|
| **Open WebUI** | https://github.com/open-webui/open-webui | **Custom (BSD-3 + branding)** | Branding-removal restricted above 50 users/30d without enterprise license. |
| **Hermes Workspace** | https://github.com/outsourc-e/hermes-workspace | MIT | ⚠️ **Community project (outsourc-e), NOT Nous Research.** Built on top of `NousResearch/hermes-agent` (MIT). |
| **claw3d** | https://github.com/iamlukethedev/claw3d | MIT | Community; explicitly **not** affiliated with the OpenClaw team. |
| **Telegram Bot API** | https://core.telegram.org/bots/api | **Bot Developer Terms** | Hosted platform: https://telegram.org/tos/bot-developers + https://telegram.org/tos . Self-hostable server (`tdlib/telegram-bot-api`) is BSL-1.0 but does **not** exempt you from the platform terms. |

## Documents & RAG
| Component | Upstream | License | Notes |
|---|---|---|---|
| **Docling** | https://github.com/docling-project/docling | MIT | IBM-originated, now LF AI & Data. Code MIT; pulled OCR/layout models carry own licenses. |
| **LlamaIndex** | https://github.com/run-llama/llama_index | MIT | Core MIT; LlamaCloud / LlamaParse are separate commercial SaaS. |

## CLI tools · batch · experimental
| Component | Upstream | License | Notes |
|---|---|---|---|
| **ACE** | https://github.com/ace-agent/ace | Apache-2.0 | Agentic Context Engineering. Paper arXiv:2510.04618. |
| **RLM** | https://github.com/alexzhang13/rlm | MIT | Recursive Language Models. ⚠️ default mode runs model-generated code locally — we sandbox it in Docker. |
| **HALO** | https://github.com/context-labs/HALO | MIT | PyPI `halo-engine` (Context Labs / inference.net). Hosted option separate terms. |
| **Lumen** | https://github.com/ory/lumen | Apache-2.0 | Ory. Fully local; embedding model weights carry own licenses. |
| **Unsloth** | https://github.com/unslothai/unsloth | Apache-2.0 core **+ AGPL-3.0 Studio** | Studio UI is AGPL-3.0. Fine-tuned models keep base-model licenses. |
| **Paperclip** | https://github.com/paperclipai/paperclip | MIT | Agent management/orchestration platform. Home: https://paperclip.ing |
| **Blaxel CLI** | https://blaxel.ai/ | **Proprietary SaaS** | Cloud-only. Terms: https://blaxel.ai/terms , AUP, Privacy. |
| **byterover (`brv`)** | https://github.com/campfirein/byterover-cli | **Elastic-2.0** | Formerly "Cipher". Local mode offline/no-account; cloud sync separate terms. |
| **remnic-hermes** | https://github.com/joshuaswarren/remnic | MIT | Remnic MemoryProvider plugin for Hermes Agent. PyPI `remnic-hermes`. |
| **autoreason** | https://github.com/NousResearch/autoreason | **None (all rights reserved)** | NousResearch; no LICENSE file. Reference only — do not redistribute. |

## Opt-in experimental extras (Phases 21–25 · 27)
| Component | Upstream | License | Notes |
|---|---|---|---|
| **portless** | https://github.com/vercel-labs/portless | Apache-2.0 | Vercel Labs. Global npm CLI; ships a Claude Code skill. |
| **cmux** | https://github.com/manaflow-ai/cmux | **GPL-3.0** (commercial license available) | Manaflow (YC). brew cask `manaflow-ai/cmux`. The only copyleft tool in the stack — fine to *use*; matters only if you redistribute a derivative. |
| **NVIDIA SkillSpector** | https://github.com/NVIDIA/skillspector | Apache-2.0 | NVIDIA. Offline static mode needs no network; optional LLM stage can point at LiteLLM. |
| **OpenAgents Launcher** | https://github.com/openagents-org/openagents | Apache-2.0 | Hosted Workspace (workspace.openagents.org) carries its own terms; the local launcher/`agn` is Apache-2.0. Installer fetches from a moving branch (no checksum) + edits your shell rc. |
| **LM Studio** | https://lmstudio.ai/ | **Proprietary, free for personal + commercial** (since 2025-07; no license needed) | App is closed-source; the `lms` CLI is MIT and Apple's **MLX** framework is MIT. Enterprise/Teams tier is paid; the desktop app + headless server are free for work use. Serves `local-lfm2-mlx` (LFM2.5 weights = LFM Open License, $10M cap — see Model weights). ⚠️ Opt-in (Phase 25): the desktop app idle-spins ~0.8–1 core even stopped — quit it when done (`lms server stop` + Cmd-Q); headless alternative is `mlx_lm.server` (pip `mlx-lm`). |
| **MemPalace** | https://github.com/MemPalace/mempalace | MIT | PyPI `mempalace`. Local-first **verbatim** conversation memory for Claude Code sessions — CLI + MCP server (29 tools) + Python lib; a spatial model (wings/rooms/drawers) over a temporal SQLite knowledge graph. Embeddings are **local ONNX on-device** (CoreML; default `all-MiniLM-L6-v2`, `embeddinggemma` opt-in) — no cloud; an optional refiner LLM routes via LiteLLM (`MEMPALACE_LITELLM_KEY`). Storage is local ChromaDB (a Qdrant backend adapter is staged at `mempalace/backend-qdrant/` per RFC-001, conformance-tested vs live Qdrant, but **not yet live** — 3.3.5 hardcodes ChromaBackend). Two upstream hook scripts (`mempal_save_hook.sh`, `mempal_precompact_hook.sh`) are **vendored verbatim** under `mempalace/hooks/` (see `mempalace/VENDORED.md`). Core phase — installed by `install all` (Phase 26). **Security:** install only from PyPI / GitHub — the domain `mempalace.tech` is a known malware squat. |

## Platform & protocols
| Component | Upstream | License | Notes |
|---|---|---|---|
| **OrbStack** | https://orbstack.dev/ | **Proprietary, freemium** | Free personal/non-commercial only; **business use needs a paid license**. Terms: https://orbstack.dev/terms |
| **Model Context Protocol** | https://github.com/modelcontextprotocol/modelcontextprotocol | Apache-2.0 | Anthropic open standard. Older contributions MIT; non-spec docs CC-BY-4.0. Home: https://modelcontextprotocol.io |

## Model weights (via Ollama / LiteLLM)
The model *server* is MIT, but **weights carry their own licenses** — these are the
ones most likely to have commercial conditions. Always confirm the exact model card.

| Model (stack alias) | Source | License | Notes |
|---|---|---|---|
| **Gemma** (`local` = `gemma4:e4b`) | https://ai.google.dev/gemma | Gemma Terms (1–3); **Apache-2.0 for Gemma 4+** | Gemma 1–3: prohibited-use policy + downstream flow-through. Terms: https://ai.google.dev/gemma/terms |
| **Qwen** (`local-qwen3.6` = `qwen/qwen3.6-27b`, LM Studio MLX, opt-in; the old Ollama `local-heavy` = `qwen3.6:27b` is removed) | https://github.com/QwenLM/Qwen3 | Apache-2.0 (varies by model) | Qwen3 mostly Apache-2.0; some older/larger Qwen models use a custom license with an MAU threshold. Check the card. |
| **LiquidAI LFM2** (`local-lfm2` — **deprecated**, manual `ollama pull` only) | https://www.liquid.ai/lfm-license | **LFM Open License v1.0** | Apache-2.0-based **with a $10M org-revenue commercial cap**. |
| **nomic-embed-text** | https://huggingface.co/nomic-ai/nomic-embed-text-v1.5 | Apache-2.0 | Embeddings. |
| **jina-embeddings-v2-base-code** | https://huggingface.co/jinaai/jina-embeddings-v2-base-code | Apache-2.0 | Code embeddings. |

---

*Generated from a parallel license/ToS research sweep (2026-05-31). Re-verify before
any compliance-sensitive decision; model-weight licenses in particular are version-specific.*
