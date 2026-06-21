# Onboarding — you've installed the stack, now use it

This is the shortest path from "`install all` finished" to "I'm actually talking to
the agents and reading their traces." It assumes the stack is installed and the
doctor is green. For first-time install see [INSTALL.md](INSTALL.md); for the deep
service-by-service tour see [STACK-GUIDE.md](STACK-GUIDE.md); for recipes see
[USER-GUIDE.md](USER-GUIDE.md).

**Haven't installed yet?** The canonical first-run order is:

```bash
bash vz-ai-stack.sh deps              # bootstrap host deps (brew, yq/jq/node, OrbStack, Ollama); --check = read-only
bash vz-ai-stack.sh setup             # (optional) enter API keys — all skippable; local + Claude-sub need none
sudo bash vz-ai-stack.sh prepare-sudo # one-time /etc/hosts + DNS flush (the only sudo step)
bash vz-ai-stack.sh install all       # the 29 core phases (offers `setup` on first run if you skipped it)
bash vz-ai-stack.sh doctor            # 52 checks — target all green
```

A plain `install all` runs `deps` for you and offers `setup` on a first run, so on a
clean Mac `prepare-sudo` then `install all` is enough; the steps above are the explicit
form. Preview without changing anything: `install all --dry-run` (alias `--plan`).

---

## 1. The `stack` command (everything goes through it)

`bin/stack` is a thin wrapper around `vz-ai-stack.sh`. Put `bin/` on your PATH once:

```bash
echo 'export PATH="$HOME/ai-stack/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

Then the four you'll use daily:

```bash
stack status        # declared vs actual — what's enabled, what's running, what drifted
stack doctor        # 47 health checks + per-check auto-fix offers (your first move when something's off)
stack phases        # list every phase as  id → name
stack logs <svc>    # docker logs wrapper, e.g.  stack logs litellm -f
stack model list    # which LLM each agent is bound to (models.yml) — assign/sync/superset too
```

`stack doctor <filter>` runs only matching checks — e.g. `stack doctor phoenix`,
`stack doctor network`, `stack doctor openshell`.

### Installing / re-running one phase — by name OR number

Phase files are `<id>_<name>.sh`, so the **name is the filename suffix** and either
form works:

```bash
stack install phoenix        # == stack install 01h
stack install telegram       # alias → hermes_telegram (Phase 20)
stack install lmstudio       # opt-in Phase 25
stack test inference         # alias → smoke test for phase 01 (litellm)
```

Friendly aliases: `litellm`→inference, `telegram`→hermes_telegram,
`hermes`→hermes_fleet, `sandbox`→openshell, `unsloth`→unsloth_studio,
`halo`→halo_autoreason, `ui`→uis, `docs`→documents, `memory`→alt_memory. Run
`stack phases` if you're not sure of a name. `install all` runs the 29 core phases
(the 8 opt-in extras are excluded — see §5).

---

## 2. Reaching services by name (alias)

Every service is reached by **name**, the same URL form on your Mac and from inside a
container — no `127.0.0.1:port`. `/etc/hosts` pins each alias to a `127.0.10.x`
loopback IP; Docker's embedded DNS resolves bare names inside the `ai-stack` network.

```bash
open http://openwebui:8080         # chat UI in front of LiteLLM
open http://phoenix:6006           # trace dashboard (click the 'ai-stack' project)
open http://claw3d:4310            # 3D agent office (also http://localhost:4310)
curl -sf http://litellm:4000/health
curl -sf http://qdrant:6333/collections
redis-cli -h falkordb -p 6379 PING
```

The full alias → IP → port table is `installer/lib/aliases.tsv` (and
[PORTS.md](PORTS.md)). If a `http://<alias>:<port>` curl hangs or refuses, run
`stack verify` — it pinpoints which layer broke (lo0 / `/etc/hosts` / DNS /
host-gateway / routing). See [TROUBLESHOOTING.md § Connection refused](TROUBLESHOOTING.md).

> Two intentional exceptions: the **claw3d bridge** (`:7780`) is `127.0.0.1`-only by
> design (auth-less, drives all 9 agents), and **LM Studio** (`:1234`) is reached from
> the LiteLLM container via host-gateway — neither gets a lo0 alias.

---

## 3. The agents you can talk to

All agents call local models through LiteLLM. Which model each agent uses is
**declared per-agent** in `installer/models.yml` and rendered by `vz-ai-stack.sh model
sync` (see [models.md](models.md)). Unassigned agents now render the primary `claude-opus-4.8-sub-max`, gated to
`local-gemma4` (gemma4:e4b — the always-on Ollama fallback) when Meridian is down; the coder profiles + Pi use `local-qwen3-coder`
and the reasoning-heavy profiles + DeerFlow use `local-qwen3.6` (both LM Studio MLX,
opt-in). lmstudio-assigned agents fall back to `local-gemma4` automatically when LM
Studio is down, so a plain `install all` works with no LM Studio.

| Agent | How to reach it | What it is |
|---|---|---|
| **claw3d office** | `http://claw3d:4310` | A 3D "office" where you click + chat with the stack's agents — the Hermes fleet, **Pi**, and **DeerFlow** — routed authentically through the stack-agents bridge. The friendliest front door. (The bridge's agent registry serves the 9-role fleet plus Pi and DeerFlow.) |
| **Telegram bot** | DM `@vz_hermes_controller_bot` | The Hermes fleet from your phone. Secure-by-default: **set an allowlist or it denies everyone** — `HERMES_TELEGRAM_ALLOWED_USERS=<your-id>` in `.env`, then `stack install 20`. (Get your id from `@userinfobot`.) |
| **Hermes fleet** | `openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_manager -m local …` | A 9-role sandboxed engineering team (manager, techlead, frontend_engineer, backend_engineer, ml_engineer, qa_test_engineer, reviewing_engineer, sre_engineer, incident_manager) running a spec→deploy pipeline under the shared team-protocol. Same team also runs as Pi personas + Claude Code agents (the manager is the main session; the other 8 are subagents it dispatches). |
| **Pi** | `bin/pi` | Earendil terminal coding agent, sandboxed; scoped virtual key, local-only. |
| **DeerFlow** | `http://localhost:2026` | Multi-step LangGraph research agent. |
| **Open WebUI** | `http://openwebui:8080` | Plain chat UI straight to LiteLLM (no agent framework). |

Talk to LiteLLM directly to test the plumbing:

```bash
KEY="$(grep ^LITELLM_MASTER_KEY= ~/ai-stack/.env | cut -d= -f2-)"
curl -s http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"local-gemma4","messages":[{"role":"user","content":"hello"}]}' \
  | jq -r '.choices[0].message.content'
```

Every call lands as a trace in Phoenix's **ai-stack** project (not `default`).

---

## 4. Where logs and state live

```
installer/state/          # stamp files (phase_<NN>.done), restart queue, lock dir, watchdog log
installer/state/openshell-watchdog.log   # what the CPU-storm watchdog did + when
traces/litellm.jsonl      # one line per chat call (ts, model, messages, latency, cost)
CHANGELOG.d/<run-id>.md    # per-run logs  →  assemble with `stack history`
data/                     # {phoenix,falkor,qdrant,honcho,openwebui} persistent volumes
ingestor/{inbox,processed}# drop docs in inbox/ to ingest into the RAG
```

Read live traces from inside the container (OrbStack bind-mount snapshots the host
view at start): `docker exec litellm tail -f /traces/litellm.jsonl`.

---

## 5. Opt-in extras (Phases 21–25, 27–29) — add only what you want

These are **not** in `install all`. Add by name; each one's doctor check (34–38, 49)
passes-as-skip until you install it. (MemPalace, Phase 26, is no longer here — it's a
core phase installed by `install all`, appended last; see OPERATIONS.md § MemPalace.)

```bash
stack install portless       # 21 — agent-aware dev proxy: stable name.localhost URLs
stack install cmux           # 22 — native macOS terminal for parallel agent sessions
stack install skillspector   # 23 — scan an agent skill/MCP before trusting it (offline)
stack install openagents     # 24 — OpenAgents Launcher (agn); overlaps the stack, edits shell rc
stack install lmstudio       # 25 — LM Studio MLX runtime behind LiteLLM (CPU caveat → §6)
stack install sourcegraph    # 27 — self-hosted code search + native MCP
stack install aionui         # 28 — AionUi desktop + WebUI Cowork workspace (multi-agent GUI)
stack install openwork       # 29 — OpenWork headless OpenCode-powered Cowork workspace (browser UI)

bin/skillspector scan <path>   # after installing skillspector: offline security scan
```

---

## 6. CPU guards (this box is 24 GB — keep it cool)

Three things keep the stack from cooking a 24 GB M-series machine:

1. **OpenShell CPU-storm watchdog (warn-only by default).** After ~8 h a sandbox's gateway token
   expires and the agent reconnect-storms at ~36% CPU. **Only recreating the sandbox
   mints a fresh token — a gateway restart does not.** Phase 04 installs a launchd
   watchdog (`bin/openshell-watchdog.sh`, every 600 s) that detects this, **halts the
   container to stop the CPU burn, and raises an alert** (surfaced by `doctor` check 43)
   — it does **not** delete/recreate the sandbox by default, since recreation discards
   in-sandbox state. You recreate when ready; opt into auto-recreate with
   `AI_STACK_WATCHDOG_RECREATE=1`.
   ```bash
   bash bin/openshell-watchdog.sh status      # is it loaded? last run / exit
   bash bin/openshell-watchdog.sh run         # run one detect cycle now (recreate only if RECREATE=1)
   bash bin/openshell-watchdog.sh uninstall   # remove the launchd timer
   ```
   The on-demand twin is `stack doctor openshell` (check 39); a pending alert shows in check 43.

2. **Cap OrbStack.** On a ~34-container stack OrbStack's VM helper is a CPU floor.
   **OrbStack → Settings → Resources → ~6–8 cores / 12–14 GB.** (Corporate EDR/MDM
   agents are a separate CPU draw, out of scope.)

3. **Quit LM Studio when done.** If you installed Phase 25, the LM Studio *app*
   idle-spins ~0.8–1 core even with no model loaded and the server stopped. Run it
   only when you want MLX tool-calling, then `~/.lmstudio/bin/lms server stop` and
   Cmd-Q the app. Headless alternative: `mlx_lm.server` (pip `mlx-lm`).

Full write-ups: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Where to go next

- **A recipe to follow** → [USER-GUIDE.md](USER-GUIDE.md) (RAG, memory-aware coding,
  sandboxed Pi, Phoenix evals).
- **What each tool is** → [COMPONENTS.md](COMPONENTS.md) (index) / [STACK-GUIDE.md](STACK-GUIDE.md) (tour).
- **Day-to-day commands** → [OPERATIONS.md](OPERATIONS.md).
- **Which model each agent uses** → [models.md](models.md) (`vz-ai-stack.sh model` binding).
- **Something's broken** → [DOCTOR.md](DOCTOR.md) then [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
