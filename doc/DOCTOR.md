# Doctor — checks reference

`bash vz-ai-stack.sh doctor` runs all 62 checks and offers a per-check auto-fix
when one fails. This doc lists every check, what it asserts, when it fails,
and what the fix does.

Run filtered:

```bash
stack doctor                    # all 62
stack doctor phoenix            # only checks whose name contains "phoenix"
stack doctor network            # only the network/alias checks (14–22)
stack doctor unsloth            # only the Unsloth Studio check (23)
stack doctor pi                 # only the Pi sandbox + virtual key checks (24-26)
stack doctor lumen              # only the Lumen MCP check (27)
stack doctor openshell          # both OpenShell checks: CPU-storm (39) + gateway liveness (54)
NO_PROMPT=1 stack doctor        # report-only, skip all auto-fixes
OPENSHELL_DOCTOR_SLOW=1 stack doctor  # also run check 25's slow negative probes
```

**Transition WARN:** during the network refactor's adoption phase, checks
14–17 degrade FAIL to WARN if any foreign containers are still present
(check 12). Once all containers are adopted onto `ai-stack`, they fail as
normal. Checks 19–22 do not degrade — they assert kernel/filesystem
invariants that hold regardless of foreign-container state.

For pre-install verification (before the first phase has run), use
`bash vz-ai-stack.sh verify` instead — it runs Phase 00·V's 6 probes
(see [INSTALL.md § verify](INSTALL.md#install-sh-verify)).

The doctor reports an `exit 1` if any check failed and was not auto-fixed.
Useful in CI / `git pre-push` hooks.

---

## Check files live one-per-failure-mode

```
installer/doctor/checks/
├── 01_orbstack_running.sh
├── 02_host_docker_internal.sh
├── 03_env_valid.sh
├── 04_phoenix_endpoint_set.sh
├── 05_litellm_env_loaded.sh
├── 05a_litellm_keystore.sh                   (LiteLLM key-store / Postgres reachable; AUTO-HEALS)
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
├── 22_etc_hosts_ownership.sh              (/etc/hosts is root:wheel mode 644)
├── 23_unsloth_studio.sh                   (Phase 14)
├── 24_pi_v1_sandbox.sh                    (Phase 15)
├── 25_pi_v1_network_policy.sh             (Phase 15)
├── 26_pi_litellm_key_allowlist.sh         (Phase 15)
├── 27_lumen.sh                            (Phase 16)
├── 28_deerflow_config.sh                  (Phase 10)
├── 29_ace.sh                              (Phase 17)
├── 30_hermes_routing.sh                   (Phase 04f)
├── 31_rlm.sh                              (Phase 18)
├── 32_claw3d.sh                           (Phase 19)
├── 33_hermes_telegram.sh                  (Phase 20)
├── 34_portless.sh                         (opt-in Phase 21; pass-as-skip)
├── 35_cmux.sh                             (opt-in Phase 22; pass-as-skip)
├── 36_skillspector.sh                     (opt-in Phase 23; pass-as-skip)
├── 37_openagents.sh                       (opt-in Phase 24; pass-as-skip)
├── 38_lmstudio.sh                         (opt-in Phase 25; pass-as-skip)
├── 39_openshell_storm.sh                  (expired-token CPU storm + watchdog status)
├── 40_models_binding.sh                   (models.yml <-> config.yaml <-> agent render + scoped keys)
├── 41_meridian.sh                         (Claude subscription behind LiteLLM; opt-in, Phase via start-meridian.sh)
├── 42_agent_fleet.sh                      (9-role fleet across claude-code + pi personas; opt-in Phase 04h)
├── 43_watchdog_alert.sh                   (surfaces a pending OpenShell watchdog storm/recreate-failed alert)
├── 44_mempalace.sh                         (Phase 26; conditional green-skip until Phase 26 has run)
├── 45_tutorial.sh                          (always-on; doc/TUTORIAL.html self-contained / link-clean / in-sync)
├── 46_agent_fleet_parity.sh                (always-on; shared skills + Tier-1 block + each role byte-identical across the 3 frameworks)
├── 47_docker_engine_consistency.sh         (no split-brain: ambient CLI + gateway.env + managed containers on the selected engine)
├── 48_docker_engine_selection.sh           (AI_STACK_DOCKER_ENGINE present, valid, still installed)
├── 49_sourcegraph_mcp.sh                    (opt-in Phase 27; skip-clean when Sourcegraph not installed)
├── 50_aionui.sh                             (opt-in Phase 28; skip-clean when AionUi not installed)
├── 51_openwork.sh                           (opt-in Phase 29; skip-clean when OpenWork not installed)
├── 52_understand.sh                         (opt-in Phase 30; skip-clean when no knowledge graph committed)
├── 53_container_liveness.sh                 (census: every managed container EXISTS + running & healthy)
├── 54_openshell_gateway.sh                  (OpenShell gateway up on :17670 & brew-manageable)
├── 55_codex_bridge.sh                       (opt-in; GPT-5.x on your ChatGPT subscription — skip-clean when not installed)
├── 56_bare_hostname_ingress.sh              (opt-in Phase 31; host-native Caddy port-free http(s)://name/ — skip when ingress not installed/loaded)
├── 57_metagpt.sh                            (opt-in Phase 32; MetaGPT venv + scoped key — pass-as-skip when Phase 32 hasn't run)
├── 58_agentscope.sh                         (opt-in Phase 33; AgentScope venv + scoped key + optional Studio GUI :5275 — pass-as-skip)
├── 59_oasis.sh                              (opt-in Phase 34; OASIS venv + scoped key — pass-as-skip when Phase 34 hasn't run)
├── 60_chatdev.sh                            (opt-in Phase 35; ChatDev web app :5274 + scoped key — pass-as-skip when Phase 35 hasn't run)
└── 61_aitown.sh                             (opt-in Phase 36; AI Town compose stack + frontend :5273 + scoped key — pass-as-skip)
```

Adding a new failure mode = adding a new file. No central registry. See
[OPERATIONS.md § Adding a new doctor check](OPERATIONS.md#adding-a-new-doctor-check).

---

## 01 · Selected Docker engine reachable

| | |
|---|---|
| Asserts | The **selected** engine (`AI_STACK_DOCKER_ENGINE` — `orbstack` \| `docker-desktop` \| `colima` \| `podman`) is installed, valid, and its daemon answers on the engine's socket. When no engine is pinned yet, it falls back to the legacy any-daemon `docker info` probe and **warns loudly** that an unpinned engine is a split-brain risk (selection should have run in Phase 00 preflight) rather than failing a fresh/local-only box red. |
| Fails when | `AI_STACK_DOCKER_ENGINE` names an engine that isn't running/installed, or is an invalid id; or no engine is pinned AND `docker info` fails. |
| Auto-fix | Selects (if unpinned) → `engine_ensure` (install-if-missing + start + bounded wait) → `engine_pin` (writes `AI_STACK_DOCKER_ENGINE`, exports `DOCKER_HOST`, syncs `gateway.env`). |

The engine registry (`installer/lib/docker-engine.sh`) is the single source of
truth for per-engine sockets/probes. Pick or change the engine with
`vz-ai-stack.sh docker-engine select` / `set <id>` (or the global `--engine <id>`
flag); inspect it with `docker-engine status`. See [PREREQUISITES.md](PREREQUISITES.md)
for the engine matrix.

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

## 05a · LiteLLM key-store (Postgres) reachable + self-heal

| | |
|---|---|
| Asserts | honcho-database Postgres (LiteLLM's virtual-key store) is reachable; runs BEFORE the per-phase key checks so the root heals first. |
| Fails when | LiteLLM returns HTTP 503 `no_db_connection`, OR Postgres :5432 is unreachable (honcho-database down). |
| Auto-fix | AUTO-HEALS automatically (AUTOHEAL — no Y/n prompt): idempotent `docker compose up -d database` from `honcho/`. NON-destructive (never rm/volume-wipe), bounded waits, verifies Postgres + LiteLLM recovered. Worktree-guarded; fail-open if honcho absent. |

This check is why the per-phase key checks (29 ace, 30 hermes, 31 rlm,
44 mempalace) now report "key-store DOWN — heal the DB (05a)" instead of
"re-mint" on a 503: a 503 `no_db_connection` means the virtual-key store is
down, not that the key was revoked — re-minting against a down DB can't
succeed, so the de-conflated checks point you at the root (05a heals it
automatically) rather than at a dead-end re-mint.

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
| Asserts | `ollama` binary on PATH; `/api/tags` 200; the lazy `REQUIRED_MODELS` set — `gemma4:e4b` (`local-gemma4`, the default) + `nomic-embed-text` — both installed (matches either bare name or `:latest`-tag variant). |
| Fails when | Ollama isn't running, or someone `ollama rm`'d a required model, or the model never finished downloading. |
| Auto-fix | `brew services start ollama`; `ollama pull` per missing model. On partial-pull (download corrupted), `ollama rm` first then retry. |

Note: per the lazy-Ollama policy (2026-05-31, `01_inference.sh`), only `gemma4:e4b` + `nomic-embed-text` are eager-pulled. The heavy/coder models moved to LM Studio MLX (`local-qwen3.6`, `local-qwen3-coder` — opt-in), and the legacy Ollama `qwen3.6:27b` (`local-heavy`) is no longer auto-pulled, so this check no longer requires it. `OLLAMA_KEEP_ALIVE=30m` (Phase 00) keeps the default model warm for 30 min of inactivity, then releases it.

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
| Auto-fix | None automated. Manual: rename the offender, or use fully-qualified DNS (`<service>.<network>`) at the call site. The Honcho compose already does this: `LLM_OPENAI_BASE_URL=http://litellm.ai-stack:4000/v1`. |

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
| Auto-fix | None automated — Docker manages its own DNS resolver. Suggested steps: `docker info \| grep -i dns`, `orb restart`, or `bash vz-ai-stack.sh reset --confirm hard` to recreate the network. |

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
| Auto-fix | Calls `bin/start-unsloth.sh` (no sudo). The script is idempotent — re-running is safe. If the CLI itself is missing, surfaces `bash vz-ai-stack.sh install 14` as the manual fix (Phase 14 runs the official installer). |

This check is the per-process twin of check 17 (which probes `http://unsloth:8898/` via the alias). 23 catches the daemon-dead case where the alias resolves but the daemon isn't there to answer.

---

## 24 · pi-v1 OpenShell sandbox is Ready (Phase 15)

| | |
|---|---|
| Asserts | The `openshell` CLI resolves AND `openshell sandbox list` shows `pi-v1` in state `Ready`. Also prints the sha256 prefix of the on-disk `openshell/policies/pi-v1.yaml` as an informational marker so you can spot policy drift between what's on disk and what the sandbox loaded. |
| Fails when | Phase 15 hasn't run, the sandbox was deleted (`openshell sandbox delete pi-v1`), the gateway is down (cannot enumerate sandboxes), or the sandbox is in a transient state (`Provisioning`, `Failed`, etc.). |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 15` — Phase 15 is idempotent and re-creates the sandbox if missing, applies the policy, and re-mints `PI_LITELLM_KEY` if invalid. |

ANSI-strip note: `openshell sandbox list` emits color codes around the state column; the check pipes through `sed 's/\x1b\[[0-9;]*m//g'` before matching `Ready`. Don't change the awk pattern without preserving the strip.

---

## 25 · pi-v1 network policy: LiteLLM/Honcho/docs-mcp reachable, ai-stack DBs denied

| | |
|---|---|
| Asserts | From inside the `pi-v1` sandbox, the 3 allowlisted destinations (`host.docker.internal:4000` LiteLLM, `:8000` Honcho, `:8765` docs-mcp) respond with any HTTP code that's NOT a proxy-deny. The OpenShell egress proxy emits HTTP 403 with body `{"error":"policy_denied"}` when refusing; the check greps that signature to distinguish "destination reached" from "destination denied". By default only positive probes run (~6s). With `OPENSHELL_DOCTOR_SLOW=1` (or `DOCTOR_ALL=1`), also runs 9 negative probes against denied destinations — those must all return the `policy_denied` signature. |
| Fails when | Allowlist hosts return `policy_denied` (policy file edited but not re-applied; sandbox restarted with stale policy; LiteLLM lost its 127.0.0.1:4000 dual-bind so `host.docker.internal:4000` is unreachable). In slow mode: a denied destination returns something OTHER than `policy_denied` — a policy leak. |
| Auto-fix | Surfaces `openshell policy set pi-v1 --policy openshell/policies/pi-v1.yaml --wait` for the apply case, and CHANGELOG 2026-05-29 (host.docker.internal dual-bind) for the LiteLLM case. |

**What this check does NOT prove**: Honcho peer-level isolation. Honcho v3 has no API-key-scoped peer enforcement; a compromised Pi could still POST to `/v3/workspaces/default/peers/hermes_backend_engineer/...` because the network policy allows reaching Honcho at all. The peer namespace boundary is a write-side convention, not a read-side authorization. Document this honestly in the USER-GUIDE.

---

## 26 · LiteLLM virtual key PI_LITELLM_KEY enforces model allowlist server-side

| | |
|---|---|
| Asserts | (1) `PI_LITELLM_KEY` is present in `.env`. (2) `GET http://litellm:4000/v1/models` with the virtual key returns exactly the canonical superset `local,local-gemma4,local-heavy,local-lfm2,local-qwen3-coder,local-qwen3.6` (sorted) — every scoped key is minted against this fixed superset so `model assign`/`sync` can re-point Pi without re-minting. (3) `POST /v1/chat/completions` with `model=claude-opus` returns a body containing the case-insensitive substring `"key not allowed"`. The substring match (rather than the full message) makes the check resilient to LiteLLM's wording across minor versions. |
| Fails when | Phase 15 never minted the key (LiteLLM has no Postgres DB; `LITELLM_MASTER_KEY` rotation; .env got nuked). The allowlist itself was changed via LiteLLM's `/key/update`. The virtual key path was bypassed by changing Pi's extension to use the master key directly. |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 15` — Phase 15 detects an invalid key via the same `/v1/models` probe and re-mints. |

Pre-condition: if LiteLLM itself is down (`/health/readiness` fails), this check WARN-skips with a pointer to check 11 + Phase 01 rather than fail-cascading.

---

## 27 · Lumen MCP binary + ollama embedding model present (Phase 16)

| | |
|---|---|
| Asserts | (1) The vendored Lumen binary exists at `$AI_STACK/vendor/lumen/lumen-0.0.41-darwin-arm64` and is executable. (2) The binary's `version` subcommand reports exactly `0.0.41` (catches tampering / wrong-binary swap; the SHA256 check in Phase 16 already happens at download time). (3) The `bin/lumen` wrapper script exists. (4) `ollama list` includes `ordis/jina-embeddings-v2-base-code` (the embedding backend Lumen needs to function). |
| Fails when | Phase 16 never ran (binary missing), an upstream Lumen version is pinned and you bumped without updating the SHA256/version constants, somebody deleted `bin/lumen`, or `ollama list` doesn't show the embedding model (manual `ollama rm` or fresh Ollama install since Phase 16). |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 16` — Phase 16 is idempotent and re-creates everything (binary + wrapper + embed-model pull). |

**What this check does NOT prove.** That any index has been built. Lumen's index lives at `~/.local/share/lumen/<hash>/` keyed by `(project_path, embed_model, binary_version)` and is user-state, not install-state — `bin/lumen index <path>` builds one on demand. The doctor doesn't care which repos you've indexed.

**No port or daemon to probe.** Lumen v0.0.41 is stdio-only (verified in source: `cmd/stdio.go` only initializes `mcp.StdioTransport{}`). Each MCP client spawns its own `lumen stdio` subprocess. There is no `:8766` listener, no `/health` endpoint — this check covers what install-state is verifiable, which is just artifact presence.

---

## 28 · DeerFlow `config.yaml` has model entries + compose passes `LITELLM_MASTER_KEY` (Phase 10)

| | |
|---|---|
| Asserts | (1) `deer-flow/config.yaml` has at least one uncommented `- name:` entry inside the `models:` block. (2) `deer-flow/docker/docker-compose.yaml` surfaces `LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}` to the gateway's `environment:` block. Skipped cleanly if `deer-flow/` doesn't exist (Phase 10 not selected). |
| Fails when | DeerFlow was seeded from the upstream `config.example.yaml` without injection — the `models:` block contains only commented examples, which YAML parses as `None`, which fails Pydantic's `list[ModelConfig]` validator inside `app/gateway/app.py:lifespan`. The 4 uvicorn workers crash on every restart, re-import LangChain + LangGraph + DeerFlow (the expensive part), validate, fail, crash again. Result: ~340% CPU continuously, even while idle, because Python is literally re-importing LangGraph in a hot loop. The compose env-passthrough catch is separate: without `LITELLM_MASTER_KEY` in the gateway container, `$LITELLM_MASTER_KEY` in `config.yaml` resolves to the empty string at startup, which LiteLLM rejects with 401 on the first request (silent if you never make one, but explicit if you do). |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 10` — Phase 10 is idempotent and re-applies all three patches (config.yaml, docker-compose.yaml, deer-flow/.env) on every run. |

**Why `host.docker.internal:4000` and not `litellm:4000`.** The deer-flow Docker network and the ai-stack network are separate. Dual-network membership would work but adds coupling; the simpler path is to dial back to the host's LiteLLM via `host.docker.internal:host-gateway` (already wired in the upstream compose `extra_hosts`).

**Was this always 340% CPU?** No — the previous diagnosis ("4 idle workers chewing CPU") was wrong. The workers chew CPU because they CAN'T start, not because they're up and idle. With a valid `models:` entry, idle CPU drops to ~1%, MEM ~520 MB. See CHANGELOG 2026-05-29.

---

## 29 · ACE installed + LiteLLM virtual key valid (Phase 17)

| | |
|---|---|
| Asserts | (1) `ace/.git` exists (clone present). (2) `ace/.venv/bin/python` is executable (uv sync succeeded). (3) `bin/ace` wrapper exists + is executable. (4) `ace/.env` exists and has `OPENAI_BASE_URL=http://litellm:4000/v1` so calls route through LiteLLM (free Phoenix tracing). (5) `ACE_LITELLM_KEY` from `.env` is non-empty AND accepted by LiteLLM's `/v1/models`. Skipped cleanly when `ace/` doesn't exist (Phase 17 not selected). |
| Fails when | Phase 17 never ran (clone missing), `uv sync` drift left the venv stale, somebody deleted `bin/ace`, `.env` was hand-edited away from the LiteLLM base URL (so ACE would silently call `api.openai.com` instead), or the virtual key was revoked from LiteLLM's DB. |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 17` — Phase 17 is idempotent: re-uses the clone, re-runs `uv sync` (no-op if locked), re-mints the virtual key only if the existing one is rejected. |

**What this check does NOT prove.** That any eval has been run. Playbooks live under `ace/results/` and are user-state, not install-state. `bin/ace --help` lists the eval surface.

**Routing.** ACE uses the OpenAI Python SDK; `OPENAI_BASE_URL` is the canonical env-var that SDK reads to redirect every chat-completion call. Setting it to `http://litellm:4000/v1` means every LLM call from ACE — generator, reflector, curator — passes through LiteLLM and gets traced in the `ai-stack` Phoenix project for free. The `ACE_LITELLM_KEY` virtual key is scoped to the canonical local-model superset (`local, local-gemma4, local-heavy, local-lfm2, local-qwen3-coder, local-qwen3.6`) only, so even if ACE's prompts somehow request cloud models, LiteLLM rejects with HTTP 403 ("key not allowed to access model"). ACE's assigned model in `models.yml` is `local-gemma4`.

---

## 30 · Hermes profiles route to LiteLLM (provider=custom:litellm, Phase 04f)

| | |
|---|---|
| Asserts | The representative `hermes_manager` profile config has `model.provider=custom:litellm` and `providers.litellm.base_url=http://host.docker.internal:4000` (the per-profile LiteLLM routing wired by Phase 04·F), AND `HERMES_LITELLM_KEY` is accepted by LiteLLM. |
| Fails when | Phase 04·F never ran, the profile config was reverted to a non-LiteLLM provider, `host.docker.internal:4000` is unreachable, or `HERMES_LITELLM_KEY` was revoked/rotated so LiteLLM rejects it. |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 04f` — Phase 04·F is idempotent: it re-mints `HERMES_LITELLM_KEY`, re-adds the `litellm_proxy` endpoint to the hermes policy, and re-sets the per-profile `model.default` + `model.provider=custom:litellm` + `providers.litellm.{base_url,api_key,model}`. |

hermes-agent v0.15.2 has no `llm.*` config namespace — the old `llm.model` / `llm.openai_api_base` / `llm.openai_api_key` config was a dead no-op (and raised a `ValueError`), so Hermes silently never reached local models. The fix routes via the `custom:litellm` provider against `http://host.docker.internal:4000/v1`. Verified: a real `hermes --profile hermes_manager -m local -z` returned `PONG`.

---

## 31 · RLM installed + LiteLLM virtual key valid (Phase 18)

| | |
|---|---|
| Asserts | `rlm/.venv` imports `rlm`, `rlm/run_rlm.py` + `bin/rlm` exist, `rlm/.env` sets `OPENAI_BASE_URL=http://litellm:4000/v1`, and `RLM_LITELLM_KEY` is accepted by LiteLLM. |
| Fails when | Phase 18 never ran, the venv/wrapper is missing, `rlm/.env` doesn't route to LiteLLM, or `RLM_LITELLM_KEY` was revoked/rotated. |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 18` (idempotent: reinstalls `rlms`, re-mints the key, regenerates `rlm/.env` + `bin/rlm`). |

Skips cleanly (passes) when RLM was never installed (`rlm/.venv` absent) — it's optional experimental tooling. RLM's REPL runs model-generated code in a **Docker sandbox** by default (`bin/rlm`); `--env local` would run it on the host.

---

## 32 · claw3d office + stack-agents bridge healthy (Phase 19)

| | |
|---|---|
| Asserts | the bridge (`claw3d-bridge/bridge.py`, `:7780`) serves `/health` + `/state` with ≥1 agent, and the claw3d UI (`:4310`) responds. |
| Fails when | the bridge or UI isn't serving, or `/state` lists no agents. |
| Auto-fix | restarts both: `bash bin/start-claw3d-bridge.sh && bash bin/start-claw3d.sh` (or re-run `vz-ai-stack.sh install 19`). |

Skips cleanly (passes) when claw3d was never installed (`claw3d/node_modules` absent). Does NOT exercise the agents (that needs the OpenShell relay) — only the bridge contract + UI liveness.

---

## 33 · Hermes Telegram gateway running (Phase 20, @vz_hermes_controller_bot)

| | |
|---|---|
| Asserts | the native hermes gateway is running INSIDE `hermes-fleet-v1` (via `hermes gateway status`) and `TELEGRAM_BOT_TOKEN` is present in the sandbox's `~/.hermes/.env`. |
| Fails when | the gateway isn't running, the token isn't configured in the sandbox, or the gateway log shows a genuine auth error (`unauthorized`/`invalid token`/`401`). |
| Auto-fix | restarts the gateway: `bash bin/start-hermes-telegram.sh` (or re-run `vz-ai-stack.sh install 20`). |

Skips cleanly (passes) when `HERMES_TELEGRAM_BOT_TOKEN` isn't set — the gateway is an optional add-on. Makes **no external Telegram API call** and never prints the token. Two benign patterns are deliberately NOT treated as failures: the transient `409 conflict` after `run --replace` (Telegram holds the prior long-poll ~50s; self-heals) and the allowlist warning "*All unauthorized users will be denied*" (the secure-by-default lock, not an auth error). A passing check may still note "**running but LOCKED**" — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the allowlist.

---

## 34–38 · Opt-in experimental extras (Phases 21–25)

These checks pass-as-skip when the tool isn't installed (the tools are opt-in, not in `install all`), so the doctor stays green whether or not you've added them. When installed, each verifies the tool is present + runnable.

| # | Check | Asserts (when installed) | Skip-pass when |
|---|---|---|---|
| 34 | `portless` | `portless --version` runs (Node 24+ is an advisory note, not a failure — runs under Node 22) | `portless` not on PATH |
| 35 | `cmux` | `brew list --cask cmux` or `/Applications/cmux.app` present | cask/app absent (or non-macOS) |
| 36 | `skillspector` | venv CLI + `bin/skillspector` exist and `--help` runs | `skillspector/.venv` absent |
| 37 | `openagents` | `agn` resolves on PATH or under `~/.openagents` | `agn` absent |
| 38 | `lmstudio` | `lms` CLI + the OpenAI server on `:1234` + every models.yml-**assigned** lmstudio MLX slug wired into `litellm/config.yaml` (the `local-lfm2-mlx` demo is opt-in via `LMS_LOAD_LFM2=1`, not required) | `/Applications/LM Studio.app` absent |

---

## 39 · OpenShell expired-token CPU storm (+ watchdog status)

| | |
|---|---|
| Asserts | No OpenShell sandbox (`hermes-fleet-v1`, `pi-v1`) is in a live "expired-token storm" — i.e. recent container logs show no `ExpiredSignature` / reconnect-storm signature and `RestartCount` isn't climbing. Also reports whether the (warn-only-by-default) watchdog (`com.ai-stack.openshell-watchdog` launchd job) is installed and loaded. |
| Fails when | A sandbox's short-lived gateway token has expired (~8h uptime) and the in-sandbox agent is retrying its log-push gRPC with no backoff — hundreds of reconnects/second, ~36% CPU per sandbox, container restart-looping. The signature is unambiguous: the sandbox is already dead. |
| Auto-fix | None auto-applied here. The watchdog is **WARN-ONLY by default** (it halts the CPU burn and raises an alert; it does NOT delete/recreate the sandbox — that would discard in-sandbox state). Manual: `bash bin/openshell-watchdog.sh run` (detect now; recreates only if you opt in with `AI_STACK_WATCHDOG_RECREATE=1`), or recreate the affected phase (`vz-ai-stack.sh install 04` / `install 15`). **A gateway restart does NOT refresh the token — only RECREATING the sandbox mints a fresh one.** |

Skips cleanly (passes) when OpenShell / its sandboxes aren't present. The standing
backstop is the launchd watchdog installed by Phase 04 (`bin/openshell-watchdog.sh
install`, runs every 600s) — by default **warn-only**: it halts the CPU burn and
writes an alert (surfaced by check 43) rather than destroying the sandbox. This
check is the on-demand twin that surfaces a storm the watchdog hasn't swept yet and
confirms the watchdog is loaded. See
[TROUBLESHOOTING.md § OpenShell CPU storm](TROUBLESHOOTING.md) for the watchdog's
`status` / `uninstall` subcommands and the detect-only mode.

---

## 40 · Model <-> agent binding

| | |
|---|---|
| Asserts | `installer/models.yml` is valid; every model declared in `models.yml` is present in `litellm/config.yaml` and a master-key chat_ping returns 200 (an `lmstudio` model is **advisory-yellow** — never red — when LM Studio's server on `:1234` is down); no rendered-vs-declared **DRIFT** across every agent surface (the 9 Hermes profiles, Pi, DeerFlow, ACE, RLM); and each scoped virtual key's allowlist covers its agent's effective model plus the canonical superset. |
| Fails when | A `models.yml` model is missing from `config.yaml`, a non-lmstudio model fails its chat_ping, an agent's rendered config drifts from the declared (availability-gated) model, or a scoped key's allowlist doesn't cover its agent's effective model. |
| Auto-fix | `bash vz-ai-stack.sh model sync`. |

WARN-skips (does not fail) when LiteLLM is down or the Hermes OpenShell sandbox
isn't Ready — both are required to verify bindings end-to-end. See
[models.md](models.md) for the full `vz-ai-stack.sh model` workflow.

---

## 41 · Meridian — Claude subscription behind LiteLLM (opt-in)

| | |
|---|---|
| Asserts | When Meridian is enabled (`bin/start-meridian.sh`), its launchd job is loaded, the local endpoint (`127.0.0.1:3456/v1/models`) is healthy, the `*-sub` models (`claude-opus-sub-*`, `claude-sonnet-sub-*`) are served through LiteLLM, and each model's `extra_body.effort` in `config.yaml` matches the declared effort in `models.yml` (the `…-sub-{low,medium,high,xhigh,max,ultracode}` ladder isn't flattened). Lets Open WebUI (and anything behind LiteLLM) chat/code on your `claude login` OAuth with **no API key**. |
| Fails when | The launchd job is loaded but the endpoint is unhealthy, or the endpoint is healthy but the `*-sub` models aren't served / their effort drifts. |
| Advisory-green | Meridian not installed, or installed but the daemon wasn't enabled (no launchd job, port closed) — it's opt-in. Never prints a token. |

Mirrors the LM Studio check's philosophy: green unless something you clearly opted
into is genuinely broken. See [models.md](models.md) and [USER-GUIDE.md](USER-GUIDE.md)
for the Meridian setup.

---

## 42 · Agent fleet present (claude-code + pi personas, Phase 04h)

| | |
|---|---|
| Asserts | When Phase 04h has run, the full **9-role** software-engineering team (`manager`, `techlead`, `frontend_engineer`, `backend_engineer`, `ml_engineer`, `qa_test_engineer`, `reviewing_engineer`, `sre_engineer`, `incident_manager`) plus its shared skills landed on both surfaces it targets: `claude-code` (the `manager` as the main-agent persona via the `~/.claude/CLAUDE.md` @-import of the repo canonical `~/ai-stack/fleet/manager.md` — no `~/.claude` copy — the other 8 roles as subagents under `~/.claude/agents`, + `~/.claude/skills`, user-global) and `pi-v1` (`/sandbox/agents/<role>/SYSTEM.md`). Also flags un-applied updates (`*.ai-stack-new` sidecars 04h writes rather than clobbering a user-edited file). Hermes's side of the same team is covered by check 30. |
| Fails when | A role file or skill is missing on a surface where the fleet was installed, or `*.ai-stack-new` sidecars are pending review. |
| Green-skip | No install marker on either surface (04h is not part of a minimal install). |

---

## 43 · OpenShell watchdog has no pending storm/recreate alert

| | |
|---|---|
| Asserts | The watchdog (`bin/openshell-watchdog.sh`) has not left a pending alert at `installer/state/openshell-watchdog.alert`. The watchdog writes this marker when it detects an expired-token storm (default = **warn-only**, sandbox NOT deleted) or when an opt-in auto-recreate failed. |
| Fails when | A storm alert is present (a sandbox hit the expired-token storm and the watchdog halted the burn but left the sandbox for you to recreate when ready), or an opt-in `AI_STACK_WATCHDOG_RECREATE=1` recreate failed. |
| Auto-fix | None auto-applied — recreation discards in-sandbox state, so it stays a deliberate human action. Heal the flagged sandbox(es) (`vz-ai-stack.sh install 04 04f 15 20 04h`), then `rm installer/state/openshell-watchdog.alert` (or it clears on a verified auto-recreate). |

This check is the loud, visible backstop ensuring a watchdog event can never be
silent again.

---

## 44 · MemPalace verbatim-memory CLI + MCP installed (Phase 26, in `install all`)

| | |
|---|---|
| Asserts | When Phase 26 has run, the `mempalace` tool is installed (PyPI uv-tool env), the `bin/mempalace` wrapper + the `bin/mempalace-hook-*` launchers exist, the palace config is present, and — if `MEMPALACE_LITELLM_KEY` is set (the optional refiner LLM) — that key is accepted by LiteLLM's `/v1/models`. Embeddings are on-device (CoreML); there is nothing to probe for them. |
| Fails when | Phase 26 ran but the tool/wrapper/hook-launchers/palace config are missing, or `MEMPALACE_LITELLM_KEY` is set but rejected by LiteLLM. |
| Green-skip | Phase 26 hasn't run yet (a stack predating mempalace joining `install all`, or a partial/resumed install) — the check passes-as-skip so doctor stays green. |
| Auto-fix | Surfaces `bash vz-ai-stack.sh install 26` — Phase 26 is idempotent (re-uses the uv-tool env, re-writes the wrapper + hook launchers, re-validates the refiner key). |

**Backend note.** MemPalace runs on local on-device **ChromaDB** (MemPalace 3.3.5
hardcodes `ChromaBackend`). A Qdrant backend adapter is staged at
`mempalace/backend-qdrant/` but is NOT live — it's tested in an isolated venv
because `qdrant-client`'s protobuf/grpc pins break `import chromadb` if co-installed
into the mempalace tool env (so the doctor never adds it). See
[TROUBLESHOOTING.md § MemPalace](TROUBLESHOOTING.md) for the install gotchas.

---

## 45 · TUTORIAL.html and DIAGRAMS.html are in sync with their .md sources

| | |
|---|---|
| Asserts | **Tutorial:** `doc/TUTORIAL.html` is a valid in-repo artifact: exactly 7 in-page `<section id="act-…">` sections (self-contained — no chapter lives off-page); zero external `TUTORIAL.md#…` nav links (they 404 under `tutorial-serve`); every in-page `#anchor` resolves to an element `id` with no duplicate ids; and the HTML is in sync with `doc/TUTORIAL.md` (`installer/lib/build_tutorial_html.py --check`). **Diagrams:** `doc/DIAGRAMS.html` is in sync with `doc/DIAGRAMS.md` (`installer/lib/build_diagrams_html.py --check`). |
| Fails when | Either HTML page drifted from its markdown source (someone edited `.md` without regenerating), a tutorial section/anchor was dropped or duplicated, or an external `TUTORIAL.md#…` link crept back in. |
| Auto-fix | Regenerates both pages from their markdown sources: `installer/lib/build_tutorial_html.py` (overwrites `doc/TUTORIAL.html`) and `installer/lib/build_diagrams_html.py` (overwrites `doc/DIAGRAMS.html`). |

This check is **always-on** (unlike the opt-in service checks 34–38 + 44 + 49–52 + 56–61, which pass-as-skip): both HTML pages are in-repo artifacts that ship with the stack, so their integrity is a hard invariant. The tutorial validator parses real element attributes via `HTMLParser` (not a regex over the page text), so `id="…"` substrings inside code examples and attrs like `*_id` never false-positive. See [project_tutorial](../doc/TUTORIAL.md) / `installer/lib/tutorial-serve.sh` for the live ephemeral-proxy serve path. The diagrams generator (`installer/lib/build_diagrams_html.py`) parses `doc/DIAGRAMS.md` from scratch on every run — edit the `.md` and re-run to update the viewer.

---

## 46 · Agent-fleet parity across the 3 frameworks

| | |
|---|---|
| Asserts | The 9-role fleet is byte-identical where it must be across the `claude-code`, `pi`, and `hermes` frameworks: every shared skill, the Tier-1 universal operating-principles block, and each role's body match across all three. Wraps `installer/lib/check_fleet_parity.sh`. |
| Fails when | A skill, the Tier-1 block, or a role body drifted between frameworks (someone hand-edited a derived copy instead of the source, or `install 04h` wasn't re-run after a source edit). |
| Auto-fix | None directly — re-run `bash vz-ai-stack.sh install 04h` to regenerate the derived `pi/` + `claude-code/` copies from the canonical `agent-profiles/` sources, then re-run doctor. |

This check is **always-on**: the fleet source→derived sync model is a hard invariant, so any drift surfaces here regardless of which framework you run.

---

## 47 · Docker engine consistency (no split-brain)

| | |
|---|---|
| Asserts | The selected engine (`AI_STACK_DOCKER_ENGINE`) is the ONLY one the stack touches: (a) the user's **ambient** `docker context` resolves to the selected engine's socket (measured with `env -u DOCKER_HOST` so it isn't just validating doctor's own export); (b) `~/.config/openshell/gateway.env`'s `DOCKER_HOST` equals the selected socket; (c) **no** `ai-stack.managed=true` container is stranded on a different installed+running engine. |
| Fails when | Other shells use a different engine than the pinned one, `gateway.env` points at a stale socket, or managed containers are running on a non-selected engine (split-brain — e.g. you re-pinned without recreating containers). |
| Auto-fix | Re-pins `gateway.env` + `DOCKER_HOST` to the selected engine (`engine_pin`). It does **not** move/destroy containers: if managed containers are stranded elsewhere, it warns to either re-pin to where they live (`docker-engine set <that-engine>`) or do a guided recreate on the selected engine (conservative `recreate_guard` philosophy — never auto-destroyed). |

Pass-as-skip when no engine is pinned (that case is check 48's job). A missing
`gateway.env` (pre-Phase-04 / gateway not installed) is treated as "nothing to
compare" by design, so the silent-pass there is intentional.

---

## 48 · Docker engine selection present & valid

| | |
|---|---|
| Asserts | `AI_STACK_DOCKER_ENGINE` is set, is a valid id (`orbstack` \| `docker-desktop` \| `colima` \| `podman`), and the selected engine is still installed on the host. |
| Fails when | The var is empty (selection never ran — fresh box, or `.env` nuked), names an unknown id, or names an engine that has since been uninstalled. |
| Auto-fix | Runs the interactive selector (`engine_select`) → `engine_ensure` (install-if-missing + start) → `engine_pin`. Non-interactively, set it first with `vz-ai-stack.sh docker-engine set <id>` (or `--engine <id>`). |

This is the foundational engine check: 47 (consistency) pass-as-skips until 48 is
green, so fix 48 first. See [PREREQUISITES.md](PREREQUISITES.md) for the engine matrix
and the `docker-engine` subcommand.

---

## 49 · Sourcegraph fleet MCP wired (opt-in)

Graceful by design — skip-clean (pass) when Sourcegraph isn't installed (no `~/.sourcegraph-local/sg-token`), so it never red-bars a stack that didn't opt into code search. When SG IS installed it checks, fast: the `sourcegraph_mcp` network-policy stanza is present in `openshell/policies/hermes-fleet-v1.yaml` (drift guard — the 04_openshell.sh heredoc regenerates that file, and a stanza-less copy would silently drop fleet→SG reachability on the next `install 04`), and — if a Hermes fleet sandbox is Ready — that `hermes_manager` actually carries the `mcp_servers.sourcegraph` stanza (fleet wired). With `--all` / `OPENSHELL_DOCTOR_SLOW=1` it adds a LIVE probe: the sandbox can reach SG through the landlock (not `policy_denied`) and SG's MCP `initialize` returns HTTP 200 with the token. It never uses `hermes mcp test` (verified buggy against this SG — its probe sends a malformed `Accept` and 400s). Fix: `vz-ai-stack.sh install sourcegraph` (deploy + bootstrap + wire), or `install 04f` (wire an existing fleet), or `install 04` (re-apply the policy stanza if the LIVE policy lacks it).

---

## 50 · AionUi WebUI healthy + LiteLLM key valid (opt-in)

Graceful by design — skip-clean (pass) when AionUi's Phase 28 hasn't run (no `installer/state/phase_28*.done` stamp), so it never red-bars a stack that didn't opt into the AionUi Cowork workspace. When installed it checks: the `aionui` desktop cask is present; the prebuilt `aionui-web` binary exists; the WebUI daemon serves HTTP 200 on the loopback `:25808`; and the minted `AIONUI_LITELLM_KEY` validates against LiteLLM `/v1/models` (gated on LiteLLM reachable + 503-aware so a down key-store reads as "heal the DB", not "bad key"). Fix: `vz-ai-stack.sh start aionui` or `install 28` (both idempotent).

---

## 51 · OpenWork daemon healthy + LiteLLM key valid (opt-in)

Graceful by design — skip-clean (pass) when OpenWork's Phase 29 hasn't run (no `installer/state/phase_29*.done` stamp), so it never red-bars a stack that didn't opt into the OpenWork Cowork workspace. When installed it checks: the `openwork` orchestrator binary resolves on PATH / npm-global and `--version` runs; the seeded `~/.openwork-stack/opencode.json` exists; the headless daemon serves HTTP 200 on the loopback `:8787/health`; and the minted `OPENWORK_LITELLM_KEY` validates against LiteLLM `/v1/models` (gated on LiteLLM reachable + 503-aware). Fix: `vz-ai-stack.sh start openwork` or `install 29` (both idempotent). First start downloads the OpenCode sidecars — give it a minute before re-checking.

---

## 52 · understand-mcp answers a real graph query (opt-in)

Graceful by design — skip-clean (pass) when Understand-Anything's Phase 30 hasn't run (no `installer/state/phase_30*.done` stamp), so it never red-bars a stack that didn't opt into codebase knowledge graphs. When installed it verifies the plugin core is built (`~/.understand-anything-plugin/packages/core/dist`) and the `understand-mcp` shim deps are present. If a knowledge graph is committed (`.understand-anything/knowledge-graph.json`) it runs a TRUE end-to-end query — `project_summary` through the real `@understand-anything/core` code path — and surfaces graph staleness (graph commit vs HEAD) plus the http daemon's health on `:7081`. If no graph is committed yet it passes with an actionable note (run `/understand .` from the MAIN checkout and commit the graph) rather than red-barring. Fix: `vz-ai-stack.sh install understand` (rebuilds the plugin core + shim, re-registers the stdio MCP, restarts the daemon).

---

## 53 · Every stack container that EXISTS is running & healthy

The census/liveness axis — distinct from check 12 (ownership: foreign/adopt) and check 16 (connectivity: on the ai-stack network). It exists because per-feature checks are a curated allowlist, not a census: a container nobody wrote a check for (or whose check probes config, not liveness) can die invisibly. This was the gap that let `autofyn-agent` crash-loop and `llm_guard` die for hours while doctor reported all-green.

| | |
|---|---|
| Asserts | Every stack-owned container that EXISTS is running and not broken. **Census** = union of the `ai-stack.managed=true` label, membership of the `ai-stack` network, and the compose-project set DERIVED from `services.yml` (`type: compose`/`docker-compose` → `project:` or basename of `path:`) ∪ a hardcoded floor. `openshell-*` is excluded (owned by checks 24/39/43). |
| Fails when | Any owned container is `restarting` (crash-loop), `exited`/`dead`, or `unhealthy` (healthcheck failing). Names each broken container + its state. |
| Auto-fix | **None** (conservative). A crash-loop almost always needs a real fix (e.g. a bind-mounted source drifted behind its image) — auto-restarting would re-mask the failure. Surfaces `docker logs <name> --tail 50` / `docker restart <name>` guidance, and reminds you to use `docker ps -a` (an OOM-killed container exits and vanishes from plain `docker ps`). |
| Scope | Covers containers that EXIST but are broken. Does **not** yet assert a full expected-set (a service that never started at all) — stated follow-up. |

Smoke: `vz-ai-stack.sh test 53` — 10 cases covering every census signal + every broken state (exited/restarting/unhealthy) + negatives (healthy, starting-grace, foreign, openshell).

---

## 54 · OpenShell gateway up on :17670 & brew-manageable

Two gaps no other check covered. The gateway is a **host launchd process, not a container**, so the container-liveness census (check 53) explicitly excludes `openshell-*` and never sees it; check 39 only catches the in-sandbox token-storm. And recent Homebrew **refuses to load a formula from an untrusted third-party tap** (`nvidia/openshell`), so `brew services list` silently omits openshell even when its formula + launchd plist are installed and the gateway is running — which is why Phase 04 prints `openshell is not registered as a brew service` while the gateway works fine. This check makes both visible.

| | |
|---|---|
| Asserts | The openshell binary is installed → the gateway port (`:17670`) is **listening** AND openshell is **manageable via brew services** (so engine-switch restart + crash recovery work). Pass-as-skip when openshell isn't installed. |
| Fails when | (a) **DOWN** — nothing listening on `:17670` (the fleet can't run); or (b) **UP but unmanageable** — `brew services` can't see openshell, because the `nvidia/openshell` tap is untrusted (Homebrew won't load the formula) or there's no brew service at all (uv/pipx install). In the untrusted case the gateway still WORKS (DEGRADED, not an outage), so this is a *latent* failure surfaced as a red — the harness has no WARN state, and a green here would re-create the "doctor doesn't detect it" blind spot. |
| Auto-fix | **None — by design.** The remediation for the untrusted-tap case is `brew trust nvidia/openshell`, which tells Homebrew to load and **execute** that tap's arbitrary Ruby — a security-posture change (team-protocol §5). It must be a human decision, never auto-healed. The diagnose detail prints the exact command (and the brew-independent `launchctl bootstrap` fallback for a down gateway). |
| Note | This is the check behind the install-time warning users asked about: the warning is informational (the gateway can still be up), but it means brew-managed lifecycle is off. Run `brew trust nvidia/openshell` to restore it, then this check goes green. |

Smoke: `vz-ai-stack.sh test 54` — 8 hermetic cases (stubs `port_listening`/`brew`): not-installed skip, up+manageable green, up+untrusted red, up+no-service red, down+untrusted red, down+manageable red, up+brew-absent red, up+stopped green.

---

## 55 · Codex bridge — GPT-5.x on your ChatGPT subscription (opt-in)

The OpenAI analog of check 41 (Meridian). Opt-in + **ToS-gray**. Lets Open WebUI
(and anything behind LiteLLM) chat on your `codex login` OAuth with no metered key:
Open WebUI → LiteLLM → codex-bridge (host `127.0.0.1:3457`) → ChatGPT backend. See
[`bin/start-codex-bridge.sh`](../bin/start-codex-bridge.sh).

| | |
|---|---|
| Asserts | When the bridge is enabled (`bin/start-codex-bridge.sh install`), its launchd job is loaded, the local endpoint (`127.0.0.1:3457/v1/models`) is healthy, and LiteLLM serves the `openai-gpt-5.*-sub` models. Liveness uses the free `/v1/models` surface (no ChatGPT quota); a real-completion auth probe is **opt-in only** (`CODEX_BRIDGE_DEEP_CHECK=1`) so a routine `doctor` never spends your rate-limited window. Never prints a token. |
| Fails when | The launchd job is loaded but the endpoint is unhealthy (common cause: ChatGPT OAuth expired — re-run `npx --yes @openai/codex login`, then `start-codex-bridge.sh restart`), or the endpoint is healthy but the `openai-gpt-5.*-sub` models aren't served by LiteLLM (recreate LiteLLM to reload config). |
| Advisory-green | Bridge not installed, or installed but the daemon wasn't enabled (no launchd job, port closed) — it's opt-in. Never prints a token. |
| Note | ⚠ Unlike Meridian (Anthropic's **official** SDK), this wraps the ChatGPT **product** backend (`chatgpt.com/backend-api/codex`) — unofficial use, **single personal account only**, real account-suspension risk. The metered `openai-gpt-5.5`/`5.4` (`OPENAI_API_KEY`) path is the supported default; the bridge only avoids metered cost. |

Mirrors check 41's philosophy: green unless something you clearly opted into is
genuinely broken. See [models.md](models.md) for setup + the full risk disclosure.

---

## 56 · Bare-hostname ingress http(s)://name/ (opt-in, Phase 31)

Graceful by design — a no-op [skip] when the host-native Caddy isn't installed (no `caddy` binary) OR its launchd daemon isn't loaded (`system/com.ai-stack.ingress`), so it never red-bars a stack that didn't opt into port-free `http(s)://litellm/`. When the daemon IS loaded the user opted in, so a broken bind is a real regression: it proves there is **no OrbStack `*:80` collapse** by asserting two services answer on their **own** socket IP — it `curl`s `litellm` resolved to `127.0.10.1` and `phoenix` resolved to `127.0.10.2` and checks `%{local_ip}` matches the expected per-service IP (which holds even if the upstream container is down — a 502 still connects to the right IP). Makes **no external network calls** (loopback only). Fails when the per-IP isolation is gone (`ingress :80 not isolated per-IP (litellm->…, phoenix->…; expected 127.0.10.1 / 127.0.10.2)`). Fix: `vz-ai-stack.sh ingress up` (bring up / repair the ingress), then `vz-ai-stack.sh ingress trust` to trust the local CA for `https://`.

---

## 57 · MetaGPT venv + scoped LiteLLM key (opt-in, Phase 32)

Graceful by design — pass-as-skip when MetaGPT's Phase 32 hasn't run (no `installer/state/phase_32*.done` stamp), so it never red-bars a stack that didn't opt into the host-venv multi-agent software-company sim. When installed it requires: the venv with the `metagpt` entrypoint (`metagpt/.venv/bin/metagpt`), `import metagpt` succeeding in that venv, the `bin/metagpt` wrapper, and the scoped `METAGPT_LITELLM_KEY` actually listing models against LiteLLM `/v1/models` (a stale/revoked key returns `200` + empty `data[]`, so the check requires a real `"id"`). A down key-store DB is reported as "heal the DB (check 05a)", **not** "re-mint" — re-minting against a dead DB just fails (`LiteLLM key-store DB is DOWN — heal it …; do NOT re-mint`). Fix: `vz-ai-stack.sh install 32` (rebuild venv + re-mint scoped key + refresh `bin/metagpt`).

---

## 58 · AgentScope venv + scoped LiteLLM key (opt-in, Phase 33)

Graceful by design — pass-as-skip when AgentScope's Phase 33 hasn't run (no `installer/state/phase_33*.done` stamp), so it never red-bars a stack that didn't opt into the host-venv multi-agent simulation framework. When installed it requires: the venv (`agentscope/.venv/bin/python`), `import agentscope` succeeding in that venv, the `bin/agentscope` wrapper, and the scoped `AGENTSCOPE_LITELLM_KEY` listing models against LiteLLM `/v1/models` (a stale/revoked key returns `200` + empty `data[]`, so it requires a real `"id"`). A down key-store DB reads as "heal the DB (check 05a)", **not** "re-mint". The optional **Studio web GUI** (host `:5275`) is probed **only when enabled** — keyed off the launchd plist `~/Library/LaunchAgents/com.ai-stack.agentscope-studio.plist` (written by Phase 33 only with `AGENTSCOPE_STUDIO=1`, removed on uninstall — NOT the `.env` flag, which is an install-time input); lib-only stacks have no plist, skip the probe, and pass. When Studio is on it must return HTTP 200 on `http://127.0.0.1:5275/` or the check fails (`Studio GUI … returned HTTP <code>`). Fix: `vz-ai-stack.sh install 33` (rebuild venv + re-mint scoped key + refresh `bin/agentscope`), and `bash bin/start-agentscope-studio.sh install` to (re)start the Studio daemon when it's enabled.

---

## 59 · OASIS venv + scoped LiteLLM key (opt-in, Phase 34)

Graceful by design — pass-as-skip when OASIS's Phase 34 hasn't run (no `installer/state/phase_34*.done` stamp), so it never red-bars a stack that didn't opt into the host-venv large-scale social-agent swarm sim. When installed it requires: the venv (`oasis/.venv/bin/python`), `import oasis` succeeding in that venv, the `bin/oasis` wrapper, and the scoped `OASIS_LITELLM_KEY` listing models against LiteLLM `/v1/models` (a stale/revoked key returns `200` + empty `data[]`, so it requires a real `"id"`). A down key-store DB reads as "heal the DB (check 05a)", **not** "re-mint" (re-minting against a dead DB fails). Fix: `vz-ai-stack.sh install 34` (rebuild venv + re-mint scoped key + refresh `bin/oasis`); prove the swarm with `vz-ai-stack.sh test 34`.

---

## 60 · ChatDev web app on :5274 + scoped LiteLLM key (opt-in, Phase 35)

Graceful by design — pass-as-skip when ChatDev's Phase 35 hasn't run (no `installer/state/phase_35*.done` stamp), so it never red-bars a stack that didn't opt into the containerized multi-agent software-company web app (Vue frontend `:5274` + FastAPI backend `:6400`, both on the `ai-stack` bridge). When installed it requires, in order: the derived image `ai-stack/chatdev:local` built, both the `chatdev-backend` and `chatdev` (frontend) containers running, the frontend serving HTTP 200 at `http://127.0.10.18:5274/` (explicit `^200$` grep — not the `http_ok` helper, which has the documented `000`-concat false-healthy bug), and the scoped `CHATDEV_LITELLM_KEY` listing models against LiteLLM `/v1/models` (a stale/revoked key returns `200` + empty `data[]`, so it requires a real `"id"`). A 503 `no_db_connection` reads as "heal the DB (check 05a)", **not** "re-mint"; if LiteLLM is simply unreachable it says so rather than blaming the key. Fix: `vz-ai-stack.sh start chatdev` (idempotent (re)build + (re)start) or `vz-ai-stack.sh install 35`; prove the swarm with `vz-ai-stack.sh test 35`.

---

## 61 · AI Town compose stack + frontend :5273 + scoped LiteLLM key (opt-in, Phase 36)

Graceful by design — pass-as-skip when AI Town's Phase 36 hasn't run (no `installer/state/phase_36*.done` stamp), so it never red-bars a stack that didn't opt into the watchable virtual-town agent sim (a self-contained Convex **docker-compose** project `aitown`: backend + frontend + dashboard). **Liveness-only** (per the no-cold-start rule): it never cold-starts or blocks on a slow Vite build; it only red-bars when the phase stamp exists and the stack is genuinely down/broken or the key is bad. When installed it requires: `ai-town/docker-compose.yml` present, the docker daemon reachable, all 3 compose members running (`docker compose -p aitown ps --status running` ≥ 3), the frontend serving HTTP 200 at `http://127.0.10.19:5273/` (explicit `^200$` grep — not `http_ok`), and the scoped `AITOWN_LITELLM_KEY` listing models against LiteLLM `/v1/models` (a stale/revoked key returns `200` + empty `data[]`, so it requires a real `"id"`; loopback `127.0.0.1:4000` is probed first, falling back to the `litellm:4000` alias). A down key-store DB reads as "heal the DB (check 05a)", **not** "re-mint". Note: AI Town's containers are bridge-exempt (no `ai-stack` bridge / managed-as-docker-run signal), so check 53's container-liveness census sees them only via the `project: aitown` compose signal. Fix: `vz-ai-stack.sh start aitown` (bring the compose stack up — first build is heavy) or `vz-ai-stack.sh install 36`; prove the wiring with `vz-ai-stack.sh test 36`.

---

## Exit codes

`bash vz-ai-stack.sh doctor` exit codes:

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
