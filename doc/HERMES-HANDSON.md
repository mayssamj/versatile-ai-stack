# Hermes Fleet — Hands-On Companion

The full hands-on companion to [Act IV of the tutorial](TUTORIAL.md) — how to
actually run the **9-role Hermes fleet** day to day. Act IV teaches *why* the
team exists and walks you through it as a story; this page is the *operator's
manual* — every surface, every lever, with copy-run commands and the output you
should see. It's a standalone deep-dive (like the
[Service Playground appendix](SERVICE-PLAYGROUND.md)), so read it top to bottom
or jump to the section you need.

The fleet lives in the **`hermes-fleet-v1` OpenShell sandbox** (Phase 04·F),
and you reach it four ways:

| Surface | What it is | Best for |
|---|---|---|
| **Hermes Workspace** | a web command center (Dashboard / Chat / Conductor / Memory / Sessions / Profiles) | seeing the whole fleet at a glance, point-and-click chat & dispatch |
| **`hermes` CLI** | the real agent CLI, run *inside* the sandbox | scripting, one-shots, the interactive TUI, model config |
| **claw3d bridge** | one OpenAI-shaped HTTP endpoint fronting every role | `curl`-ing any agent, backing the 3D office |
| **chat apps** | Telegram (pre-wired) and Slack (self-setup) | reaching the fleet from your phone or your team channel |

> **Conventions.** 🟢 basic · 🟡 intermediate · 🔴 advanced. Commands are
> **copy-run** — paste them, compare against **Expected**. Services are reached
> by **name** (`http://workspace:3000`), which needs the one-time
> `sudo bash vz-ai-stack.sh prepare-sudo` step (tutorial L2); the loopback
> `127.0.x.x` fallback is noted where a bare hostname won't resolve yet.
> `vz-ai-stack.sh` is the CLI entrypoint (`bin/stack` takes the same arguments).

---

## 1) The Hermes Workspace (web command center) · 🟡

**Why.** The Workspace is the single pane of glass over the fleet — you see
every profile, dispatch missions, and browse memory without ever touching a
terminal. It's the friendliest entry point and the one to open first.

**What's running.** Phase 05 brings up **two** containers:

- **`hermes-agent`** — the gateway on **`:8642`** (the long-running API/health
  server) plus the dashboard on **`:9119`** (an internal status API on the
  private Docker network).
- **`hermes-workspace`** — the **UI on `:3000`** that talks to the agent over
  the Docker network (`hermes-agent:8642` + `hermes-agent:9119`).

**Open it.** No login by default:

```bash
open http://workspace:3000        # loopback alias 127.0.10.10:3000
```

**The pages you'll use** (as listed in the service's `help` block):

- **Dashboard** — fleet activity at a glance: which profiles are loaded, recent tasks.
- **Chat** — talk to a profile in the browser.
- **Conductor** — the *mission dispatcher*: hand a goal to the fleet and watch it route.
- **Memory** — browse what the fleet knows / has stored.
- **Sessions** — past conversation sessions.
- **Profiles** — the 9 souls, each role's mandate and config.

**Health-check the gateway** (the API the UI depends on):

```bash
curl -s http://hermes-gw:8642/health | jq      # alias 127.0.10.11:8642
```

**Expected.**

```json
{ "status": "ok", "platform": "hermes-agent", "version": "…" }
```

**Confirm the containers are up:**

```bash
docker ps --filter name=hermes-workspace
```

You should see the `hermes-workspace-…` container `Up` (compose normalizes the
project name to **dashes** — the container is `hermes-workspace-…`, not
`hermes_workspace-…`).

**Lifecycle.**

```bash
bash bin/start-hermes_workspace.sh              # start / restart (idempotent: docker compose up -d)
bash bin/stop-hermes_workspace.sh               # stop
bash bin/start-hermes_workspace.sh --recreate   # hard reset: compose down && up -d (data volumes survive)
```

`--recreate` runs `docker compose down && docker compose up -d` — it does **not**
pass `-v`, so the named volumes (your sessions/memory) survive the reset.

**Lesson — the dashboard-binding gotcha (teach this).** The dashboard on `:9119`
must bind **`0.0.0.0` inside the container** so the separate workspace container
can reach it across the Docker network. ai-stack sets
`HERMES_DASHBOARD_HOST=0.0.0.0` for exactly this reason. If it binds loopback
instead, cross-container calls fail and the **Sessions sidebar crashes** with:

```
Cannot read properties of undefined (reading 'map')
```

That's why install builds a **derived, hardened workspace image** in Phase 05 —
it both pins the `0.0.0.0` binding and guards that `.map` so a transient empty
response degrades gracefully instead of white-screening the sidebar.

---

## 2) The Hermes CLI, end to end · 🟡

**Why.** The Workspace is point-and-click; the CLI is where you script, one-shot,
and configure. The catch: `hermes` lives **inside** the `hermes-fleet-v1`
sandbox — you don't run it on the host directly, you run it *through* OpenShell.

**Enter the fleet sandbox (interactive shell).** This drops you into a shell
*inside* the sandbox, where `hermes …` is on the PATH:

```bash
openshell sandbox connect hermes-fleet-v1
# inside the sandbox, now you can run:
hermes --help
```

**One command from the host (no shell).** Use `exec` to run a single `hermes`
command without opening a shell:

```bash
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_manager --yolo -z "Give me a one-line status of the fleet's operating contract."
```

Add **`--tty`** when you want an *interactive* hermes session (the TUI) instead
of a one-shot:

```bash
openshell sandbox exec -n hermes-fleet-v1 --tty -- hermes --profile hermes_manager
```

Use **`--no-tty`** for scripted, non-interactive calls (it's what the installer
uses for config probes — see §4).

**The CLI shape.**

```
hermes --profile hermes_<role> [--yolo -z '<prompt>'] [-m <model>]
```

- **`--profile hermes_<role>`** — which of the 9 souls answers.
- **`--yolo`** — bypass the dangerous-command approval prompts (it's how a
  scripted run doesn't stall waiting for a y/n).
- **`-z '<prompt>'`** (alias `--oneshot`) — a **one-shot** run: send a single
  prompt, print only the final response to stdout, exit. Intended for scripts /
  pipes. **Omit `-z`** (and add `--tty` via `exec`) to get the **interactive
  TUI** instead — the TUI needs a tty.
- **`-m <model>`** (alias `--model`) — override the role's bound model for this
  invocation.

**The 9 role profiles** (note the **underscores**):

```
hermes_manager              hermes_techlead             hermes_frontend_engineer
hermes_backend_engineer     hermes_ml_engineer          hermes_qa_test_engineer
hermes_reviewing_engineer   hermes_sre_engineer         hermes_incident_manager
```

**Discover the subcommands** — the authoritative list is the CLI's own help:

```bash
openshell sandbox exec -n hermes-fleet-v1 -- hermes --help
```

The subcommands you'll reach for:

| Subcommand | What it does |
|---|---|
| `hermes gateway` | the messaging gateway (Telegram/Slack/…) — see §5 |
| `hermes slack` / `hermes send` | chat-app messaging — see §5 |
| `hermes sessions` | list / inspect conversation sessions |
| `hermes kanban` | a multi-profile work board |
| `hermes model` | the **in-agent** model picker (this is *not* the installer's `vz-ai-stack.sh model` — see §4) |
| `hermes status` | the agent's own status |
| `hermes doctor` | the agent's self-diagnostics |
| `hermes config` | read/check/set agent config (e.g. `config check` — see §4) |

**See the roster from the host** (no sandbox round-trip):

```bash
vz-ai-stack.sh fleet list           # add --json for machine-readable
```

**Expected.** A table of the 9 roles with each one's bound model — manager,
techlead, the four engineers, qa, reviewing, sre, incident-manager.

**Gotchas (teach these).**

- **Relay idle-timeout.** If the OpenShell relay has idle-timed-out, sandbox
  calls **fail fast** (they don't hang) — recover with:
  ```bash
  brew services restart openshell
  ```
- **A `-z` prompt that starts with `-`** is parsed as a flag. Quote it and lead
  with a space (or reword), e.g. `-z ' -v means verbose, explain it'`, not
  `-z '-v means…'`.
- **`Phase=Ready` ≠ relay-live** — a sandbox can be `Ready` while its relay
  isn't actually serving. If in doubt, `openshell sandbox list` and re-run a
  trivial `exec`.

---

## 3) Driving each of the 9 roles · 🟡

Each role stays **in lane** — that's the whole point of the team-protocol. Below
is one realistic one-shot per role. All use the same shape; run them either from
the host via `openshell sandbox exec -n hermes-fleet-v1 -- hermes …` or, after
`openshell sandbox connect hermes-fleet-v1`, just `hermes …` inside the sandbox.

```bash
# manager — frame + route a small feature (it emits a SPEC with AC-n, then routes)
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_manager --yolo \
  -z "Feature request: add a /version endpoint returning {sha, built_at}. Frame it and route it."

# techlead — an ADR comparing two approaches
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_techlead --yolo \
  -z "Write a short ADR: server-side sessions vs stateless JWT for our web app. Compare both, recommend one."

# backend_engineer — an API contract
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_backend_engineer --yolo \
  -z "Define the contract for POST /tokens (issue a JWT in an httpOnly cookie). Contract only, no implementation."

# frontend_engineer — an accessible component
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_frontend_engineer --yolo \
  -z "Sketch an accessible (WCAG 2.1 AA) password field with a show/hide toggle. Markup + the a11y reasoning."

# ml_engineer — a model-choice / eval call
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_ml_engineer --yolo \
  -z "We need to classify support tickets into 6 categories. Propose the smallest model that works and an eval plan."

# qa_test_engineer — a test plan
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_qa_test_engineer --yolo \
  -z "Write a critical-path test plan for a /healthz endpoint that returns 200 + {status, version, uptime_seconds}."

# reviewing_engineer — adversarial + security review of a diff
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_reviewing_engineer --yolo \
  -z "Adversarially review this change for correctness AND security: a login route that builds SQL with string concatenation."

# sre_engineer — a rollout + rollback plan
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_sre_engineer --yolo \
  -z "Plan a progressive rollout (and a verified rollback) for a new caching layer in front of our read API."

# incident_manager — a postmortem outline
openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_incident_manager --yolo \
  -z "Outline a blameless postmortem for a 20-minute outage caused by an expired TLS cert."
```

**Expected.** Each role answers *in character* on its bound model (all 9 route to
Claude Opus 4.8 over the subscription via Meridian — see §4). The output is the
role's typed artifact: the manager a SPEC, the techlead an ADR, the reviewer a
findings list, and so on.

**The "stays in lane" guarantee.** Ask a role to do another role's job and it
**escalates instead of overreaching** — e.g. ask the *backend engineer* to design
the whole system and it'll tell you that's the techlead's call and route it
upward. That's `team-protocol §4` working, not the model being unhelpful.

**Two other ways to reach a single role** (cross-ref tutorial L12):

- **The claw3d bridge** — one OpenAI-shaped endpoint; the `role` field picks the
  agent (full treatment in §6):
  ```bash
  curl -s http://127.0.0.1:7780/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"role":"hermes_backend_engineer","messages":[{"role":"user","content":"Sketch the POST /tokens contract. Contract only."}]}'
  ```
- **`bin/pi-as <role>`** — Pi *wearing* the persona, pinned to that role's model
  tier:
  ```bash
  bin/pi-as techlead -p "Compare server-side sessions vs stateless JWT for our web app. Recommend one."
  ```

---

## 4) Give a role a different model · 🟡

**Why.** Every role ships bound to Claude Opus 4.8 over the subscription, but you
can re-point any role at a local model (to save the cloud budget, or to test) —
or blanket-reassign the whole fleet. This is the **installer's** model plane
(`vz-ai-stack.sh model`), which is the source of truth, not the in-agent
`hermes model` picker.

**See the matrix first** — it's read-only and shows what each role is *assigned*
vs what it *effectively* renders, and flags **DRIFT**:

```bash
vz-ai-stack.sh model list           # add --json for machine-readable
```

**Expected.** A catalog of models plus a per-agent matrix with columns including
**ASSIGNED**, **EFFECTIVE**, and **DRIFT** — DRIFT is set when a role's effective
model differs from what you assigned (see availability-gating below).

**Reassign one role:**

```bash
vz-ai-stack.sh model assign hermes_ml_engineer local-qwen3-coder
```

This re-points `installer/models.yml` and syncs that agent.

**Blanket-assign every role:**

```bash
vz-ai-stack.sh model assign all claude-opus-sub-max
```

`assign all` backs up `models.yml` to **`models.yml.bak`** first (rollback:
`cp installer/models.yml.bak installer/models.yml`).

**Render everything** (reconcile config + restart LiteLLM):

```bash
vz-ai-stack.sh model sync                 # full reconcile
vz-ai-stack.sh model sync --dry-run       # preview: plan + a unified diff of config.yaml, NO writes
vz-ai-stack.sh model sync --no-restart    # reconcile config but skip the LiteLLM restart
```

**Availability-gating (teach this).** If the assigned model's upstream is down —
LM Studio not running, Meridian unreachable, or a required cloud key missing —
the role **auto-falls-back to the default `local-gemma4`** (the always-on Ollama
fallback) and `model list` shows it under **DRIFT**. When the upstream returns,
the role **re-gates automatically** on the next sync — you don't have to
reassign. The fallback is a safety floor, not a silent failure: the DRIFT column
tells you it happened.

**Reasoning effort.** Reasoning effort is the **model's** knob (Meridian's
`effort`, OpenAI/codex-bridge's `reasoning_effort`), set per *model definition*
in `installer/models.yml`. Valid levels by runtime:

- Meridian models: `low | medium | high | xhigh | max | ultracode`
- OpenAI / codex-bridge models: `none | low | medium | high | xhigh`

Two equivalent ways to change it (both auto-`sync` to apply):

```bash
# A) the model-edit subcommand (validates the level against the runtime, then syncs):
vz-ai-stack.sh model edit claude-opus-sub-max effort xhigh

# B) edit installer/models.yml -> the model's `effort:` field, then:
vz-ai-stack.sh model sync
```

<!-- TODO(orchestrator): verify the spec's "there is NO model edit command" claim.
     It is FALSE against the real code: installer/lib/models.sh defines `cmd_edit`,
     dispatched as `model edit <name> <field> <value>` (main() ~L1734), help text
     ~L1751 "edit a safe field: rpm|tpm|ttl|big|effort|note", and `effort` is an
     explicitly-editable, runtime-validated field (cmd_edit ~L1385-1393, identity/
     endpoint fields are refused). I documented BOTH the real `model edit … effort`
     command AND the models.yml-edit path rather than write a documented falsehood
     (SOUL r1/r15: verify, don't assume; never invent OR mis-state a command). The
     offline grep "no `model edit` string appears" will therefore NOT pass by design —
     please confirm you want `model edit` documented (it exists) or re-confirm the
     spec's non-existence claim. -->

**Verify a role's live model.** `config check` reports the agent's
**configuration/env status** (config version, which env keys are set), not the
routed model name. To confirm a role is wired to LiteLLM at all, run:

```bash
openshell sandbox exec -n hermes-fleet-v1 --no-tty -- hermes --profile hermes_manager config check
```

**Expected.** A config-status report (e.g. `Config version: NN ✓`, then the
required/optional env keys with ○/✓ markers). For the *routed model itself*, the
authoritative views are `vz-ai-stack.sh model list` (the EFFECTIVE column, host
side) or the rendered LiteLLM config (`providers.litellm.model` in the agent's
config.yaml, which the installer greps directly when verifying routing).

> Note: `vz-ai-stack.sh model assign/sync/edit` is the **installer's**
> declarative binding (the source of truth in `models.yml`); `hermes model`
> (§2) is the **agent's own in-session** picker — different layer, different job.

---

## 5) Reach Hermes from chat apps — Telegram & Slack · 🟡

**Frame this clearly: Telegram works out of the box; Slack is a documented
self-setup with two prerequisites.** Hermes-agent natively supports several chat
platforms, but ai-stack only **pre-wires Telegram**.

### Telegram — pre-wired by ai-stack (Phase 20)

```bash
vz-ai-stack.sh install 20
```

**Secure-by-default.** With **no allowlist** the bot connects but **denies every
user** — it stays silent. That's deliberate: the gateway can drive all nine
profiles, so it must never be open by accident. To actually use it, set your
numeric Telegram id in `.env` and re-run the phase:

```bash
# in ~/ai-stack/.env:
HERMES_TELEGRAM_ALLOWED_USERS=<your numeric Telegram id>
# then:
vz-ai-stack.sh install 20
```

The gateway runs **inside** the sandbox and long-polls `api.telegram.org`
(allowlisted by Phase 04's network policy) — no host daemon, no exposed port.

**Status / stop** (the gateway is managed by hermes' own lifecycle):

```bash
openshell sandbox exec -n hermes-fleet-v1 -- hermes gateway status
openshell sandbox exec -n hermes-fleet-v1 -- hermes gateway stop
```

The bot is **`@vz_hermes_controller_bot`**. DM it (once you're allowlisted) and a
profile answers.

### Slack — supported by hermes-agent, NOT pre-wired (self-setup)

hermes-agent natively supports Slack via `hermes slack` / `hermes send` / the
gateway, but **ai-stack ships only Telegram wired**. To enable Slack yourself
there are **two prerequisites you must do**:

**Prerequisite 1 — egress.** The `hermes-fleet-v1` network policy allowlists
**only `api.telegram.org` today** (`openshell/policies/hermes-fleet-v1.yaml`).
The sandbox is **deny-by-default**, so without a Slack egress block the Slack
connection just hangs. Add a Slack egress section to that policy — Slack needs
`api.slack.com:443`, `slack.com:443`, and a WebSocket path for **Socket Mode** —
then apply it:

```bash
# edit openshell/policies/hermes-fleet-v1.yaml, adding a slack egress block
# (api.slack.com:443, slack.com:443, and the wss endpoint for Socket Mode), then:
openshell policy set hermes-fleet-v1 \
  --policy /Users/mayssam.sayyadian/ai-stack/openshell/policies/hermes-fleet-v1.yaml --wait
```

**Prerequisite 2 — token.** Put a Slack **bot token** in the sandbox's
`~/.hermes/.env` (that's where hermes reads its secrets — the same file Phase 20
writes the Telegram token into).

Then pick how two-way you want it:

**One-way push (simplest — no gateway, no LLM needed).** Fire a message at a
channel:

```bash
# inside the sandbox (openshell sandbox connect hermes-fleet-v1), or via exec:
hermes send -t slack:#your-channel "deploy finished ✅"
```

Target forms: `slack:#channel` or `slack:C0123ABCD` (a channel id). List the
targets hermes can reach:

```bash
hermes send --list slack
```

(`hermes send` also targets telegram / discord / signal the same way.)

**Two-way slash-command app.** Generate a Slack app manifest that registers the
gateway's commands as native slash commands (`/btw`, `/stop`, `/model`, …),
create a Slack app from it, install it, then run the gateway:

```bash
hermes slack manifest          # prints a Slack app manifest to paste into api.slack.com
hermes gateway setup           # interactive wizard to wire the credentials
hermes gateway run             # run the gateway (now serving Slack)
```

> **Summary:** Telegram = `install 20` + your allowlist id, done. Slack = add the
> egress block + a bot token, then either `hermes send` (push) or
> `hermes slack manifest` → app → `hermes gateway setup`/`run` (two-way).

---

## 6) The claw3d 3D office · 🟡

**Why.** claw3d is a 3D "virtual office" that visualizes the fleet — walk up to an
agent's desk and chat in-scene. Under the hood it's just the **bridge** from §3:
one OpenAI-shaped endpoint that routes to every isolated agent. The office is the
fun front-end; the bridge is the part you can also script.

**Install (one-time setup — clone + npm + .env + settings.json):**

```bash
vz-ai-stack.sh install 19
```

**Run (health-gated composite):**

```bash
vz-ai-stack.sh start claw3d
```

`start claw3d` starts the **bridge on `:7780`**, waits for its `/health`, **then**
brings up the **UI on `:4310`** and opens the browser — so you never land on
"UI up, bridge dead". Bring both down with:

```bash
vz-ai-stack.sh stop claw3d
```

**At the Connect screen.** `http://localhost:4310` redirects to `/office`:

1. **Backend:** **Custom**.
2. **Upstream URL:** `http://127.0.0.1:7780` — the bridge, normally pre-filled.
3. **Token:** leave **blank**.

The 3D office and agent presence load on Connect.

**The bridge itself** (`claw3d-bridge/bridge.py`, stdlib-only) implements
claw3d's custom HTTP runtime — `/health`, `/state`, `/registry`,
`/v1/chat/completions` — and routes to the **9 Hermes roles + Pi + DeerFlow**.
Probe it directly:

```bash
# health
curl -s http://127.0.0.1:7780/health | jq
```

**Expected.**

```json
{ "ok": true, "status": "ready" }
```

```bash
# live agent state (which agents are active + their models)
curl -s http://127.0.0.1:7780/state | python3 -m json.tool | head

# chat any agent — the `role` field selects it
curl -s http://127.0.0.1:7780/v1/chat/completions \
  -d '{"role":"hermes_backend_engineer","messages":[{"role":"user","content":"ping"}]}'
```

(An unknown `role` silently falls back to `hermes_manager`.)

**Security & ops.** The bridge **binds `127.0.0.1` only** and is **auth-less** —
never give it an `/etc/hosts` alias and never expose it. An agent showing
**`[<name> unavailable]`** (rather than a 500) means its OpenShell relay is down:

```bash
brew services restart openshell
```

Logs and health:

```bash
tail -f installer/state/claw3d-bridge.log     # the bridge
tail -f installer/state/claw3d.log            # the UI
vz-ai-stack.sh doctor claw3d                  # health check
```

---

## Troubleshooting & the security model

A compact map of what breaks, why, and the fix — and the security invariants that
make the fleet safe to hand a goal to.

| Symptom | Cause | Fix |
|---|---|---|
| `openshell sandbox exec/connect` fails fast | OpenShell relay idle-timed-out | `brew services restart openshell`; confirm with `openshell sandbox list` (sandbox must be `Ready`) |
| Bridge / office shows `[<name> unavailable]` | that agent's relay is down | `brew services restart openshell` (§6) |
| Workspace **Sessions sidebar** crashes (`reading 'map'`) | dashboard not bound `0.0.0.0` cross-container | ai-stack ships the hardened image + `HERMES_DASHBOARD_HOST=0.0.0.0` (§1) |
| Slack connection hangs | sandbox is deny-by-default; no Slack egress | add the Slack egress block + `openshell policy set … --wait` (§5) |
| Telegram bot silent | secure-by-default denies all with no allowlist | set `HERMES_TELEGRAM_ALLOWED_USERS` + re-run `install 20` (§5) |
| A role runs on the wrong model | upstream down → availability-gated to `local-gemma4` | check the **DRIFT** column in `model list`; it re-gates when the upstream returns (§4) |

**The security model (baked in, not optional).**

- **The sandbox is deny-by-default egress** (the Phase 04 network policy). That's
  exactly *why* Slack needs an explicit egress add (§5) — nothing leaves the
  sandbox unless the policy allows it. Telegram works only because
  `api.telegram.org` is on the allowlist.
- **Agents never hold the LiteLLM key.** Each role calls inference with **no
  credentials**; the **OpenShell gateway injects the scoped key server-side**, so
  a profile can think (via LiteLLM) without ever being able to read or exfiltrate
  the key.
- **Read-only roles cannot write.** `reviewing_engineer` and `incident_manager`
  are read-only — they emit findings and coordinate, never edits.
- **The manager is the single entrance.** It frames, routes, and executes
  directly when fastest; its own changes still pass the review + verification
  gates (`team-protocol`). Executors don't self-delegate — routing is the
  manager's job.
- **The bridge is loopback-only and auth-less** — never expose it (§6).

---

**See also:** [TUTORIAL.md Act IV](TUTORIAL.md) (the narrative) ·
[SERVICE-PLAYGROUND.md](SERVICE-PLAYGROUND.md) (per-service 2-minute entries:
`hermes_fleet`, `hermes_workspace`, `hermes_telegram`, `claw3d`).
