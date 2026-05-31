# Doctor — checks reference

`bash install.sh doctor` runs all 32 checks and offers a per-check auto-fix
when one fails. This doc lists every check, what it asserts, when it fails,
and what the fix does.

Run filtered:

```bash
stack doctor                    # all 32
stack doctor phoenix            # only checks whose name contains "phoenix"
stack doctor network            # only the network/alias checks (14–22)
stack doctor unsloth            # only the Unsloth Studio check (23)
stack doctor pi                 # only the Pi sandbox + virtual key checks (24-26)
stack doctor lumen              # only the Lumen MCP check (27)
NO_PROMPT=1 stack doctor        # report-only, skip all auto-fixes
OPENSHELL_DOCTOR_SLOW=1 stack doctor  # also run check 25's slow negative probes
```

**Transition WARN:** during the network refactor's adoption phase, checks
14–17 degrade FAIL to WARN if any foreign containers are still present
(check 12). Once all containers are adopted onto `ai-stack`, they fail as
normal. Checks 19–22 do not degrade — they assert kernel/filesystem
invariants that hold regardless of foreign-container state.

For pre-install verification (before the first phase has run), use
`bash install.sh verify` instead — it runs Phase 00·V's 6 probes
(see [INSTALL.md § verify](INSTALL.md#install-sh-verify)).

The doctor reports an `exit 1` if any check failed and was not auto-fixed.
Useful in CI / `git pre-push` hooks.

---

## Check files live one-per-failure-mode

```
installer/doctor/checks/
├── 01_orbstack_running.sh
├── 02_ai_stack_network.sh                 (replaces host_docker_internal)
├── 03_env_valid.sh
├── 04_phoenix_endpoint_set.sh
├── 05_litellm_env_loaded.sh
├── 06_arize_phoenix_callback.sh
├── 07_guardrails_file_or_remove.sh
├── 08_ollama_models.sh
├── 09_phoenix_project.sh
├── 10_helicone_cleanup.sh
├── 11_port_collisions.sh
├── 12_foreign_containers.sh
├── 13_phoenix_api_key.sh
├── 14_ai_stack_network.sh                 (bridge exists, driver=bridge)
├── 15_hosts_block.sh                      (/etc/hosts has every alias)
├── 16_container_network_membership.sh     (managed containers on ai-stack)
├── 17_alias_resolution.sh                 (per-alias protocol-aware probe)
├── 18_dns_collision_guard.sh              (no cross-network name collisions)
├── 19_lo0_aliases.sh                      (every aliases.tsv IP bound on lo0)
├── 20_container_alias_routable.sh         (transient probe reaches each managed alias)
├── 21_container_dns_in_network.sh         (ai-stack containers resolve each other by bare name)
└── 22_etc_hosts_ownership.sh              (/etc/hosts is root:wheel mode 644)
```

Adding a new failure mode = adding a new file. No central registry. See
[OPERATIONS.md § Adding a new doctor check](OPERATIONS.md#adding-a-new-doctor-check).

---

## 01 · OrbStack / Docker daemon reachable

| | |
|---|---|
| Asserts | `docker info` succeeds. |
| Fails when | OrbStack isn't running, or Docker Desktop is hung, or the docker socket is wrong. |
| Auto-fix | `open -a OrbStack`, wait up to 60 seconds for `docker info` to succeed. |

If auto-fix fails: open OrbStack manually. If on Docker Desktop and migrating
to OrbStack, ensure `~/.docker/run/docker.sock` is owned by OrbStack.

---

## 02 · ai-stack docker network + /etc/hosts integrity

| | |
|---|---|
| Asserts | Every alias in `installer/lib/aliases.tsv` resolves via `/etc/hosts` on the Mac AND inside the `ai-stack` Docker network via Docker's embedded DNS. The `ollama` alias resolves via `--add-host=ollama:host-gateway` inside each consumer container. |
| Fails when | `/etc/hosts` is missing entries (Phase 00·N not run, block tampered with), or a managed container is not joined to the `ai-stack` network, or `--add-host=ollama:host-gateway` is missing on a consumer. Breaks: LiteLLM → Ollama, LiteLLM → Phoenix, Open WebUI → LiteLLM, etc. |
| Auto-fix | Re-runs Phase 00·N's `hosts_ensure_block` + `network_ensure ai-stack` helpers; for missing container network-membership, suggests `stack adopt <svc>` per offender. |

---

## 03 · .env file exists, 0600, parses cleanly

| | |
|---|---|
| Asserts | `~/ai-stack/.env` exists; mode is `-rw-------`; every non-comment line matches `^[A-Z_][A-Z0-9_]*=`; no CRLF line endings. |
| Fails when | `.env` got chmod'd loose by an editor; user typed `KEY = value` (with spaces around `=`); file was saved as CRLF (Windows line endings). |
| Auto-fix | `ensure_env_file` + `chmod 600` + `fix_crlf` (strip `\r` from every line). |

---

## 04 · PHOENIX_COLLECTOR_HTTP_ENDPOINT set in .env

| | |
|---|---|
| Asserts | The value is non-empty and starts with `http://` or `https://`. |
| Fails when | Phase 00 was skipped, or the line was deleted manually. |
| Auto-fix | Writes `http://phoenix:6006/v1/traces` and `PHOENIX_PROJECT_NAME=ai-stack`, queues litellm restart. |

The most-hit landmine in the prior session: LiteLLM's OTel exporter defaults
to `localhost:6006` when this is empty. Inside the LiteLLM container,
`localhost` is the container itself, not Phoenix → connection refused → 200-line
urllib3 stack trace in logs. The fix uses the docker-network alias
`phoenix:6006` to reach the Phoenix container directly via Docker's
embedded DNS.

---

## 05 · LiteLLM container has PHOENIX_COLLECTOR_HTTP_ENDPOINT non-empty

| | |
|---|---|
| Asserts | `docker exec litellm env` shows `PHOENIX_COLLECTOR_HTTP_ENDPOINT=…` with a value. |
| Fails when | `.env` was fixed (check 04 passes) but the running litellm container hasn't been recreated to pick up the new value. (Reminder: `docker restart` does NOT reload `--env-file`.) |
| Auto-fix | Queues litellm restart (conservative — doesn't auto-recreate). Run `stack apply-restarts` to drain. |

This check is the in-container twin of check 04; they catch different failure
modes.

---

## 06 · arize_phoenix callback in config.yaml AND OTLP exporter active

| | |
|---|---|
| Asserts | `litellm/config.yaml` has `arize_phoenix` in `litellm_settings.callbacks`. If litellm is running, its logs show OTLP / OpenTelemetry / `export batch` activity (which proves the callback is loaded — even a "Failed to export" line is evidence). |
| Fails when | The callbacks list got reverted, OR litellm was started with a config that didn't have the callback, OR the python module failed to import at boot. |
| Auto-fix | `litellm_ensure_callback arize_phoenix` (adds to config.yaml) + queues litellm restart. |

---

## 07 · guardrails.handler callback has matching guardrails.py

| | |
|---|---|
| Asserts | If `guardrails.handler` is in the callbacks list, `litellm/guardrails.py` exists. |
| Fails when | The callback list references a python module file that doesn't exist on disk. LiteLLM will crash at boot with `ImportError: Could not find module file /app/config/guardrails.py`. |
| Auto-fix | Prompts: either re-run phase 04·G (which creates `guardrails.py`), or remove `guardrails.handler` from the callbacks list. |

---

## 08 · Ollama running + required models pulled

| | |
|---|---|
| Asserts | `ollama` binary on PATH; `/api/tags` 200; `gemma4:e4b`, `qwen3.6:27b-q4_K_M`, `nomic-embed-text` all installed (matches either bare name or `:latest`-tag variant). |
| Fails when | Ollama isn't running, or someone `ollama rm`'d a model, or the model never finished downloading. |
| Auto-fix | `brew services start ollama`; `ollama pull` per missing model. On partial-pull (download corrupted), `ollama rm` first then retry. |

Note: this can take many minutes (qwen3.6:27b is 17GB).

---

## 09 · Phoenix has 'ai-stack' project (traces flowing)

| | |
|---|---|
| Asserts | `/v1/projects` returns a JSON list containing `ai-stack` (in addition to Phoenix's catch-all `default`). |
| Fails when | (a) no traces have ever arrived (LiteLLM not wired up, or down, or callback misconfigured) OR (b) `PHOENIX_API_KEY` is empty and `/v1/projects` returns 401. |
| Auto-fix | None. Manually: send an inference call through LiteLLM, wait 10s for OTel batch flush, re-run this check. If 401, see check 13. |

---

## 10 · No leftover Helicone artifacts (deprecated)

| | |
|---|---|
| Asserts | No `~/ai-stack/helicone/` directory; `HELICONE_API_KEY` is empty in `.env`. |
| Fails when | A previous install used Helicone (Mayssam migrated to Phoenix). |
| Auto-fix | Confirms, then `rm -rf ~/ai-stack/helicone/` and clears the env var. |

---

## 11 · No non-docker process on ai-stack IP:port pairs

| | |
|---|---|
| Asserts | None of the canonical `127.0.10.x:<port>` bindings (one per row in `aliases.tsv`) is held by a process other than OrbStack/Docker/Ollama. Filtering is by **IP:port pair**, not by bare port — multiple services on host port 80 (each on a different 127.0.10.x) is normal. |
| Fails when | Some other app is bound to a specific `127.0.10.x:<port>` we expect (e.g., a stray `redis-server` on `127.0.10.7:6379` instead of FalkorDB). |
| Auto-fix | None. Kill the offender, or override the IP/port for that service. |

The check tolerates Docker/OrbStack/Ollama owning these bindings — that's
expected.

---

## 12 · No foreign ai-stack containers (and managed ones are on the network)

| | |
|---|---|
| Asserts | (a) None of `litellm phoenix falkordb qdrant openwebui llm_guard honcho` exists as a docker container without the `ai-stack.managed=true` label. (b) If a container carries `ai-stack.managed=true`, its `.NetworkSettings.Networks` includes `ai-stack`. |
| Fails when | A container with one of those names is running but wasn't started by the installer (foreign — typical after re-installing on a host with prior work). Or a managed container is somehow attached only to the default bridge (no `--network ai-stack`). |
| Auto-fix | None directly — adoption is interactive. Run `stack adopt <svc>` per foreign container. Adoption also re-attaches managed containers to `ai-stack` as part of the recreate. |

This is the main mechanism that protects state when re-installing on a host
that already has work running.

---

## 13 · PHOENIX_API_KEY set (auth-on Phoenix needs it to accept OTLP)

| | |
|---|---|
| Asserts | If Phoenix is running with auth ON (`/v1/projects` returns 401 without a key), `PHOENIX_API_KEY` is non-empty in `.env`. If the key IS set, recent litellm logs don't show `Failed to export batch code: 401`. |
| Fails when | Phoenix auth is enabled but no API key has been minted, OR a key is in `.env` but the running litellm container started before the key was set (so its env doesn't have it). |
| Auto-fix | None — Phoenix doesn't expose API key creation over its REST surface. Manual: log in to http://phoenix:6006 → Settings → API Keys → create one → paste into `.env` → `stack apply-restarts`. |

This is the highest-value check for getting traces flowing. See
[INSTALL.md § 3.1](INSTALL.md#1-create-the-phoenix-api-key) for the full
workflow.

---

## 14 · `ai-stack` Docker bridge network exists

| | |
|---|---|
| Asserts | `docker network inspect ai-stack` returns an object with `Driver: bridge`. The network was created by Phase 00·N with an explicit `--subnet 10.99.0.0/24` (or whatever `AI_STACK_SUBNET` was set to). |
| Fails when | Phase 00·N was skipped, or the network was manually `docker network rm`'d (e.g., via `reset --confirm hard`), or Docker daemon lost its state. |
| Auto-fix | Calls `network_ensure ai-stack` from `lib/network.sh` to recreate the bridge with the canonical subnet. |

Transition WARN: if check 12 reports any foreign containers, this check
degrades FAIL to WARN (yellow indicator, doesn't fail the doctor exit
code) — the network is fine, but the foreign containers haven't joined it
yet. Adopt them, then this check goes back to hard PASS/FAIL.

---

## 15 · `/etc/hosts` block has every canonical alias

| | |
|---|---|
| Asserts | `/etc/hosts` contains the `# >>> ai-stack` … `# <<< ai-stack` managed block AND every alias from `installer/lib/aliases.tsv` is present with the expected `127.0.10.x` IP. No extras, no missing rows. |
| Fails when | Phase 00·N was skipped, the block was hand-edited, or a `reset --confirm nuke` stripped it without re-running 00·N. |
| Auto-fix | Offers to call `hosts_ensure_block` (which prompts for `sudo` once, writes atomically, and flushes `dscacheutil`). |

Transition WARN as in check 14.

---

## 16 · Every managed container is on the `ai-stack` network

| | |
|---|---|
| Asserts | For every container with label `ai-stack.managed=true`, `docker inspect --format '{{json .NetworkSettings.Networks}}'` includes `ai-stack`. Foreign containers (no managed label) are NOT checked here — check 12 handles them. |
| Fails when | A managed container was started without `--network ai-stack` (typically: an old `bin/start-*.sh` that pre-dates the refactor, or manual `docker run`). |
| Auto-fix | Offers `docker network connect ai-stack <container>` for each offender. Persistent fix is to re-run `bin/start-<svc>.sh --recreate` so the canonical flags are baked in. |

---

## 17 · Per-alias reachability (protocol-aware)

| | |
|---|---|
| Asserts | For every alias in `aliases.tsv` whose service is enabled in `services.yml`, the protocol-appropriate probe succeeds: |
| | • `http`: `curl -sf --max-time 2 http://<alias>/<health-path>` returns 200. |
| | • `redis`: `redis-cli -h <alias> -p 6379 PING` returns `PONG`. |
| | • `grpc`: `nc -z <alias> 4317` succeeds (TCP connect only — full gRPC handshake would need `grpcurl`). |
| Fails when | The /etc/hosts block is correct but the service behind the alias isn't responding (container down, wrong health path, auth required). |
| Auto-fix | None — investigate per-service. Most often the service container is stopped (run `bin/start-<svc>.sh`) or the health path moved upstream. |

Transition WARN as in check 14.

---

## 18 · DNS collision guard (no cross-network duplicates)

| | |
|---|---|
| Asserts | No bare service name appears in two distinct Docker networks with different target containers. Important for multi-network containers like `honcho-api-1` (which sits on both `honcho_default` and `ai-stack`); a collision would make bare-name resolution non-deterministic. |
| Fails when | Two networks both have a container named `litellm` (or similar), or `honcho_default` and `ai-stack` both define a `redis` that resolves to different IPs (no risk today — `redis` only exists in `honcho_default`). |
| Auto-fix | None automated. Manual: rename the offender, or use fully-qualified DNS (`<service>.<network>`) at the call site. The Honcho compose already does this: `LLM_OPENAI_API_BASE=http://litellm.ai-stack:4000/v1`. |

The honcho-api / honcho-deriver pair (both compose v1 `honcho-api` /
`honcho-deriver` and v2 `honcho-api-1` / `honcho-deriver-1`) is on the
allowlist — they are *expected* to live on two networks and that's
documented in [CHANGELOG.md 2026-05-27 entry](../CHANGELOG.md).

---

## 19 · Every `aliases.tsv` IP is bound on `lo0`

| | |
|---|---|
| Asserts | For every alias in `installer/lib/aliases.tsv` whose IP is in `127.0.10.0/24`, `ifconfig lo0` shows that IP as a bound alias. |
| Fails when | (a) `prepare-sudo` was never run, (b) `lo0_install_persistence_plist` failed and macOS was rebooted (aliases evaporate), (c) someone manually `ifconfig lo0 -alias 127.0.10.X` removed an alias. The symptom is the silent-killer: `/etc/hosts` resolves the alias correctly, `docker -p` registers the port, but the kernel routing table has no path to deliver packets to `127.0.10.X` — `curl` hangs or returns connection-refused with no useful log line anywhere. |
| Auto-fix | Calls `lo0_ensure_aliases` from `lib/network.sh` (requires `sudo`). Re-binds every missing alias and re-installs the launchd plist for reboot persistence. |

This check exists because macOS does NOT auto-route `127.0.0.0/8` — only
`127.0.0.1` is on `lo0` by default. Every other loopback IP must be
explicitly bound. The brief from the original install guide assumed the
Linux model (where all of `127/8` is implicitly loopback); this check is
the safety net that catches that assumption regressing.

---

## 20 · Per-managed-container alias is routable end-to-end

| | |
|---|---|
| Asserts | For every container with label `ai-stack.managed=true`, spawn a transient probe on the `ai-stack` network and run `curl --connect-timeout 2 http://<alias>:<port>/`. The probe must succeed (even a `404` body counts — we're testing the routing chain, not the HTTP semantics). |
| Fails when | The container is running, the alias resolves, lo0 is bound, but the actual TCP path doesn't deliver — most often the container forgot to `--publish 127.0.10.X:<port>:<port>` (e.g., an old `bin/start-*.sh` that pre-dates the 2026-05-28 native-port change), or OrbStack got into a weird state where the publish registered but the listener didn't bind. |
| Auto-fix | None — investigate per service. Common fix is `bash bin/start-<svc>.sh --recreate`. |

This check is the in-network twin of check 17 (which probes from the Mac
side). 17 + 20 together cover both directions of the routing chain.

---

## 21 · ai-stack containers resolve each other by bare name

| | |
|---|---|
| Asserts | For every container on the `ai-stack` network, spawn a transient alpine probe and confirm `getent hosts <name>` resolves every other container's bare name. Apps talk to each other by bare name (e.g. LiteLLM → `http://phoenix-otlp:4317`); a silent failure here means OTel traces vanish without an error log. |
| Fails when | Docker's embedded DNS regressed (rare but does happen after OrbStack updates), a managed container was started without `--network ai-stack`, or the `ai-stack` network was torn down and recreated while containers were still running. Skips gracefully when the network doesn't exist yet (legitimate pre-install state — check 14 covers the network-must-exist invariant post-install). |
| Auto-fix | None automated — Docker manages its own DNS resolver. Suggested steps: `docker info \| grep -i dns`, `orb restart`, or `bash install.sh reset --confirm hard` to recreate the network. |

---

## 22 · `/etc/hosts` ownership and mode

| | |
|---|---|
| Asserts | `stat /etc/hosts` reports owner `root`, group `wheel`, mode `0644`. |
| Fails when | `prepare-sudo` ran an `awk → tmp → sudo mv` workflow but the tmp was user-owned and the destination didn't inherit `root:wheel`. macOS does not silently break on this (you can read it as anyone) but it does mean an unprivileged process can rewrite `/etc/hosts` — a real privilege-escalation surface. |
| Auto-fix | `sudo chown root:wheel /etc/hosts && sudo chmod 0644 /etc/hosts`. |

This check is post-2026-05-28 hardening — `prepare-sudo` should never
leave the file in a wrong-owner state, but the doctor is the catch-all
that protects against a regression.

---

## 23 · Unsloth Studio CLI installed + daemon serving :8898

| | |
|---|---|
| Asserts | (1) The `unsloth` CLI shim is resolvable (either on `$PATH` or at `~/.local/bin/unsloth`). (2) `installer/state/unsloth.pid` exists and points at a live PID. (3) Port `:8898` is bound. (4) `curl http://127.0.0.1:8898/api/health` returns a JSON body containing `"status":"healthy"`. |
| Fails when | The official `curl|sh` installer never ran (CLI missing), the studio daemon died (pid alive but port unbound, or pid stale), or the studio is mid-startup (first launch downloads PyTorch + pre-caches a helper GGUF — can take 2–5 min). |
| Auto-fix | Calls `bin/start-unsloth.sh` (no sudo). The script is idempotent — re-running is safe. If the CLI itself is missing, surfaces `bash install.sh install 14` as the manual fix (Phase 14 runs the official installer). |

This check is the per-process twin of check 17 (which probes `http://unsloth:8898/` via the alias). 23 catches the daemon-dead case where the alias resolves but the daemon isn't there to answer.

---

## 24 · pi-v1 OpenShell sandbox is Ready (Phase 15)

| | |
|---|---|
| Asserts | The `openshell` CLI resolves AND `openshell sandbox list` shows `pi-v1` in state `Ready`. Also prints the sha256 prefix of the on-disk `openshell/policies/pi-v1.yaml` as an informational marker so you can spot policy drift between what's on disk and what the sandbox loaded. |
| Fails when | Phase 15 hasn't run, the sandbox was deleted (`openshell sandbox delete pi-v1`), the gateway is down (cannot enumerate sandboxes), or the sandbox is in a transient state (`Provisioning`, `Failed`, etc.). |
| Auto-fix | Surfaces `bash install.sh install 15` — Phase 15 is idempotent and re-creates the sandbox if missing, applies the policy, and re-mints `PI_LITELLM_KEY` if invalid. |

ANSI-strip note: `openshell sandbox list` emits color codes around the state column; the check pipes through `sed 's/\x1b\[[0-9;]*m//g'` before matching `Ready`. Don't change the awk pattern without preserving the strip.

---

## 25 · pi-v1 network policy: LiteLLM/Honcho/docs-mcp reachable, ai-stack DBs denied

| | |
|---|---|
| Asserts | From inside the `pi-v1` sandbox, the 3 allowlisted destinations (`host.docker.internal:4000` LiteLLM, `:8000` Honcho, `:8765` docs-mcp) respond with any HTTP code that's NOT a proxy-deny. The OpenShell egress proxy emits HTTP 403 with body `{"error":"policy_denied"}` when refusing; the check greps that signature to distinguish "destination reached" from "destination denied". By default only positive probes run (~6s). With `OPENSHELL_DOCTOR_SLOW=1` (or `DOCTOR_ALL=1`), also runs 9 negative probes against denied destinations — those must all return the `policy_denied` signature. |
| Fails when | Allowlist hosts return `policy_denied` (policy file edited but not re-applied; sandbox restarted with stale policy; LiteLLM lost its 127.0.0.1:4000 dual-bind so `host.docker.internal:4000` is unreachable). In slow mode: a denied destination returns something OTHER than `policy_denied` — a policy leak. |
| Auto-fix | Surfaces `openshell policy set pi-v1 --policy openshell/policies/pi-v1.yaml --wait` for the apply case, and CHANGELOG 2026-05-29 (host.docker.internal dual-bind) for the LiteLLM case. |

**What this check does NOT prove**: Honcho peer-level isolation. Honcho v3 has no API-key-scoped peer enforcement; a compromised Pi could still POST to `/v3/workspaces/default/peers/hermes_software_engineer/...` because the network policy allows reaching Honcho at all. The peer namespace boundary is a write-side convention, not a read-side authorization. Document this honestly in the USER-GUIDE.

---

## 26 · LiteLLM virtual key PI_LITELLM_KEY enforces model allowlist server-side

| | |
|---|---|
| Asserts | (1) `PI_LITELLM_KEY` is present in `.env`. (2) `GET http://litellm:4000/v1/models` with the virtual key returns exactly `local,local-heavy,local-lfm2` (sorted). (3) `POST /v1/chat/completions` with `model=claude-opus` returns a body containing the case-insensitive substring `"key not allowed"`. The substring match (rather than the full message) makes the check resilient to LiteLLM's wording across minor versions. |
| Fails when | Phase 15 never minted the key (LiteLLM has no Postgres DB; `LITELLM_MASTER_KEY` rotation; .env got nuked). The allowlist itself was changed via LiteLLM's `/key/update`. The virtual key path was bypassed by changing Pi's extension to use the master key directly. |
| Auto-fix | Surfaces `bash install.sh install 15` — Phase 15 detects an invalid key via the same `/v1/models` probe and re-mints. |

Pre-condition: if LiteLLM itself is down (`/health/readiness` fails), this check WARN-skips with a pointer to check 11 + Phase 01 rather than fail-cascading.

---

## 27 · Lumen MCP binary + ollama embedding model present (Phase 16)

| | |
|---|---|
| Asserts | (1) The vendored Lumen binary exists at `$AI_STACK/vendor/lumen/lumen-0.0.41-darwin-arm64` and is executable. (2) The binary's `version` subcommand reports exactly `0.0.41` (catches tampering / wrong-binary swap; the SHA256 check in Phase 16 already happens at download time). (3) The `bin/lumen` wrapper script exists. (4) `ollama list` includes `ordis/jina-embeddings-v2-base-code` (the embedding backend Lumen needs to function). |
| Fails when | Phase 16 never ran (binary missing), an upstream Lumen version is pinned and you bumped without updating the SHA256/version constants, somebody deleted `bin/lumen`, or `ollama list` doesn't show the embedding model (manual `ollama rm` or fresh Ollama install since Phase 16). |
| Auto-fix | Surfaces `bash install.sh install 16` — Phase 16 is idempotent and re-creates everything (binary + wrapper + embed-model pull). |

**What this check does NOT prove.** That any index has been built. Lumen's index lives at `~/.local/share/lumen/<hash>/` keyed by `(project_path, embed_model, binary_version)` and is user-state, not install-state — `bin/lumen index <path>` builds one on demand. The doctor doesn't care which repos you've indexed.

**No port or daemon to probe.** Lumen v0.0.41 is stdio-only (verified in source: `cmd/stdio.go` only initializes `mcp.StdioTransport{}`). Each MCP client spawns its own `lumen stdio` subprocess. There is no `:8766` listener, no `/health` endpoint — this check covers what install-state is verifiable, which is just artifact presence.

---

## 28 · DeerFlow `config.yaml` has model entries + compose passes `LITELLM_MASTER_KEY` (Phase 10)

| | |
|---|---|
| Asserts | (1) `deer-flow/config.yaml` has at least one uncommented `- name:` entry inside the `models:` block. (2) `deer-flow/docker/docker-compose.yaml` surfaces `LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}` to the gateway's `environment:` block. Skipped cleanly if `deer-flow/` doesn't exist (Phase 10 not selected). |
| Fails when | DeerFlow was seeded from the upstream `config.example.yaml` without injection — the `models:` block contains only commented examples, which YAML parses as `None`, which fails Pydantic's `list[ModelConfig]` validator inside `app/gateway/app.py:lifespan`. The 4 uvicorn workers crash on every restart, re-import LangChain + LangGraph + DeerFlow (the expensive part), validate, fail, crash again. Result: ~340% CPU continuously, even while idle, because Python is literally re-importing LangGraph in a hot loop. The compose env-passthrough catch is separate: without `LITELLM_MASTER_KEY` in the gateway container, `$LITELLM_MASTER_KEY` in `config.yaml` resolves to the empty string at startup, which LiteLLM rejects with 401 on the first request (silent if you never make one, but explicit if you do). |
| Auto-fix | Surfaces `bash install.sh install 10` — Phase 10 is idempotent and re-applies all three patches (config.yaml, docker-compose.yaml, deer-flow/.env) on every run. |

**Why `host.docker.internal:4000` and not `litellm:4000`.** The deer-flow Docker network and the ai-stack network are separate. Dual-network membership would work but adds coupling; the simpler path is to dial back to the host's LiteLLM via `host.docker.internal:host-gateway` (already wired in the upstream compose `extra_hosts`).

**Was this always 340% CPU?** No — the previous diagnosis ("4 idle workers chewing CPU") was wrong. The workers chew CPU because they CAN'T start, not because they're up and idle. With a valid `models:` entry, idle CPU drops to ~1%, MEM ~520 MB. See CHANGELOG 2026-05-29.

---

## 29 · ACE installed + LiteLLM virtual key valid (Phase 17)

| | |
|---|---|
| Asserts | (1) `ace/.git` exists (clone present). (2) `ace/.venv/bin/python` is executable (uv sync succeeded). (3) `bin/ace` wrapper exists + is executable. (4) `ace/.env` exists and has `OPENAI_BASE_URL=http://litellm:4000/v1` so calls route through LiteLLM (free Phoenix tracing). (5) `ACE_LITELLM_KEY` from `.env` is non-empty AND accepted by LiteLLM's `/v1/models`. Skipped cleanly when `ace/` doesn't exist (Phase 17 not selected). |
| Fails when | Phase 17 never ran (clone missing), `uv sync` drift left the venv stale, somebody deleted `bin/ace`, `.env` was hand-edited away from the LiteLLM base URL (so ACE would silently call `api.openai.com` instead), or the virtual key was revoked from LiteLLM's DB. |
| Auto-fix | Surfaces `bash install.sh install 17` — Phase 17 is idempotent: re-uses the clone, re-runs `uv sync` (no-op if locked), re-mints the virtual key only if the existing one is rejected. |

**What this check does NOT prove.** That any eval has been run. Playbooks live under `ace/results/` and are user-state, not install-state. `bin/ace --help` lists the eval surface.

**Routing.** ACE uses the OpenAI Python SDK; `OPENAI_BASE_URL` is the canonical env-var that SDK reads to redirect every chat-completion call. Setting it to `http://litellm:4000/v1` means every LLM call from ACE — generator, reflector, curator — passes through LiteLLM and gets traced in the `ai-stack` Phoenix project for free. The `ACE_LITELLM_KEY` virtual key is scoped to `[local, local-heavy, local-lfm2]` only, so even if ACE's prompts somehow request cloud models, LiteLLM rejects with HTTP 403 ("key not allowed to access model").

---

## 30 · Hermes profiles route to LiteLLM (provider=custom:litellm, Phase 04f)

| | |
|---|---|
| Asserts | The `hermes_cos` profile config has `model.provider=custom:litellm` and `providers.litellm.base_url=http://host.docker.internal:4000` (the per-profile LiteLLM routing wired by Phase 04·F), AND `HERMES_LITELLM_KEY` is accepted by LiteLLM. |
| Fails when | Phase 04·F never ran, the profile config was reverted to a non-LiteLLM provider, `host.docker.internal:4000` is unreachable, or `HERMES_LITELLM_KEY` was revoked/rotated so LiteLLM rejects it. |
| Auto-fix | Surfaces `bash install.sh install 04f` — Phase 04·F is idempotent: it re-mints `HERMES_LITELLM_KEY`, re-adds the `litellm_proxy` endpoint to the hermes policy, and re-sets the per-profile `model.default` + `model.provider=custom:litellm` + `providers.litellm.{base_url,api_key,model}`. |

hermes-agent v0.15.2 has no `llm.*` config namespace — the old `llm.model` / `llm.openai_api_base` / `llm.openai_api_key` config was a dead no-op (and raised a `ValueError`), so Hermes silently never reached local models. The fix routes via the `custom:litellm` provider against `http://host.docker.internal:4000/v1`. Verified: a real `hermes --profile hermes_cos -m local -z` returned `PONG`.

---

## 31 · RLM installed + LiteLLM virtual key valid (Phase 18)

| | |
|---|---|
| Asserts | `rlm/.venv` imports `rlm`, `rlm/run_rlm.py` + `bin/rlm` exist, `rlm/.env` sets `OPENAI_BASE_URL=http://litellm:4000/v1`, and `RLM_LITELLM_KEY` is accepted by LiteLLM. |
| Fails when | Phase 18 never ran, the venv/wrapper is missing, `rlm/.env` doesn't route to LiteLLM, or `RLM_LITELLM_KEY` was revoked/rotated. |
| Auto-fix | Surfaces `bash install.sh install 18` (idempotent: reinstalls `rlms`, re-mints the key, regenerates `rlm/.env` + `bin/rlm`). |

Skips cleanly (passes) when RLM was never installed (`rlm/.venv` absent) — it's optional experimental tooling. RLM's REPL runs model-generated code in a **Docker sandbox** by default (`bin/rlm`); `--env local` would run it on the host.

---

## Exit codes

`bash install.sh doctor` exit codes:

| Code | Meaning |
|---|---|
| 0 | All checks passed (possibly after auto-fix). |
| 1 | One or more checks failed and were not auto-fixed. |
| 2 | Bad usage (unknown filter, malformed args). |
| 3 | Could not acquire the install lock (`LOCK_FORCE=1` to break). |

---

## When the doctor isn't enough

The doctor checks known failure modes. If you have a problem the doctor
doesn't recognize, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for less
common issues and the "how do I diagnose from scratch" recipe.

If you find a new failure mode that recurs, add it as a doctor check (see
[OPERATIONS.md § Adding a new doctor check](OPERATIONS.md#adding-a-new-doctor-check))
so the next person doesn't have to debug it from scratch.
