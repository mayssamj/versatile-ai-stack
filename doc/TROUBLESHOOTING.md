# Troubleshooting

For the 40 known failure modes the doctor handles, see [DOCTOR.md](DOCTOR.md).
This file is for everything else.

---

## "Phoenix dashboard says 'Waiting for traces to arrive…'"

The most common new-install problem. **It's almost always `PHOENIX_API_KEY`
being empty.** Phoenix runs with auth ON; the OTLP exporter inside LiteLLM
gets `401: Invalid token` on every trace push. Symptoms:

```bash
docker logs litellm 2>&1 | grep "Failed to export"
# {"message": "Failed to export batch code: 401, reason: Invalid token", ...}
```

Fix:

```bash
open http://phoenix:6006
# log in admin@localhost / your-password
# Settings → API Keys → create
# paste key into ~/ai-stack/.env as PHOENIX_API_KEY=...
stack apply-restarts                       # recreate litellm with new env
stack test 01h                             # verify 'ai-stack' project appears
```

---

## "I edited services.yml / .env but nothing changed"

The installer is not a daemon. It doesn't watch files. After you edit
declared state, you have to ask it to reconcile:

```bash
stack status            # see what drifted
stack apply-restarts    # if .env changed and a container needs recreate
```

Or directly recreate one service:

```bash
bash ~/ai-stack/bin/start-<svc>.sh --recreate
```

`--recreate` is required — start scripts refuse silent `docker rm -f`.

---

## "I `docker restart`'d litellm and my new env vars aren't visible"

By design of docker, not the installer: **`docker restart` does NOT reload
`--env-file`.** The container's environment is fixed at `docker run` time.

Use the managed start script's `--recreate` flag instead. It does
`docker rm -f` + `docker run`, picking up the current `--env-file`:

```bash
bash ~/ai-stack/bin/start-litellm.sh --recreate
```

The doctor check `litellm_env_loaded` catches this drift specifically.

---

## "OrbStack bind-mount weirdness — host shows empty, container shows full"

**This is OrbStack behavior, not a bug.** A running container holds a snapshot
view of its bind mount; host-side changes don't propagate into the running
container until the container is recreated.

Two practical consequences:

1. If you `touch` or write to `~/ai-stack/traces/litellm.jsonl` from the host,
   the running litellm container may not see it. Read from inside the
   container instead:
   ```bash
   docker exec litellm tail -f /traces/litellm.jsonl
   ```
2. If you `docker rm -f <container>` and start a new one with the same `-v`
   flags, the new container sees the HOST's current view of that path — which
   may be empty if the old container had stuffed data there since startup.
   This is why the **adoption flow** does `docker cp` BEFORE `docker rm`:
   it extracts the in-container data first.

If you find yourself needing host visibility into a running container's mount,
either restart the container (so its snapshot refreshes) or `docker cp` the
file out.

---

## "openshell gateway start: unrecognized subcommand"

The OpenShell CLI (0.0.5x line) has moved away from the `gateway start` shape
the install guide assumed. The current shape uses `gateway add`,
`gateway login`, `gateway select` to manage REGISTRATIONS, not lifecycle.

Phase 04 detects this and writes runtime steps to:

```bash
cat ~/ai-stack/installer/state/openshell-manual-steps.md
```

Run the manual gateway registration there. Once `openshell sandbox list`
shows `hermes-fleet-v1`, run `stack install 04f` to mount the SOULs and
bootstrap the 7 profiles.

If OpenShell upstream changes again, update phase 04's docs to match.

---

## "OpenShell `sandbox create` hangs and never returns"

**No longer a manual recovery dance — it's handled in code.** On macOS the
OpenShell `sandbox create` CLI never returns even after the sandbox reaches
`Phase=Ready`. `installer/lib/openshell.sh` (`openshell_sandbox_ensure`) now
runs the create in the background, polls `sandbox get` for `Phase=Ready`,
kills the hung create CLI once Ready, then retries/escalates as needed.
Phases 04 and 15 both go through this watchdog, so a clean `install all`
brings sandboxes up without intervention.

If a sandbox is still wedged (e.g. left over from an interrupted run), do a
clean recreate:

```bash
bash vz-ai-stack.sh reset --confirm hard --yes   # deletes OpenShell sandboxes (preserves data)
bash vz-ai-stack.sh install all                  # watchdog recreates them
```

---

## "A sandbox is pegging ~36% CPU with `ExpiredSignature` in its logs" (OpenShell CPU storm)

A recurring, high-CPU failure that is **distinct** from the create-hang above. After
~8 h of sandbox uptime its short-lived **gateway token expires**. The in-sandbox agent
then retries its log-push gRPC with **no backoff** — hundreds of reconnects/second
(`invalid token: ExpiredSignature`, "log push stream lost, reconnecting") — pegging
**~36% CPU per sandbox** while the container restart-loops. Confirm:

```bash
docker stats --no-stream | grep -E 'hermes-fleet-v1|pi-v1'   # CPU% high
docker logs --tail 50 hermes-fleet-v1 2>&1 | grep -i ExpiredSignature
```

**The fix is to RECREATE the sandbox — a gateway restart does NOT refresh the token;
only recreation mints a fresh one** (empirically verified). This is now **auto-healed**
by a launchd watchdog installed by Phase 04:

```bash
WD=~/ai-stack/bin/openshell-watchdog.sh

$WD status                 # is the launchd job loaded? last run / exit?
$WD run                    # run one detect+recreate cycle now (manual sweep)
$WD install                # (re)install the launchd timer (every 600s)
$WD uninstall              # remove the launchd timer

# Detect-only (delete the dead sandbox to stop the burn, but don't recreate):
AI_STACK_WATCHDOG_RECREATE=0 $WD run
```

What the watchdog does on each run (every 600 s by default): for each sandbox it
detects the storm by its unambiguous signature (ExpiredSignature / reconnect-storm in
recent logs, or a climbing `RestartCount` → the sandbox is already dead, so acting
loses nothing — it won't false-fire on a busy sandbox), then deletes + recreates it via
its install phase. It is throttled (≤ 1 recreate per thing per 30 min), logs to
`installer/state/openshell-watchdog.log`, and posts a desktop notification. It skips
while an `vz-ai-stack.sh` is already running. Doctor **check 39 (`openshell_storm`)** is the
on-demand twin: `stack doctor openshell` surfaces a live storm and reports whether the
watchdog is loaded.

---

## "The whole machine feels hot/slow even when idle" (OrbStack CPU floor + the 34-container stack)

On a full stack (~34 containers) OrbStack's VM helper process is effectively a **CPU
floor** — it consumes a baseline even when every container is idle. On a 24 GB M-series
box that baseline matters. Mitigation: **cap OrbStack's resources** so it can't claim
the whole machine.

> **OrbStack → Settings → Resources** → set a CPU/RAM cap, e.g. **6–8 cores / 12–14 GB**.

This bounds the VM helper and leaves headroom for the host (and for Ollama, which runs
on the host, not in a container). Two other CPU draws to rule out before blaming the
stack:

- **LM Studio** (if you ran Phase 25) idle-spins ~0.8–1 core even stopped — quit it when
  not in use (see next section).
- **Corporate EDR / MDM agents** (security/management daemons) are a separate, often
  significant CPU draw. They're **out of scope** for this stack — identify them with
  `top -o cpu` and take it up with IT; nothing here will quiet them.

The OpenShell expired-token storm (above) is another ~36%/sandbox spike — check for it
first if CPU is high *and* you have sandboxes up.

---

## "LM Studio is using CPU even though I'm not using it" (Phase 25 opt-in caveat)

Expected, and exactly why Phase 25 is **opt-in**. The LM Studio **desktop app**
idle-spins **~0.8–1 core even with no model loaded and the server stopped**. On a 24 GB
box that's a real liability. So:

- Run LM Studio **only when you want its MLX models** — the two big agent models
  `local-qwen3.6` + `local-qwen3-coder` (~17 GB each) and `local-lfm2-mlx` (LFM2.5 with
  working tool-calling, which the Ollama GGUF can't do). `local-gemma4` stays on Ollama,
  which remains the default runtime.
- **QUIT LM Studio when done:**
  ```bash
  ~/.lmstudio/bin/lms server stop     # stop the OpenAI server on :1234
  # then quit the LM Studio app itself (Cmd-Q) — stopping the server is not enough
  ```
- Want MLX without the app idle-cost? Use the **headless** alternative:
  `pip install mlx-lm` then `mlx_lm.server` (then point `litellm/config.yaml` at it the
  same way Phase 25 wires the LM Studio server).

If `local-lfm2-mlx` calls fail after you quit LM Studio, that's why — restart the server
(`lms server start`) or remove the model from `litellm/config.yaml` while it's off.
Agents **assigned** an lmstudio model (e.g. `hermes_software_engineer` → `local-qwen3-coder`)
don't 404 when LM Studio is down — `vz-ai-stack.sh model sync` availability-gates them back to
`local-gemma4`. Re-run `model sync` once LM Studio is up to promote them again (see
[models.md](models.md)).

---

## "git clone failed: Repository not found"

Some best-effort phases (05 Hermes Workspace, 07 AutoFyn, 11 autoreason)
clone from upstream repos whose URLs may have moved. The installer logs a
warning but doesn't fail the phase.

Find the correct upstream, then either:

```bash
git clone <real-url> ~/ai-stack/<svc>
bash vz-ai-stack.sh install <phase>   # phase detects existing checkout and proceeds
```

Or, if you have the source elsewhere:

```bash
cp -R /path/to/source ~/ai-stack/<svc>
bash vz-ai-stack.sh install <phase>
```

---

## "FalkorDB / Qdrant data appears empty after a recreate"

Same root cause as the OrbStack bind-mount issue above. The **adoption flow**
mitigates this for the original takeover, but if you do a subsequent
`--recreate` on an already-managed container, the data may not survive
because the host bind-mount path itself is the source of truth.

Mitigation:

```bash
# Before recreate
docker exec falkordb redis-cli SAVE       # flush AOF to disk
docker cp falkordb:/data/. ~/ai-stack/data/falkor.bak-$(date +%Y%m%d)/

# Recreate
bash bin/start-falkordb.sh --recreate

# If empty:
docker cp ~/ai-stack/data/falkor.bak-<ts>/. falkordb:/data/
docker restart falkordb
```

This is why `docker.sh::backup_before_recreate` does `SAVE` for FalkorDB and
`docker cp` for Phoenix sqlite before any destructive op.

---

## "Honcho's redis port collides with FalkorDB on 6379"

Phase 03 handles this: the generated
`~/ai-stack/honcho/docker-compose.override.yml` has:

```yaml
services:
  redis:
    ports: !reset []
```

which removes the upstream's `127.0.0.1:6379:6379` mapping that would have
collided with FalkorDB's `127.0.10.7:6379:6379` publish. Honcho's internal
services still reach redis via the docker network as `redis:6379`.

If you see `Bind for 127.0.10.7:6379 failed: port is already allocated` from
honcho compose, check that the override file is present:

```bash
cat ~/ai-stack/honcho/docker-compose.override.yml
```

If missing, re-run phase 03:

```bash
bash vz-ai-stack.sh install 03
```

---

## "Ollama pull stuck / timed out / corrupted"

```bash
# Clean partial blob
ollama rm <model>:<tag>

# Re-pull
ollama pull <model>:<tag>
```

`ollama pull` resumes by default but occasionally a hash check fails. The
`ollama_models_fix` in the doctor does this automatically when a model fails.

If your disk is full, the pull silently fails. Pre-check:

```bash
df -h ~                  # ~/.ollama lives in your home; need ~30GB free
```

---

## "Permission denied" on .env from a script

`.env` is mode 0600. If a script run by another user (or via sudo) tries to
read it, permission denied. Don't run installer scripts with sudo (vz-ai-stack.sh
refuses anyway).

If `.env` got chmod'd wrong (e.g., an editor recreated it):

```bash
chmod 600 ~/ai-stack/.env
```

The doctor's `env_valid` check fixes this automatically.

---

## "I want to see what the vz-ai-stack.sh actually did"

Per-run logs are in `CHANGELOG.d/<run-id>.md`:

```bash
ls -la ~/ai-stack/CHANGELOG.d/
stack history             # assembled chronologically
```

Each significant action (`record` and `record_block` calls in the lib) writes
there.

---

## "Connection refused on http://<alias>:<port>"

The single most common post-refactor problem. Run `bash vz-ai-stack.sh verify`
first — Phase 00·V's 6 probes will pinpoint which layer broke. If
that's not available, the four most likely causes, in order:

1. **lo0 alias not bound.** This is the killer that doesn't log anywhere:
   `/etc/hosts` resolves `litellm` to `127.0.10.1`, `docker -p
   127.0.10.1:4000:4000` registers cleanly, but `curl http://litellm:4000`
   hangs or returns connection-refused because macOS does not auto-route
   `127.0.0.0/8`. Check:
   ```bash
   ifconfig lo0 | grep 127.0.10
   ```
   Should list every alias IP from `installer/lib/aliases.tsv`. If it's
   missing rows, run `sudo bash vz-ai-stack.sh prepare-sudo`. Doctor check
   19 detects this systematically. The launchd plist
   `/Library/LaunchDaemons/com.ai-stack.loopback.plist` re-binds on
   boot — confirm with `sudo launchctl list | grep ai-stack.loopback`.

2. **`/etc/hosts` block missing.** Run Phase 00·N: `bash vz-ai-stack.sh install 00n`.
   It's idempotent (no-op if already correct) and prompts for `sudo` once.
   Confirm with `dscacheutil -q host -a name litellm` — should print
   `ip_address: 127.0.10.1`.

3. **The container is still on the OLD `127.0.0.1` scheme.** If the
   container existed before the refactor (e.g., was started by a prior
   session) it's not joined to the `ai-stack` network and is not bound to
   `127.0.10.x` — so the alias resolves but nothing is listening on it.
   Adopt it:
   ```bash
   stack adopt litellm
   stack adopt phoenix
   stack adopt falkordb
   stack adopt qdrant
   ```
   `stack doctor` reports which containers are foreign.

4. **`dscacheutil` cache is stale.** macOS caches host lookups; the
   installer flushes after writing the block but a long-running shell may
   still have the old answer. Force a flush:
   ```bash
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   ```
   Then retry. As a sanity-check, the underlying `/etc/hosts` lookup is
   layer-independent — `awk '$2=="litellm"{print $1}' /etc/hosts` should
   print `127.0.10.1` regardless of cache state.

---

## "Every http://<alias>:80 URL goes to the same container" (OrbStack `*:80` wildcard)

If you see `curl http://litellm`, `curl http://phoenix`, `curl
http://openwebui` all returning the same response (whichever service was
started first), you've hit the OrbStack `*:80` wildcard collision.
**This was the failure mode that drove the 2026-05-28 port-form change.**

The cause: OrbStack collapses every `--publish 127.0.10.X:80:Y` into a
single `*:80` host listener regardless of bind IP. Even though `docker
inspect` shows distinct `HostIp` values, only one container's listener
actually receives traffic on port 80.

**Confirmation:**

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep ':80 '
# If you see a single *:80 line (not multiple 127.0.10.X:80 lines), the
# wildcard collapse is in effect.
```

**Fix:** `aliases.tsv` already sets `host_port == container_port` for
every HTTP service. Mac and container dial the SAME URL form
(`http://litellm:4000`, `http://phoenix:6006`, `http://openwebui:8080`).
If you still see the symptom, you have stale `bin/start-*.sh` files from
before the patch — re-pull or re-run the installer to refresh them, then
`bash vz-ai-stack.sh reset --confirm hard` (preserves data) and
`bash vz-ai-stack.sh install all` to re-publish on native ports.

---

## "A container can't reach another by name"

From inside a container, `wget http://litellm:4000/health` returns "bad
address" or "not found." Diagnostic order:

1. **Is the calling container on `ai-stack`?**
   ```bash
   docker inspect <caller> --format '{{json .NetworkSettings.Networks}}' | jq keys
   ```
   The output must include `"ai-stack"`. If not, recreate via
   `bin/start-<caller>.sh --recreate` (the canonical flag set includes
   `--network ai-stack`).

2. **Is the callee on `ai-stack`?** Same `docker inspect` for the callee.
   The two must share at least one network for Docker's embedded DNS to
   resolve the bare name. Doctor check 16 catches this systematically.

3. **Multi-network container?** A container on N networks (today: only
   `honcho-api-1` on both `honcho_default` and `ai-stack`) MUST use
   **fully-qualified DNS** for cross-network calls:
   `http://litellm.ai-stack:4000/v1` (not bare `http://litellm:4000/v1`).
   Docker's multi-network bare-name resolution order is unspec'd. Honcho's
   `.env` already does this; if you wire a new multi-network service, use
   the same pattern.

4. **Docker daemon weirdness.** `docker network inspect ai-stack` and
   verify each expected container appears in the `Containers` list. If
   the network looks corrupt, `reset --confirm hard` recreates it from
   scratch.

---

## "VPN / route conflicts with 127.0.10.x"

The refactor uses `127.0.10.x` loopback addresses for /etc/hosts aliases
and `10.99.0.0/24` for the `ai-stack` Docker bridge. Both choices avoid
common collisions, but a corporate VPN can still inject routes that win.

**Symptoms:**

- `curl http://litellm:4000` hangs or times out (instead of refusing).
- `netstat -nr | grep 127.0.10` shows a route NOT to `lo0`.
- `traceroute 127.0.10.1` hops off the Mac.

Phase 00·N pre-flights this and refuses to install if a pre-existing
`127.0.10.x` route is present. If you saw the install proceed and routes
appeared later (VPN connected after install), disconnect the VPN, run
`bash vz-ai-stack.sh install 00n` to re-flush, then reconnect.

For Docker subnet collisions (rare, but VPN tunnels do span 10.x):

```bash
# Inspect the bridge's subnet
docker network inspect ai-stack --format '{{(index .IPAM.Config 0).Subnet}}'

# If it conflicts with a VPN tunnel:
docker network rm ai-stack
AI_STACK_SUBNET=10.142.0.0/24 bash vz-ai-stack.sh install 00n
```

See [refactor-design-final.md § D22](../installer/state/refactor-design-final.md)
for the full design rationale.

---

## "Lock held by pid N. Re-run with LOCK_FORCE=1."

Another `vz-ai-stack.sh` or `doctor` is running. If you're sure it's hung or dead:

```bash
LOCK_FORCE=1 stack doctor
```

The lock dir is `~/ai-stack/installer/state/.lock/`. The PID file inside it
tells you who's holding it.

Stale locks (PID not alive) are detected and broken automatically. The force
flag is only needed for live-but-hung PIDs.

---

## "The Telegram bot (@vz_hermes_controller_bot) doesn't reply" (Phase 20)

By far the most common cause: **the bot is LOCKED.** The gateway is secure-by-default
— with no allowlist it connects to Telegram but **denies every user**, so your DMs
get no response. `doctor` shows the check passing with a "**running but LOCKED**" note,
and Phase 20 prints a loud "BOT IS LOCKED" banner. Fix:

```bash
# 1. Get your numeric Telegram user id — DM @userinfobot on Telegram.
# 2. Add it to .env (mode 0600):
echo 'HERMES_TELEGRAM_ALLOWED_USERS=123456789' >> ~/ai-stack/.env   # your id
# 3. Re-apply (restarts the gateway with the new allowlist):
bash ~/ai-stack/vz-ai-stack.sh install 20
```

Open access (anyone who finds the bot) is `HERMES_TELEGRAM_ALLOW_ALL=true` in `.env`
— **not advised**, since the bot can drive all 7 agent profiles.

Other causes:

```bash
OSH=/opt/homebrew/bin/openshell
# Is the gateway actually running inside the sandbox?
$OSH sandbox exec -n hermes-fleet-v1 -- hermes gateway status      # expect "running (PID …)"
# Read the gateway log (auth errors, conflicts):
$OSH sandbox exec -n hermes-fleet-v1 -- tail -30 /sandbox/.hermes-gateway.log
# Restart it:
bash ~/ai-stack/bin/start-hermes-telegram.sh
```

- **`unauthorized` / `invalid token` / `401`** in the log → the bot token in `.env`
  (`HERMES_TELEGRAM_BOT_TOKEN`) is wrong or revoked. Get a fresh one from @BotFather,
  update `.env`, re-run `install 20`.
- **`409 conflict`** right after a restart is **benign and self-heals** — Telegram
  holds the previous instance's long-poll for ~50s. It is NOT flagged as an error.
- **Gateway not running after a relay outage** → the gateway long-polls Telegram
  *directly* (not through the relay), so it survives relay idle-timeouts; but if the
  sandbox itself was recreated (`reset … hard` + `install`), Phase 20 re-runs and
  restarts it. If the sandbox is down, fix that first (`vz-ai-stack.sh install 04`).

---

## Diagnosing from scratch when nothing's obvious

```bash
# 1. What does the installer think is happening?
stack status
stack doctor

# 2. What are the containers actually doing?
docker ps --all --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# 3. What did each container's first 30 lines of logs say?
for c in litellm phoenix falkordb qdrant openwebui honcho-api-1 llm_guard; do
  echo "=== $c ==="
  docker logs --tail 30 "$c" 2>&1 || echo "  (not running)"
done

# 4. Are the host ports really listening?
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(11434|4000|6006|6379|6333|8000|8080|3000) '

# 5. Can the containers reach each other?
docker exec litellm wget -qO- --timeout=2 http://phoenix:6006/healthz; echo
docker exec litellm wget -qO- --timeout=2 http://ollama:11434/api/tags; echo
docker exec litellm wget -qO- --timeout=2 http://honcho:8000/health; echo

# 6. Are env vars actually inside the container?
docker exec litellm env | sort | grep -iE '^(phoenix|honcho|litellm|openai|anthropic|openrouter|google)'

# 7. Do the smoke tests pass?
stack test 01
stack test 01h
stack test 02
stack test 03
stack test 05
```

If something in steps 1–7 reveals a new recurring failure, add it as a doctor
check (see [DOCTOR.md](DOCTOR.md)) so the next person doesn't have to debug
it from scratch.
