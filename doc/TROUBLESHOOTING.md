# Troubleshooting

For the doctor's 72 checks, see [DOCTOR.md](DOCTOR.md).
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

## "LiteLLM container is 'Up' but `/v1/models` times out" (Phase 01 fails on a fresh / 2nd machine)

A classic cold-machine / second-machine install blocker: the `litellm` container reports
**Up**, Postgres `:5432` is reachable, but `GET /v1/models` hangs and Phase 01 fails with
*"did not return a model list"*. The usual cause is that **the `litellm` Postgres DATABASE
doesn't exist** — Honcho's Postgres only creates the `postgres` DB, so the database named
in `DATABASE_URL` is missing and Prisma blocks uvicorn startup. The server is up; the DB
it needs isn't.

Fix:

```bash
bash ~/ai-stack/bin/start-litellm.sh --recreate   # now auto-creates the 'litellm' DB if missing
# or just re-run the phase (it self-heals):
stack install 01
```

Phase 01 now **self-heals** a running-but-unhealthy managed LiteLLM/Phoenix/OpenWebUI on
cold/second machines and, on failure, prints a self-diagnosing block — container status,
published ports, Postgres reachability, whether the **`litellm` DB** exists, master-key
match, and the last 20 (secret-redacted) log lines — so the install explains itself instead
of dying on a bare error. To check the DB by hand:

```bash
docker exec honcho-database-1 psql -U postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='litellm'"   # prints 1 if present
```

---

## "My `.env` looks corrupted (catalog text in a value)" — re-run `setup`

`vz-ai-stack.sh setup` (alias `keys`) writes nothing harmful. If an older run ever
corrupted `.env` — e.g. its own prompt catalog text landed inside a value — just re-run it
and it **self-heals** the file:

```bash
bash ~/ai-stack/vz-ai-stack.sh setup
```

`setup` always ensures the non-interactive baseline first, so a local-only / Claude-subscription
install needs no keys at all; every external-secret prompt is optional and skippable.

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
bootstrap the 9 profiles.

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
only recreation mints a fresh one** (empirically verified). A launchd watchdog
installed by Phase 04 watches for this, but is **warn-only by default and data-safe**:
it halts the burn and raises an alert; recreation (which discards in-sandbox state)
stays a deliberate action unless you opt in.

```bash
WD=~/ai-stack/bin/openshell-watchdog.sh

$WD status                 # is the launchd job loaded? last run / exit?
$WD run                    # run one detect cycle now (warn-only: halts the burn, raises an alert)
$WD install                # (re)install the launchd timer (every 600s)
$WD uninstall              # remove the launchd timer

# Opt-in: also delete + recreate the dead sandbox (capability-checked, Ready-verified):
AI_STACK_WATCHDOG_RECREATE=1 $WD run
```

What the watchdog does on each run (every 600 s by default): for each sandbox it
detects the storm by its unambiguous signature (ExpiredSignature / reconnect-storm in
recent logs, or a climbing `RestartCount` → the sandbox is already dead, so acting
loses nothing — it won't false-fire on a busy sandbox). **By default** it then halts the
container to stop the CPU burn, writes an alert to
`installer/state/openshell-watchdog.alert` (surfaced by doctor check 43), and posts a
desktop notification — it leaves the sandbox for **you** to recreate (`vz-ai-stack.sh
install 04 04f 15 20 04h`), since recreation discards in-sandbox state. With
`AI_STACK_WATCHDOG_RECREATE=1` it instead verifies the rebuild can run, then deletes +
recreates (throttled ≤ 1 recreate per thing per 30 min) and fails loud if the rebuild
doesn't come back Ready. It logs to `installer/state/openshell-watchdog.log` and skips
while a `vz-ai-stack.sh` is already running. Doctor **check 39 (`openshell_storm`)** is the
on-demand twin (`stack doctor openshell` surfaces a live storm and whether the watchdog
is loaded); **check 43 (`watchdog_alert`)** surfaces a pending alert the watchdog left.

**Durability / auto-heal modes** (persisted sticky in `installer/state/watchdog.conf` by
`$WD install`, so a later bare `install` keeps them — an explicit env var still wins):

- `AI_STACK_SANDBOX_PERSIST=1` + `AI_STACK_WATCHDOG_REMINT=1` — sandboxes are long-lived
  (`restart=unless-stopped` + the timer runs at boot), and a storm is healed by an **in-place
  token re-mint** (no recreate, no data loss) instead of warn-only halt.
- `AI_STACK_WATCHDOG_GATEWAY_SUPERVISE=1` (**W2**, default ON) — relaunch the Hermes gateway
  process inside the sandbox if it dies (reboot / crash) so the Slack/Telegram bot comes back
  without a manual `install`.
- `AI_STACK_WATCHDOG_REVIVE_EXITED=1` (**W4**, default ON) — `docker start` a managed sandbox
  that died on reboot/crash and wasn't auto-restarted (an operator `docker stop` is respected:
  an `unless-stopped`/`always` container left exited is treated as a deliberate stop).
- `AI_STACK_WATCHDOG_CRASHLOOP_BREAK=1` (**W1**, default ON) — a NON-sandbox managed container
  stuck restarting (a bad image/config crash-loop, e.g. `autofyn-agent`) is stopped
  (`restart=no` + stop, writable layer kept) and surfaced, so it stops burning CPU.

`stack status` shows the active modes on its **`durability:`** line plus a **host-memory** block
(swap, free+inactive RAM, top host-app RSS) — on this 24 GB box the memory lever is host apps
(quit LM Studio / Chrome) rather than the containers.

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
  `local-nemotron3-nano-4b-mlx` (the same nemotron on Apple MLX, opt-in). Start the server with
  `vz-ai-stack.sh start lmstudio` (idempotent). `install lmstudio` is the one-time
  **assignment-driven** setup: it loads only MLX models assigned to an agent in
  `models.yml`. (The retired `local-lfm2-mlx` demo, LFM2.5, is no longer wired by
  default; it stays an `LMS_LOAD_LFM2=1 bash vz-ai-stack.sh install lmstudio` opt-in.)
  `local` stays on Ollama, which remains the default runtime.
- **QUIT LM Studio when done:**
  ```bash
  vz-ai-stack.sh stop lmstudio        # stop the OpenAI server on :1234
  # then quit the LM Studio app itself (Cmd-Q) — stopping the server is not enough
  ```
- Want MLX without the app idle-cost? Use the **headless** alternative:
  `pip install mlx-lm` then `mlx_lm.server` (then point `litellm/config.yaml` at it the
  same way Phase 25 wires the LM Studio server).

If you opted into the retired `local-lfm2-mlx` (`LMS_LOAD_LFM2=1`) and its calls fail
after you quit LM Studio, that's why — restart the server (`vz-ai-stack.sh start
lmstudio`) or remove the model from `litellm/config.yaml` while it's off.
The same availability-gating protects subscription-assigned agents: the nine Hermes
profiles (e.g. `hermes_backend_engineer` → `claude-opus-sub-max`), `pi`, and
`deerflow` don't 404 when the Meridian host daemon is down — `vz-ai-stack.sh model sync`
gates them back to `local`. Re-run `model sync` once Meridian is up
(`bin/start-meridian.sh`) to promote them again (see [models.md](models.md)).

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
— **not advised**, since the bot can drive all 9 agent profiles.

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

## "The Slack bot doesn't reply" (Phase 38)

By far the most common cause: **the bot is LOCKED.** Slack is secure-by-default
— with no allowlist it connects to Slack but **denies every user**, so your DMs and
`@`-mentions get no response. `doctor` shows check 67 passing with a "**running but
LOCKED**" note, and Phase 38 prints a loud "SLACK BOT IS LOCKED" banner. Fix:

```bash
# 1. Get your Slack member id — Slack profile → ⋮ (More) → Copy member ID (U…).
# 2. Add it to .env (mode 0600):
echo 'HERMES_SLACK_ALLOWED_USERS=U0123ABCD' >> ~/ai-stack/.env   # your member id
# 3. Re-apply (restarts the Slack role router with the new allowlist):
bash ~/ai-stack/vz-ai-stack.sh install 38
```

`HERMES_SLACK_ALLOW_ALL=true` does **not** grant operator authority in the default
role-router mode. Use explicit `HERMES_SLACK_ALLOWED_USERS=<your_member_id>` for
any Slack user who may drive Hermes. `ALLOW_ALL` is only honored if
`HERMES_SLACK_ROLE_ROUTER=false` rolls back to upstream-native Slack.

Other causes:

```bash
OSH=/opt/homebrew/bin/openshell
# Is the role router actually running inside the sandbox?
$OSH sandbox exec -n hermes-fleet-v1 -- cat /sandbox/.hermes-slack-role-router.pid
# Read the role-router log (auth errors, blocked egress, Socket-Mode connect):
$OSH sandbox exec -n hermes-fleet-v1 -- tail -80 /sandbox/.hermes-slack-role-router.log
# Restart it:
bash ~/ai-stack/bin/start-hermes-slack.sh
```

- **`policy_denied` / blocked egress** in the log → a Slack host is missing from the
  Phase 04 `slack` egress policy (Socket Mode needs `slack.com`, `api.slack.com`,
  `wss-primary.slack.com`, `wss-backup.slack.com`, `files.slack.com`). Re-run
  `vz-ai-stack.sh install 04` (or `install 38`, which live-applies the policy).
- **`invalid_auth` / `token_revoked` / `missing_scope` / `not_allowed_token_type`**
  in the log → a token is wrong/revoked or the app is missing a scope. Slack needs
  BOTH `HERMES_SLACK_BOT_TOKEN` (`xoxb-…`) and `HERMES_SLACK_APP_TOKEN` (`xapp-…`,
  with `connections:write` for Socket Mode). After changing the app's scopes you must
  **re-install the Slack app** to issue a fresh bot token, update `.env`, then re-run
  `install 38`.
- **Only one token configured** → a missing app token means no Socket Mode connection
  at all (check 67 fails with "not both in sandbox"). Set both in `.env` and re-run
  `install 38`.
- **Role syntax not working** → Phase 38 defaults to ai-stack's virtual role router.
  DM the app with `techlead: ...`, `backend: ...`, `qa: ...`, or `delivery: ...`.
  If you set `HERMES_SLACK_ROLE_ROUTER=false`, you are using upstream Hermes'
  native Slack adapter instead, so role prefixes/mission threads are not active.
- **Connected but no events arrive** → in the Slack app settings, enable Socket Mode,
  subscribe to bot events `app_mention`, `message.channels`, `message.groups`,
  `message.im`, and `message.mpim`, add bot scopes `app_mentions:read`,
  `channels:history`, `groups:history`, `im:history`, `mpim:history`, and
  `chat:write`, reinstall the app, then re-run `install 38`.
- **Role router not running after a relay outage** → the Socket-Mode WebSocket dials
  slack.com *directly* (not through the relay), so it survives relay idle-timeouts;
  but if the sandbox was recreated (`reset … hard` + `install`), re-run `install 38`.
  If the sandbox is down, fix that first (`vz-ai-stack.sh install 04`).

---

## MemPalace verbatim memory (Phase 26)

MemPalace is installed by `install all` (Phase 26) — local-first **verbatim**
conversation memory (CLI + MCP, no daemon, no port). Embeddings run **on-device** (CoreML); storage is on-device
ChromaDB. Install is **PyPI-only** — `mempalace.tech` is a **malware squat**, never
install from it. Doctor check 44 green-skips when it isn't installed. The recurring
gotchas:

- **First `mine` fails with `httpx.ReadTimeout` (downloading the ONNX model).** The
  first run downloads the ~80MB on-device embedding model once. If the download
  times out, **just re-run** the same `bin/mempalace mine …` command — it resumes
  and the model is cached after the first success.
  ```bash
  bash ~/ai-stack/bin/mempalace mine ~/ai-stack --mode convos --extract general
  # httpx.ReadTimeout → re-run the exact same command; it's a one-time model fetch.
  ```

- **`embeddinggemma` silently falls back to minilm.** The opt-in multilingual
  `embeddinggemma` embedding function can **silently fall back** to `all-MiniLM-L6-v2`
  if its model can't be fetched — which is exactly why minilm (384-dim) is the
  default. If you expected multilingual quality and aren't getting it, confirm the
  embeddinggemma model actually downloaded before assuming it's active
  (`bin/mempalace status` shows the active model).

- **`import chromadb` breaks after touching qdrant-client.** **NEVER co-install
  `qdrant-client` into the mempalace uv-tool env** — its protobuf/grpc pins break
  `import chromadb`, which is why MemPalace runs on ChromaDB. The staged Qdrant
  backend adapter (`mempalace/backend-qdrant/`) is deliberately **tested in an
  isolated venv**, not the tool env. If `import chromadb` is throwing protobuf
  errors, you (or a tool) co-installed qdrant-client — recreate the tool env via
  `bash ~/ai-stack/vz-ai-stack.sh install 26`.

- **"No palace found".** Expected until you've populated memory. Run a `mine` (or
  let the auto-save hooks capture a session) first:
  ```bash
  bash ~/ai-stack/bin/mempalace mine ~/ai-stack --mode convos --extract general
  bash ~/ai-stack/bin/mempalace status     # should now show a palace
  ```

- **GUI / launchd-spawned Claude Code can't find `mempalace`.** A Claude Code
  launched from the macOS GUI (or by launchd) may not have `~/.local/bin` on `PATH`,
  so the bare `mempalace` / hook commands aren't found. The `bin/mempalace-hook-*`
  launchers fix this by setting PATH explicitly — point the hooks at those launchers
  (`bin/mempalace-hooks install --apply` wires them) rather than calling `mempalace`
  directly. Disable auto-save live without uninstalling via
  `MEMPALACE_HOOKS_AUTO_SAVE=false`.

The optional refiner LLM routes through LiteLLM (`MEMPALACE_LITELLM_KEY` → Phoenix);
if refiner calls fail, check that key the same way as any other scoped LiteLLM key
(`GET http://litellm:4000/v1/models` with it). Embeddings are on-device and never
touch LiteLLM.

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
