# Doctor — checks reference

`bash vz-ai-stack.sh doctor` runs all 84 checks and, when one fails, prints the
failure detail plus remediation. This doc lists every check, what it asserts,
when it fails, and what the fix does.

**The auto-fix prompt is gated on CAPABILITY, not on a fix merely existing**
(changed 2026-07-16). 81 of the 84 checks ship a `<name>_fix`, but most only
PRINT guidance — the house convention. Doctor used to offer *"Auto-fix
available. Apply? [Y/n]"* for any check with a fix function (`declare -F`), so
the operator answered `y`, nothing ran, and doctor reported *"fix ran but the
check still fails"* (the 74/76 incident). A fix must now declare
`FIX_CAPABLE[<name>]=1` to be offered. Three classes:

| Class | Count | Behavior on failure |
|---|---|---|
| **CAPABLE** (`FIX_CAPABLE=1`) | 19 | Prompts *"Auto-fix available. Apply? [Y/n]"* — answering `y` really mutates, then re-verifies. Skipped under `NO_PROMPT=1`. |
| **AUTOHEAL** (`AUTOHEAL=1`, implies capable) | 2 | Safe + idempotent → applied AUTOMATICALLY, no prompt (`05a` litellm_keystore, `73` hermes_workspace_pair). Skipped under `NO_PROMPT=1`. |
| **ADVISORY** (unmarked — the DEFAULT) | 60 | No prompt. Prints `Manual step required:` + the guidance. An unmarked check fails SAFE, so a new check can never over-promise a fix it cannot perform. |

The 21 capable checks (19 + the 2 autoheal) are the only ones that can change
your system from a doctor run.

Run filtered:

```bash
stack doctor                    # all 83
stack doctor phoenix            # only checks whose name contains "phoenix"
stack doctor network            # only the network/alias checks (14–22)
stack doctor unsloth            # only the Unsloth Studio check (23)
stack doctor pi                 # only the Pi sandbox + virtual key checks (24-26)
stack doctor lumen              # only the Lumen MCP check (27)
stack doctor openshell          # both OpenShell checks: CPU-storm (39) + gateway liveness (54)
NO_PROMPT=1 stack doctor        # no mutation: skips every capable/autoheal fix.
                                # Advisory guidance is still PRINTED (those bodies
                                # only print), so it stays effectively report-only.
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
├── 61_aitown.sh                             (opt-in Phase 36; AI Town compose stack + frontend :5273 + scoped key — pass-as-skip)
├── 62_audit_drift.sh                        (core; bin/audit.sh in sync with its 04g generator heredoc)
├── 63_loopback_publish.sh                   (core; every managed container publishes loopback-only (no 0.0.0.0/[::]))
├── 64_hostname_alias_coverage.sh            (core; services.yml hostname open_urls all have aliases.tsv rows)
├── 65_models_console.sh                     (core; Model & Agent Console (models-serve) present + wired)
├── 66_concordia.sh                          (opt-in Phase 37; Concordia venv + scoped key — pass-as-skip)
├── 67_hermes_slack.sh                       (Phase 38; Hermes Slack gateway running (Socket Mode))
├── 68_hermes_gateway_config.sh              (Hermes gateway config complete + self-heal from host snapshot)
├── 69_autofyn_agent.sh                      (opt-in; AutoFyn agent healthy — /workspace-shadow ImportError self-heal)
├── 70_corp_ca.sh                            (corporate TLS-interception readiness (Zscaler CA trust))
├── 71_rendered_artifact_routability.sh      (bin wrappers + deerflow picker route to real LiteLLM models)
├── 72_no_glued_multibyte_var.sh             (no bare $var glued to a multibyte char in shell code (${var} required))
├── 73_hermes_workspace_pair.sh              (Phase 05; Hermes Workspace <-> agent netns pair intact + self-heal)
├── 74_fleet_memory_mcp.sh                   (opt-in Phase 39; claude-cli + hermes-fleet memory MCP wiring)
├── 75_honcho_mcp.sh                         (default-on Phase 40; Honcho memory MCP shim wired + raw :8000 egress retired)
├── 76_falkordb_mcp.sh                       (opt-in Phase 41; FalkorDB graph memory MCP shim wired + raw :6379 denied)
├── 77_embedding_dim_consistency.sh          (embedding dim consistency: live store dim == assigned-model dim; skip-clean when a store is absent; opt-in DEEP round-trip)
├── 78_verify_then_stamp_guard.sh            (static source-shape guard: phases 39/40/41 keep the verify-then-stamp shape; skip-clean when the phase files are absent)
├── 79_fix_capable_integrity.sh              (mechanical FIX_CAPABLE marker integrity: no orphan markers, AUTOHEAL ⊆ FIX_CAPABLE, every unmarked _fix is print-only)
├── 80_halo_drift.sh                          (bin/halo default model in sync with its 11_halo_autoreason.sh generator — install can't dirty git with a stale wrapper)
├── 81_litellm_config_canonical.sh            (litellm/config.yaml committed in yq-canonical form — a model render can't dirty git with a comment/whitespace reindent)
├── 82_anon_volume_orphans.sh                 (dangling anonymous docker volume census ≤5 — leaked mask-guards/sandbox homes; advisory, points at cleanup --docker)
└── 83_pipefail_grep_epipe_guard.sh           (no racy `producer | grep -q` pipelines under pipefail — yq/docker-logs/awk-mid-pipe EPIPE class; advisory static guard)
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
| Asserts | `ollama` binary on PATH; `/api/tags` 200; the lazy `REQUIRED_MODELS` set — `nemotron-3-nano:4b` (`local`, the default) + `nomic-embed-text` — both installed (matches either bare name or `:latest`-tag variant). |
| Fails when | Ollama isn't running, or someone `ollama rm`'d a required model, or the model never finished downloading. |
| Auto-fix | `brew services start ollama`; `ollama pull` per missing model. On partial-pull (download corrupted), `ollama rm` first then retry. |

Note: per the local-model policy (operator directive 2026-07-01, `01_inference.sh`), only `nemotron-3-nano:4b` + `nomic-embed-text` are eager-pulled — nemotron is the ONLY local chat model (`local`, `local-heavy`, `local-nemotron3-nano-4b` all map to it), and no gemma4/qwen model is pulled by install or doctor. `OLLAMA_KEEP_ALIVE=30m` (Phase 00) keeps the default model warm for 30 min of inactivity, then releases it.

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

## 25 · pi-v1 network policy: LiteLLM/docs-mcp/honcho-mcp/falkordb-mcp reachable; raw Honcho :8000 + raw FalkorDB :6379 + ai-stack DBs denied

| | |
|---|---|
| Asserts | From inside the `pi-v1` sandbox, the allowlisted destinations respond with any HTTP code that is NOT a proxy-deny: `host.docker.internal:4000` (LiteLLM) and `:8765` (docs-mcp) ALWAYS; plus `:7082` (honcho-mcp shim) and `:7083` (falkordb-mcp shim) **only when that opt-in shim is actually listening on the host** (Phase 40/41 — the egress stanza is additive, so a box without the shim must not false-fail). The OpenShell egress proxy emits HTTP 403 with body `{"error":"policy_denied"}` when refusing; the check greps that signature to distinguish "destination reached" from "destination denied". By default only positive probes run (~6–8s). With `OPENSHELL_DOCTOR_SLOW=1` (or `DOCTOR_ALL=1`) it also runs 10 negative probes against denied destinations — those must all return the `policy_denied` signature. It additionally asserts `pi-memory-tools.ts` (slice 2b) is present in `/sandbox/.pi/extensions/` — the egress is only useful if the extension that consumes it is installed. |
| Fails when | An allowlisted host returns `policy_denied` (policy file edited but not re-applied — the common case; sandbox restarted with a stale policy; LiteLLM lost its 127.0.0.1:4000 dual-bind). In slow mode: a denied destination returns something OTHER than `policy_denied` — a policy leak (e.g. raw Honcho `:8000` or raw FalkorDB `:6379` became reachable). Or the memory extension is missing from the sandbox. |
| Auto-fix | Surfaces `openshell policy set pi-v1 --policy openshell/policies/pi-v1.yaml --wait` for the apply case, `bash vz-ai-stack.sh install 15` for a missing extension, and CHANGELOG 2026-05-29 (host.docker.internal dual-bind) for the LiteLLM case. |

**The deliberate asymmetry this check proves** (slice 3 + 2b, §24): the RAW datastores stay DENIED — `:8000` Honcho (whose REST API runs `AUTH_USE_AUTH=false`) and `:6379` FalkorDB — while their **token-gated shim ports** (`:7082`, `:7083`) are ALLOWED. Pi reaches turn/graph memory ONLY through the shims, which require a Bearer token that `bin/pi` injects; a token-less pi simply gets fewer tools.

**What this check does NOT prove**: honcho peer-level isolation. The shim forwards a caller-chosen `peer`, and honcho v3 has no API-key-scoped peer enforcement — so a compromised Pi can still read or write another agent's turns *through the shim*. The peer namespace is a write-side convention, not a read-side authorization; the FULL-SHARED memory pool is an operator-accepted property. What retiring the `:8000` egress DID remove is unauthenticated direct REST access to the entire honcho API surface.

---

## 26 · LiteLLM virtual key PI_LITELLM_KEY enforces model allowlist server-side

| | |
|---|---|
| Asserts | (1) `PI_LITELLM_KEY` is present in `.env`. (2) `GET http://litellm:4000/v1/models` with the virtual key returns exactly the canonical superset `local,local,local-heavy,local,local,local` (sorted) — every scoped key is minted against this fixed superset so `model assign`/`sync` can re-point Pi without re-minting. (3) `POST /v1/chat/completions` with `model=claude-opus` returns a body containing the case-insensitive substring `"key not allowed"`. The substring match (rather than the full message) makes the check resilient to LiteLLM's wording across minor versions. |
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

**Routing.** ACE uses the OpenAI Python SDK; `OPENAI_BASE_URL` is the canonical env-var that SDK reads to redirect every chat-completion call. Setting it to `http://litellm:4000/v1` means every LLM call from ACE — generator, reflector, curator — passes through LiteLLM and gets traced in the `ai-stack` Phoenix project for free. The `ACE_LITELLM_KEY` virtual key is scoped to the canonical local-model superset (`local, local-heavy`) only, so even if ACE's prompts somehow request cloud models, LiteLLM rejects with HTTP 403 ("key not allowed to access model"). ACE's assigned model in `models.yml` is `local`.

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
| Asserts | `installer/models.yml` is valid; every model declared in `models.yml` is present in `litellm/config.yaml` and a master-key chat_ping returns 200 (an `lmstudio` model is **advisory-yellow** — never red — when LM Studio's server on `:1234` is down); every declared **`effort:` round-trips into the rendered route** (`extra_body.effort` for `meridian`, `reasoning_effort` for `openai`/`codex-bridge` — see below); no rendered-vs-declared **DRIFT** across every agent surface (the 9 Hermes profiles, Pi, DeerFlow, ACE, RLM); and each scoped virtual key's allowlist covers its agent's effective model plus the canonical superset. |
| Fails when | A `models.yml` model is missing from `config.yaml`, a non-lmstudio model fails its chat_ping, a declared `effort:` is absent from or differs in the rendered route, an agent's rendered config drifts from the declared (availability-gated) model, or a scoped key's allowlist doesn't cover its agent's effective model. |
| Auto-fix | `bash vz-ai-stack.sh model sync`. |

WARN-skips (does not fail) when LiteLLM is down or the Hermes OpenShell sandbox
isn't Ready — both are required to verify bindings end-to-end. See
[models.md](models.md) for the full `vz-ai-stack.sh model` workflow.

**The effort round-trip.** A `models.yml` `effort:` reaches the route in a runtime-specific
shape: `litellm_params.extra_body.effort` for `meridian` (LiteLLM merges `extra_body` into the
request body, which Meridian reads), `litellm_params.reasoning_effort` for `openai` /
`codex-bridge` (LiteLLM's first-class param). Every writer **reassigns `litellm_params` to a
fresh map**, so any argument a *caller* omits is silently **deleted** from the route — the
model still answers, just at the provider's default reasoning level. Nothing else in the stack
notices.

The check asserts **two layers**, because they fail independently:

1. **The file** (`litellm/config.yaml`) — what LiteLLM will serve after its next restart.
   Remedy: **`bash vz-ai-stack.sh model sync`**. Note this is *not* `install inference` —
   Phase 01 self-gates on its own stamp and exits before it would ever re-register.
2. **The running proxy** (`GET /model/info`, static route metadata — no inference, no
   cold-start) — what it serves *right now*. LiteLLM reads config at **boot**, and Phase 01
   deliberately does not restart a healthy serving container, so "file repaired, proxy stale"
   is a real state that a file-only assertion would green. Remedy:
   `bash bin/start-litellm.sh --recreate`.

Historically only the **meridian** half was guarded, by check 41 — which is *runtime*-scoped
(it skips every non-meridian model), **not** gated on Meridian being enabled; its effort clause
runs regardless of daemon state. That one-sided coverage is how `openai-gpt`'s declared
`effort: xhigh` stopped being served while `models.yml` still advertised it. The degraded state
is **born at install time**: `install inference` rewrites those rows and strips effort, and
`model sync` is never auto-run by install — so a fresh `install all` produces it and nothing
restores it until an operator syncs. (The *tracked* `config.yaml` has never been wrong.)
A declared `effort:` on a runtime that renders none (e.g. `ollama`) is an **advisory** — the
declaration is inert, not broken.

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

## 62 · bin/audit.sh in sync with its 04g generator heredoc (core)

`bin/audit.sh` is GENERATED by a `cat > bin/audit.sh <<'EOF' … EOF` heredoc in `installer/phases/04g_security.sh` — the two must stay byte-identical, because a fix applied to one but not the other silently ships a stale security smoke test (and a later `install 04g` would clobber any hand-edit to `bin/audit.sh`). This check extracts the heredoc body and diffs it against the committed `bin/audit.sh`, failing on drift. Pure file comparison — no external calls. Pass-as-skip if either file is missing. Fails when (a) the heredoc can't be located in `04g_security.sh` (the generator changed shape — update this check), or (b) the extracted body and `bin/audit.sh` differ (`bin/audit.sh DRIFTED from its 04g_security.sh generator heredoc`). Fix: apply the intended change to **both** (keep them byte-identical), or re-run `vz-ai-stack.sh install 04g` to regenerate `bin/audit.sh` from the heredoc (this DISCARDS any hand-edit to `bin/audit.sh`).

---

## 63 · Containers publish loopback-only (no 0.0.0.0/[::]) (core)

The routine-doctor version of `bin/audit.sh` check 1: asserts no running container publishes a port on `0.0.0.0` or `[::]` (all-interfaces LAN exposure) — stack policy is loopback-only (`127.0.0.1` / `127.0.10.x`). Skip-clean when the docker engine is unreachable (nothing to assert), so it never red-bars a box with the engine down. Catches upstream-compose drift that the on-demand `audit.sh` would miss — an upstream image whose compose republishes on all interfaces gets surfaced on the next routine `doctor` rather than only when someone runs the audit by hand. Fails when a running container is found publishing on `0.0.0.0`/`[::]`. Fix: dual-bind the offending publish to the loopback alias (`127.0.0.1` + the service's `127.0.10.x`) in the start script that patches the (gitignored) upstream compose.

---

## 64 · services.yml hostname open_urls have aliases.tsv rows (core)

Asserts every `services.yml` service whose `open_url` is a bare hostname (e.g. `http://deerflow:2026`) has a matching `installer/lib/aliases.tsv` row — the row that drives `/etc/hosts`, the `lo0` alias, and the Caddy ingress. `localhost`/IP `open_url`s are exempt (they need no alias). Guards the deerflow-class gap where a service gains a hostname `open_url` but no alias row, so the URL never resolves. Fails when a bare-hostname `open_url` has no corresponding `aliases.tsv` row. Fix: add the missing row to `installer/lib/aliases.tsv` (then `sudo vz-ai-stack.sh prepare-sudo` to activate the `/etc/hosts` + `lo0` alias), or point the service's `open_url` at `localhost`/an IP if it intentionally has no hostname.

---

## 65 · Model & Agent Console (models-serve) present + wired (core)

Asserts the `models-serve` web console (the Model & Agent Console) is present and wired so `vz-ai-stack.sh models-serve` will actually boot: `installer/lib/models-serve.sh` + `installer/lib/models_proxy.py` + `doc/MODELS.html` all exist, the proxy compiles as valid Python, `models-serve` is wired into `vz-ai-stack.sh` dispatch (lib present but unreachable verb is the regression this guards), and `installer/models.yml` parses (fail-closed — the console reads the catalog through the `model` CLI). Pure file/parse — NO cold-start, network, or container calls; deep model↔agent binding and allowlist correctness stay owned by check 40 (`models_binding`), not duplicated here. ADVISORY (WARN, never red): every `models.yml` model declaring a `key_env` should have that env var set in `.env` — a missing vendor key is surfaced as a red dot in the console and means that route 401s at call time, worth flagging but not a stack fault (a keyless local-only box is legitimate). Fails when a console file is missing, the proxy has a syntax error, `models-serve` isn't dispatched, or `models.yml` doesn't parse. Fix: restore the missing piece on branch `feat/model-console` (or `main` once merged), then serve it with `vz-ai-stack.sh models-serve` from the MAIN checkout.

---

## 66 · Concordia venv + scoped LiteLLM key (opt-in, Phase 37)

Graceful by design — pass-as-skip when Concordia's Phase 37 hasn't run (no `installer/state/phase_37*.done` stamp), so it never red-bars a stack that didn't opt into the host-venv generative-agent-based-modeling (GABM) sim. When installed it requires: the venv (`concordia/.venv/bin/python`), both `import concordia` and `import sentence_transformers` succeeding in that venv (the latter is Concordia's mandatory associative-memory embedder), the `bin/concordia` wrapper, and the scoped `CONCORDIA_LITELLM_KEY` listing models against LiteLLM `/v1/models` (a stale/revoked key returns `200` + empty `data[]`, so it requires a real `"id"`), plus an allow-list assertion that the key permits the model Concordia is bound to (`models.yml` `.assignments.concordia`, else the default `claude-sonnet-sub-high`). A down key-store DB reads as "heal the DB (check 05a)", **not** "re-mint" (re-minting against a dead DB fails). Fix: `vz-ai-stack.sh install 37` (rebuild venv + re-mint scoped key + refresh `bin/concordia`); prove the sim with `vz-ai-stack.sh test 37`.

---

## 67 · Hermes Slack gateway running (Phase 38, Socket Mode)

| | |
|---|---|
| Asserts | the Slack role router is running INSIDE `hermes-fleet-v1`, `/sandbox/.hermes-slack/health.json` is fresh with `connected=true` for the live pid, and BOTH `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` are present in the sandbox's `~/.hermes/.env`. |
| Fails when | the router isn't running, health is missing/stale/pid-mismatched, either token isn't configured in the sandbox, the router log shows a genuine Slack auth/API error (`invalid_auth` / `token_revoked` / `token_expired` / `missing_scope` / `not_allowed_token_type`), or it shows blocked egress (`policy_denied`) — a Slack host missing from the Phase 04 `slack` policy. |
| Auto-fix | self-heals by re-running Phase 38 converge, which re-writes config, restarts the router, and then re-diagnoses health. |

Skips cleanly (passes) when `HERMES_SLACK_BOT_TOKEN` isn't set — Slack is an opt-in add-on (Phase 38). Makes **no external Slack API call** and never prints the tokens; it reads only in-sandbox pid, health, token-presence, and log files. Benign Socket-Mode churn (`reconnect` / `disconnect` / `ping` / `pong` / rate-limit / `429`) is filtered before matching auth errors so a healthy, reconnecting bot doesn't false-fail. A passing check may still note "**running but LOCKED**" (no allowlist → denies every user) — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) to set `HERMES_SLACK_ALLOWED_USERS`.

---

## 73 · Hermes Workspace ↔ agent netns pair intact + self-heal (Phase 05)

| | |
|---|---|
| Asserts | when the workspace is on the v0.18.0 loopback+netns model (`network_mode: service:hermes-agent` in the override), the `hermes-agent` and `hermes-workspace` containers are BOTH running. |
| Fails when | the agent is **running** but the workspace is **not** (`exited`/`dead`/`created`) — the parent-up / child-down split unique to the shared netns (a host reboot can start the netns child before the agent's namespace exists). |
| Auto-fix | `AUTOHEAL=1` — idempotent `docker compose up -d` in `hermes-workspace/` (compose starts the agent first via `depends_on`, then re-joins the workspace to its netns). Worktree-guarded, non-destructive, bounded wait. |

Skips cleanly (passes) when the workspace isn't installed or isn't on the netns model, and when the agent itself is down (that's a full-stop / general-census concern, check 53 — not the netns split). Never touches volumes.

---

## 74 · Fleet memory — claude-cli + hermes-fleet MCP wiring (opt-in, Phase 39)

| | |
|---|---|
| Asserts | when Phase 39 (`install fleet_memory`) is installed: (a) if the `claude` CLI is present, the host Claude session has BOTH memory MCPs registered (user scope) — `mempalace` (verbatim recall via the `bin/mempalace-mcp` env-injecting wrapper) and `docs-mcp` (doc-RAG `search_documents` on :8765); (b) if a `hermes-fleet-v1` sandbox is Ready, a representative fleet profile carries `mcp_servers.docs` → `host.docker.internal:8765` (fleet doc-RAG wired). |
| Fails when | a claude-cli MCP is missing from `claude mcp list`, or the fleet profile lacks the `docs` MCP server, after Phase 39 has stamped. With `FLEET_MEMORY_DEEP_CHECK=1` it additionally fails when Qdrant is unreachable or the `ai-stack-docs` collection holds **0 points** — a registered-but-empty docs-mcp answers every query with nothing. |
| Auto-fix | none (reports the command): `vz-ai-stack.sh install fleet_memory`; populate doc-RAG with `cd ingestor && python ingest.py`. |

Skips cleanly (passes) when Phase 39 isn't installed (opt-in); the claude-cli sub-check is skipped when the `claude` CLI isn't on PATH, and the hermes sub-check when no fleet sandbox is Ready. Static by default (wiring only); the corpus-population probe is opt-in behind `FLEET_MEMORY_DEEP_CHECK=1` so routine runs never touch Qdrant.

---

## 75 · Honcho memory MCP — raw :8000 egress retired + shim wired (default-on, Phase 40)

| | |
|---|---|
| Asserts | when Phase 40 (`install honcho_mcp`) is installed: **(a) SECURITY DRIFT-GUARD** — the raw auth-off `honcho_memory` (:8000) egress is GONE from the `04_openshell.sh` generator AND both committed policies (`hermes-fleet-v1.yaml`, `pi-v1.yaml`), and the `honcho_mcp` (:7082) shim stanza is PRESENT in the fleet policy; **(b)** if the `claude` CLI is present, the host session has the `honcho` stdio MCP registered; **(c)** the http shim answers on `127.0.0.1:7082/healthz`; **(d)** if a `hermes-fleet-v1` sandbox is Ready, `hermes_manager` carries the honcho MCP wired to `host.docker.internal:7082`. |
| Fails when | the raw `honcho_memory` (:8000) egress **REAPPEARS** in the generator or a policy (a regression re-opens the auth-off hole to sandboxed agents), or the `honcho_mcp` shim stanza is missing from the fleet policy, or the claude-cli `honcho` MCP is unregistered, or the shim isn't answering on :7082, or the fleet profile isn't wired — after Phase 40 has stamped. |
| Auto-fix | **advisory** (print-only — no prompt; prints the command): `vz-ai-stack.sh install honcho_mcp`; if a policy regained `honcho_memory` (:8000), revert it (it MUST stay retired) + `install 04`. |

Skips cleanly (passes) when Phase 40 isn't installed — no `phase_40*.done` stamp, i.e. the stack declined honcho memory with `HONCHO_MEMORY_OPT_IN=0` or predates the phase — so it never red-bars a stack without honcho memory. (Phase 40 is default-on under `install all --include-optionals` as of 2026-07-16; its decline path deliberately stamps nothing, which is exactly what keeps this skip-clean honest.) The claude-cli sub-check is skipped when the `claude` CLI isn't on PATH; the fleet sub-check when no `hermes-fleet-v1` sandbox is Ready. A "shim up but Honcho backend unreachable per `/healthz`" state is a NOTE, not a failure. The centerpiece is the always-on **security drift-guard**: the raw :8000 egress must stay retired so the token-gated shim remains the only in-sandbox path to Honcho.

---

## 76 · FalkorDB graph memory MCP — shim wired + raw :6379 denied (opt-in, Phase 41)

| | |
|---|---|
| Asserts | when Phase 41 (`install falkordb_mcp`) is installed: **(a) DRIFT-GUARD** — the `falkordb_mcp` (:7083) shim egress is PRESENT in the fleet policy (`hermes-fleet-v1.yaml`) AND **no** sandbox policy (`hermes-fleet-v1.yaml`, `pi-v1.yaml`) targets the raw `falkordb` :6379 endpoint; **(b)** if the `claude` CLI is present, the host session has the `falkordb` stdio MCP registered; **(c)** the http shim answers on `127.0.0.1:7083/healthz`; **(d)** if a `hermes-fleet-v1` sandbox is Ready, `hermes_manager` carries the FalkorDB MCP wired to `host.docker.internal:7083`. |
| Fails when | the `falkordb_mcp` shim egress is missing from the fleet policy, or a sandbox policy targets raw `falkordb` :6379 (sandboxes must reach the graph ONLY via the token-gated :7083 shim), or the claude-cli `falkordb` MCP is unregistered, or the shim isn't answering on :7083, or the fleet profile isn't wired — after Phase 41 has stamped. |
| Auto-fix | none (reports the command): `vz-ai-stack.sh install falkordb_mcp`; if a policy gained a raw `falkordb` :6379 endpoint, revert it (it MUST stay denied) + `install 04`. |

Skips cleanly (passes) when Phase 41 isn't installed (opt-in — no `phase_41*.done` stamp), so it never red-bars a stack that didn't opt into graph memory. The claude-cli sub-check is skipped when the `claude` CLI isn't on PATH; the fleet sub-check when no `hermes-fleet-v1` sandbox is Ready. A "shim up but FalkorDB backend unreachable per `/healthz`" state is a NOTE, not a failure. **Unlike check 75 (honcho) there is NO retired-egress to assert — slice 4 is purely additive** (FalkorDB was never fleet-reachable) — but the always-on **"no raw :6379 sandbox egress" guard** keeps it that way, so the shim stays the only in-sandbox path to the graph.

---

## 77 · Embedding dim + family consistency (canonical 768)

| | |
|---|---|
| Asserts | for every dim-pinned embedding consumer, the LIVE store's vector dim equals the dim of the embedder assigned to it in `models.yml` (`.embedding_assignments.<svc>` → `.embeddings[m].dim`). Covers **docs** (the Qdrant `ai-stack-docs` collection `vectors.size`, the deployed `ingestor/ingest.py` `EMBED_DIM` literal that populates it, the deployed `EMBED_MODEL` == the assigned route, **and the per-point embedder FAMILY STAMP** == the assigned embedder) and **honcho** (the pgvector column typmod on the base tables `documents` + `message_embeddings`, filtered `relkind='r'` so the HNSW index relations don't surface as phantom columns). |
| Fails when | a **present** store's dim disagrees with its assigned embedder — docs: `ai-stack-docs` `vectors.size` ≠ assigned dim, or the deployed `ingest.py` `EMBED_DIM` ≠ assigned dim (the next populate would write wrong-dim vectors), or `EMBED_MODEL` ≠ the assigned route; honcho: a pgvector `embedding` column dim ≠ assigned dim. **Family:** any point in `ai-stack-docs` stamped with an embedder other than the assigned one (a same-dim family re-point whose re-index was skipped), or a partially-stamped collection (mixed geometry from a partial re-index). Under `EMBEDDING_DIM_DEEP=1` (or `DOCTOR_ALL=1`) it additionally fails when a live embedder route emits a vector whose length ≠ the store dim (a store at that dim would reject every insert). |
| Auto-fix | none (reports the command): **docs (dim)** → flip `.embedding_assignments.docs` in `models.yml`, `install 06`, then recreate the collection with `AI_STACK_FORCE_RECREATE=1` ingest; **docs (family)** → `install 06` re-bakes code but never re-embeds — restore the corpus (`mv ingestor/processed/ai-stack-doc/* ingestor/inbox/ai-stack-doc/`), `AI_STACK_FORCE_RECREATE=1 .venv/bin/python ingest.py`, then `bash bin/start-docs_mcp.sh --recreate`; **honcho** → set `EMBEDDING_VECTOR_DIMENSIONS` to the assigned dim + run honcho `scripts/configure_embeddings.py --yes` (wired via `install honcho_mcp`). |

A store that is absent/unreachable is **SKIP-CLEAN** (a distinct, benign state from present-but-wrong-dim = FAIL), so an unpopulated docs collection or a stopped honcho DB never red-bars the stack. The routine run is cheap — schema / registry / code only, **no model load**. Under `EMBEDDING_DIM_DEEP=1` (or `DOCTOR_ALL=1`) it also does a live 1-vector round-trip per consumer and asserts the emitted length == store dim — this catches a route that silently emits the wrong dim (e.g. a cloud route missing its `dimensions` param) that a schema-only check would miss; the round-trip touches **embedders only, never a chat model**, and is opt-in so routine doctor never cold-starts. openwebui / lumen self-manage their own index dim, mempalace is on-device 384, and ai-town is an isolated opt-in sim — all out of scope.

**The family stamp (why dim alone was not enough).** `embed-nomic` and `embed-openai-small-768` are **both 768** but are different vector *spaces*. Re-pointing `docs` between them and running `install 06` — which re-bakes `EMBED_MODEL`, satisfying the code-drift guard — while **forgetting the re-index** left the store full of old-geometry vectors and every guard green: total, silent recall collapse. So `ingest.py` stamps the models.yml **registry key** of the embedder that produced each vector into that same point's payload (`embedder`), and this check counts, via the Qdrant `points/count` API, any point not carrying the assigned embedder. Because the stamp is written by the same call that computes the vector it cannot drift from what it describes, and because it lives inside the collection it dies with it — so a dropped/recreated store can never present a stale stamp. It is excluded from the embedded text (`excluded_embed_metadata_keys`), so it never pollutes the vector space it audits.

Stamp semantics: an **entirely unstamped** collection is **SKIP-CLEAN** (it pre-dates the stamp — re-index to arm the guard); **any wrong-family point** FAILS; a **partially stamped** collection FAILS as mixed provenance. `ingest.py` independently refuses to append a different family onto a populated collection unless `AI_STACK_FORCE_RECREATE=1` — the doctor catches a forgotten re-index, the ingester prevents a mixed corpus.

> **Scoped out, deliberately:** **honcho gets no family stamp.** It owns its embedding pipeline upstream, so stamping its writes means patching code that an upgrade overwrites. Its dim guard + its own boot validator cover the dim case; a same-dim family swap on honcho is caught only by following the re-index runbook in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#embedding-dimensionality-canonical-768--cloudlocal-interchangeability). This is a known, accepted residual — not an oversight.

---

## 78 · Verify-then-stamp shape intact in phases 39/40/41 (no-sandbox-still-stamps drift guard)

| | |
|---|---|
| Asserts | a STATIC source-shape guard (cf. check 62 `audit_drift`) — for each of phases `39_fleet_memory.sh` / `40_honcho_mcp.sh` / `41_falkordb_mcp.sh`, the verify-then-stamp SHAPE tokens are still present WITHOUT running the stack: (1) an `if sandbox_ready …` wiring-branch gate (only a Ready fleet is wired); (2) an `if _mem_hermes_<key>_wired …` POST-CONDITION gate (verify before stamp); (3) a `NOT stamping Phase` failure path followed by an `exit` before the skip-note (a wiring that did not land must NOT stamp); (4) a `not present or not Ready` genuine-skip else-branch — the opt-in RECORD that arms `04f_hermes_fleet.sh`'s `stamp_check 39/40/41` so a fleet built LATER still gets wired; (5) a TOP-LEVEL `stamp_mark "$PHASE"` fall-through that BOTH the verified AND the genuine-skip path reach; (6) ORDER — the skip-note precedes that stamp with no `exit` short-circuiting the skip path before it. Checks SHAPE, not byte-identity (the three phases legitimately differ). Pure file reads — no external calls, no cold-start. |
| Fails when | a fleet-memory phase lost the stamp gate or the no-sandbox-still-stamps invariant: a missing shape token, an `exit` between the genuine-skip note and the fall-through stamp (a no-sandbox run would no longer stamp — opt-in-survives-rebuild broken), or a `NOT stamping Phase` failure branch with no `exit` before the skip note (a wiring that did not land would fall through and STILL stamp — the exact 2026-07-16 incident). |
| Fix | print-only advice (NOT FIX_CAPABLE): restore the verify-then-stamp shape by referencing the sibling phase that still has it, then re-run `vz-ai-stack.sh test verify-then-stamp` (the companion runtime test that pins the contract). |

Skips cleanly (returns 0) when none of phases 39/40/41 is present — a genuine skip, never a red-bar. Companion: `installer/smoke/verify-then-stamp.sh` pins the CONTRACT (real helpers + real stamp → right outcome); THIS check pins that the phases still IMPLEMENT it.

---

## 79 · FIX_CAPABLE marker integrity (mutating _fix must be marked; no orphans)

| | |
|---|---|
| Asserts | the mechanical integrity of doctor's `FIX_CAPABLE` marker — enforcing at every `doctor` run the convention the 2026-07-16 council could otherwise only hand-census: (1) **no orphan markers** — every `FIX_CAPABLE[<name>]=1` maps to a registered check that actually defines `<name>_fix`; (2) **AUTOHEAL ⊆ FIX_CAPABLE** — every `AUTOHEAL[<name>]=1` also carries `FIX_CAPABLE[<name>]=1` (AUTOHEAL implies capable); (3) **no unmarked mutation** — every `_fix` that is NEITHER `FIX_CAPABLE` NOR `AUTOHEAL` must be print-only. The mutation test is a SOURCE GREP over `declare -f <name>_fix`: after blanking string literals and comments, every statement-position command word must be a known output/control builtin, and a write-redirect (`>`/`>>`) to a real file counts as mutation — anything else demands a marker. |
| Fails when | a `FIX_CAPABLE`/`AUTOHEAL` marker is orphaned (no registered check or no `_fix`), an `AUTOHEAL` entry lacks its `FIX_CAPABLE`, or an UNMARKED `_fix` appears to mutate at statement position — because `doctor.sh` RUNS an unmarked `_fix` body in EVERY mode (including `NO_PROMPT=1`), an unmarked-but-mutating `_fix` silently breaks `doc/DOCTOR.md`'s report-only contract. |
| Fix | print-only advice (NOT FIX_CAPABLE — this body must itself stay print-only, which the check verifies): if the `_fix` mutates, add `FIX_CAPABLE[<name>]=1` beside its `CHECKS+=(<name>)`; if it is advice-only, keep the body print-only; remove a stale orphan marker; give an `AUTOHEAL` entry its `FIX_CAPABLE`. |

The mutation heuristic is designed for ZERO false positives on today's print-only bodies (advice text mentioning `rm`/`docker restart` is blanked as a string; read-only getters inside `$(…)` are never scanned as statement heads). Its accepted residual — a body that mutates only via a command hidden in `$(…)`/`if <cmd>`, or a `source`d file that mutates at source time — evades a static grep; the AGENT-ONBOARDING template note is the backstop for those. It catches the realistic, template-shaped regression the council reproduced: a plain mutating command at statement position with no marker.

---

## 80 · bin/halo default model in sync with its 11_halo_autoreason.sh generator (drift guard)

| | |
|---|---|
| Asserts | the git-tracked `bin/halo` wrapper carries the SAME default model as the generator that emits it. `bin/halo` is GENERATED by an UNQUOTED `cat > … <<WRAPEOF` heredoc in `installer/phases/11_halo_autoreason.sh`, and the only value that varies is the default model — `HALO_MODEL_DEFAULT` — emitted into the wrapper's exec line as `exec "$HALO_BIN" --model "${HALO_MODEL:-<default>}" "$@"`. The check reads `HALO_MODEL_DEFAULT` from the phase and asserts the committed `bin/halo` carries the matching `${HALO_MODEL:-<value>}` default. UNLIKE check 62 (`audit_drift`) it is NOT a byte-diff of the heredoc body — the heredoc is unquoted so `${HALO_MODEL_DEFAULT}`/`$AI_STACK` expand at generation and a literal extract would never match; it asserts only the one field that drifts, with ZERO eval. Pure file reads — no external calls, no cold-start. |
| Fails when | the committed `bin/halo` default drifted from the generator (`HALO_MODEL_DEFAULT` moved but the wrapper was not re-committed) — so every `install`, which re-runs phase 11 and regenerates `bin/halo`, dirties the tree with pure noise. Exactly how the committed default went stale at `local` while the generator moved to `claude-opus-sub-xhigh` (the 2026-07-17 fix). |
| Fix | print-only advice (NOT FIX_CAPABLE): re-sync `bin/halo` to the generator's default (re-run the halo phase or edit the wrapper's `${HALO_MODEL:-…}` default) and commit it. |

Skips cleanly (returns 0) when `11_halo_autoreason.sh` or `bin/halo` is absent — a genuine skip, never a red-bar. Guards the "tracked generated artifact re-dirties on install" class (cf. check 81 for `litellm/config.yaml`).

---

## 81 · litellm/config.yaml committed in yq-canonical form (no model-render dirt)

| | |
|---|---|
| Asserts | the git-tracked `litellm/config.yaml` is a yq FIXED POINT — re-emitting it through `yq '.'` produces byte-identical output. `config.yaml` is a DERIVED artifact: `installer/phases/01_inference.sh` seeds it from `prompts/config.yaml` only if absent, then `installer/lib/models.sh` (`register_model_list`) rewrites `.model_list` via `yq -i`, which re-emits the whole document through yq's serializer and normalizes comment indentation. The check first requires the file be valid with a `.model_list[0]`, then diffs `yq '.' config.yaml` against the file on disk; an empty diff means the committed form is exactly what a model render would write. Requires `yq` (a hard host dep). Read-only — no stack, no cold-start. |
| Fails when | the committed `config.yaml` is off-canonical (e.g. a hand-edit reintroduced a 4-space indent), so the next `model sync` / `install` re-serializes it and dirties git with a comment/whitespace-only diff (zero model_list change). Fixed once at `bfc6944` and REGRESSED five days later when `fb41ce3` hand-edited the tracked artifact back to a non-canonical indent — re-commit alone cannot survive that class, so this guard makes it caught instead of silent. |
| Fix | print-only advice (NOT FIX_CAPABLE): re-canonicalize with `yq -i '.' litellm/config.yaml` and commit it. |

Skips cleanly (returns 0) when `litellm/config.yaml` is absent (install 01 seeds it) or `yq` is not on PATH (run `vz-ai-stack.sh deps`) — a genuine skip, never a red-bar. Guards the same "tracked generated artifact re-dirties on install" class as check 80.

---

## 82 · dangling anonymous docker volumes (census)

| | |
|---|---|
| Asserts | at most 5 DANGLING ANONYMOUS docker volumes exist on the selected engine (`docker volume ls --filter dangling=true --filter label=com.docker.volume.anonymous`). Anonymous volumes are minted by single-path `-v /path` mask-guards (chatdev / ai-town `node_modules`), image `VOLUME` directives, and the OpenShell supervisor's sandbox homes (the gateway strips `--label`, so those carry no ai-stack label). Since the §24 2026-07-20 hygiene round every ai-stack `docker rm` sink passes `-v` and `reset hard/nuke` diff-sweeps its own orphans — so a growing census here means a NEW leak, or another project's debris on this shared engine. Read-only; no external calls. |
| Fails when | more than 5 dangling anonymous volumes have accumulated (the pre-fix steady state was 20 ≈ 1.5 GB). |
| Fix | print-only advice (NOT FIX_CAPABLE — removal is NON-recoverable and stays operator-gated): review the itemized, HOST-WIDE list with `vz-ai-stack.sh cleanup --docker` (dry-run: size + age per volume), then reclaim with `cleanup --docker --yes` (each volume is tar-backed-up to `data/volume-backups/cleanup-<ts>/` first, fail-closed). |

Skips cleanly (returns 0) when the docker engine is not reachable — a stopped engine must never red-bar an advisory hygiene census (same idiom as check 63).

---

## 83 · no racy `producer | grep -q` pipelines (pipefail-EPIPE guard)

| | |
|---|---|
| Asserts | no single-line `yq … \| grep -q`, `docker logs … \| grep -q`, or `\| awk … \| grep -q` pipeline exists in `installer/lib`, `installer/phases`, `installer/doctor/checks`, or `bin`. Under `set -o pipefail`, `grep -q` exits at its first match; a producer still writing (yq and `docker logs` line-flush; awk mid-pipe streams) takes SIGPIPE (rc 141) and the TRUE condition reads FALSE — a coin-flip. Bit live twice: openshell phase wiring (the checks-78/80 era `sandbox list \| grep -q` bug) and check 06 red on a GREEN fresh install (`litellm_has_callback`, reproduced ~40%, 2026-07-21). Buffered single-write producers (`docker ps` tabwriter tables, printf builtins, a trailing `curl -w` code) cannot EPIPE and are not flagged; inner `sh -c`/`bash -c` strings (no pipefail) and comment lines are excluded. Single-line heuristic — the offline suite (`test_install_doctor_determinism.sh`) pins the converted multi-line sites. Read-only. |
| Fails when | a new racy pipeline of one of the three guarded producer classes lands in the scanned trees. |
| Fix | print-only advice (NOT FIX_CAPABLE — conversion is per-site judgment, never a blind sed): capture-then-grep on a variable (the `fleet.sh` idiom), fold the match into `awk END` with no early exit, or count with `grep -c` and judge the number. |

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
