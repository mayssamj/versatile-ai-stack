# Troubleshooting

For the 31 known failure modes the doctor handles, see [DOCTOR.md](DOCTOR.md).
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
bash install.sh reset --confirm hard --yes   # deletes OpenShell sandboxes (preserves data)
bash install.sh install all                  # watchdog recreates them
```

---

## "git clone failed: Repository not found"

Some best-effort phases (05 Hermes Workspace, 07 AutoFyn, 11 autoreason)
clone from upstream repos whose URLs may have moved. The installer logs a
warning but doesn't fail the phase.

Find the correct upstream, then either:

```bash
git clone <real-url> ~/ai-stack/<svc>
bash install.sh install <phase>   # phase detects existing checkout and proceeds
```

Or, if you have the source elsewhere:

```bash
cp -R /path/to/source ~/ai-stack/<svc>
bash install.sh install <phase>
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
bash install.sh install 03
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
read it, permission denied. Don't run installer scripts with sudo (install.sh
refuses anyway).

If `.env` got chmod'd wrong (e.g., an editor recreated it):

```bash
chmod 600 ~/ai-stack/.env
```

The doctor's `env_valid` check fixes this automatically.

---

## "I want to see what the install.sh actually did"

Per-run logs are in `CHANGELOG.d/<run-id>.md`:

```bash
ls -la ~/ai-stack/CHANGELOG.d/
stack history             # assembled chronologically
```

Each significant action (`record` and `record_block` calls in the lib) writes
there.

---

## "Connection refused on http://<alias>:<port>"

The single most common post-refactor problem. Run `bash install.sh verify`
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
   missing rows, run `sudo bash install.sh prepare-sudo`. Doctor check
   19 detects this systematically. The launchd plist
   `/Library/LaunchDaemons/com.ai-stack.loopback.plist` re-binds on
   boot — confirm with `sudo launchctl list | grep ai-stack.loopback`.

2. **`/etc/hosts` block missing.** Run Phase 00·N: `bash install.sh install 00n`.
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
`bash install.sh reset --confirm hard` (preserves data) and
`bash install.sh install all` to re-publish on native ports.

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
`bash install.sh install 00n` to re-flush, then reconnect.

For Docker subnet collisions (rare, but VPN tunnels do span 10.x):

```bash
# Inspect the bridge's subnet
docker network inspect ai-stack --format '{{(index .IPAM.Config 0).Subnet}}'

# If it conflicts with a VPN tunnel:
docker network rm ai-stack
AI_STACK_SUBNET=10.142.0.0/24 bash install.sh install 00n
```

See [refactor-design-final.md § D22](../installer/state/refactor-design-final.md)
for the full design rationale.

---

## "Lock held by pid N. Re-run with LOCK_FORCE=1."

Another `install.sh` or `doctor` is running. If you're sure it's hung or dead:

```bash
LOCK_FORCE=1 stack doctor
```

The lock dir is `~/ai-stack/installer/state/.lock/`. The PID file inside it
tells you who's holding it.

Stale locks (PID not alive) are detected and broken automatically. The force
flag is only needed for live-but-hung PIDs.

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
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(11434|4000|6006|6379|6333|3010|8000|3001|3000) '

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
