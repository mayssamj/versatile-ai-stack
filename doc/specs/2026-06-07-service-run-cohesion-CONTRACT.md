# Interface contract — service run/lifecycle cohesion (orchestrator-defined, Phase 1)

Frozen before Phase 1. All 4 workstreams code to THIS. If you need a field/behavior not here,
STOP and ask the orchestrator — do not invent schema. Companion to the approved design
(`2026-06-07-service-run-cohesion.md`) + plan (`...-PLAN.md`).

## File ownership (STRICT — no two agents touch the same file)
- **WS-A** → `mayssam-ai-stack.sh` ONLY.
- **WS-B** → `bin/start-lmstudio.sh` (NEW) · `installer/phases/25_lmstudio.sh` · `installer/lib/lmstudio.sh`.
- **WS-C** → `bin/start-claw3d.sh` · `bin/start-claw3d-bridge.sh` · `installer/phases/19_claw3d.sh`.
- **WS-D** → `services.yml` ONLY.

Nobody else edits these. Docs are Phase 3.

## services.yml schema cmd_start/cmd_stop rely on (WS-D provides, WS-A consumes)
Per service `.services.<svc>`:
- `type` — already present on all; the behavior class. Real values in this repo:
  `docker`, `docker-compose`, `compose`, `node-bg`, `python-bg`, `brew-service`, `openshell`,
  `cli-only`, `clone-only`, `pip-package`, `npm-global`, `agent-pattern`, `litellm-feature`,
  `litellm-virtual-key`, `paperclip-plugin`, `hermes-profiles`, `sandbox-daemon`.
- `alias` — /etc/hosts docker-network alias (e.g. `openwebui`), may be null.
- `host_port` — published host port (e.g. 8080), may be null.
- `open_url` — **NEW, optional.** Absolute, HOST-reachable URL for a UI service. Presence ⇒ UI ⇒
  browser-open eligible. Absent/null ⇒ never browser-open.
- `help.usage` — authored "how to use" prose; cmd_start prints it for non-daemon types.

### open_url values WS-D sets (host-reachable; aliases resolve via the stack's /etc/hosts entries)
| svc | open_url |
|---|---|
| claw3d | `http://localhost:4310` |
| openwebui | `http://openwebui:8080` |
| phoenix | `http://phoenix:6006` |
| qdrant | `http://qdrant:6333/dashboard` |
| falkordb-ui | `http://falkordb-ui:3000` |
| falkordb | `http://falkordb-ui:3000` (so `start falkordb` opens the browser UI) |
| deerflow | `http://localhost:2026` |
| autofyn | `http://autofyn:3400` |
| paperclip | `http://paperclip:3100` |
| hermes_workspace | `http://workspace:3000` |
| unsloth | `http://localhost:8898` |
WS-D: verify each against the service's start script / HANDOFF before committing a value; if a URL
is wrong or the service has no real browser UI, drop open_url for it and note it for the orchestrator.

## cmd_start dispatch order (WS-A authoritative)
For `start <svc>` / `run <svc>` / `enable <svc>`:
1. **_ensure_setup <svc>** (enumerated: claw3d, lmstudio) — see below. May abort or run install.
2. If `bin/start-<svc>.sh` exists & executable → **`bash "$script"`** (NOT `exec` — post-start
   actions must run; preserve its exit code with `local rc=$?`). On rc==0 → `_report_started` +
   `_browser_open` (fresh-start only). On rc!=0 → propagate.
3. elif `_is_brew_service "$svc"` → `brew services start` (KEEP existing ollama/openshell warnings).
   Then `_report_started`. (brew path may keep `exec` or not — but if you want _report_started after,
   drop exec here too. Minimum: existing warnings preserved.)
4. elif `type` ∈ {cli-only, clone-only, pip-package, npm-global, agent-pattern, litellm-feature,
   litellm-virtual-key, paperclip-plugin, hermes-profiles, sandbox-daemon, openshell-agent} →
   print an **honest categorical message**: `"<svc> is a <type-friendly-name>; it doesn't run as a
   daemon. To use it:"` + the `help.usage` prose (read via yq). **exit 0.** NEVER "no start script".
5. else (unknown type, no script, not brew) → existing `err "No start script"` + list + exit 1.

`run` is a PURE alias of `start`. `enable`=start, `disable`=stop (already wired).

## Helpers WS-A adds (all live in mayssam-ai-stack.sh)
- **`_report_started <svc>`**: read services.yml. If `open_url` set → print `URL: <open_url>`. elif
  `alias`+`host_port` → `Endpoint: http://<alias>:<host_port>`. elif `host_port` →
  `Endpoint: http://localhost:<host_port>`. Always print `Stop: mayssam-ai-stack.sh stop <svc>`.
- **`_browser_open <svc> <url>`**: best-effort, GATED — open only when ALL hold: `open_url` non-empty
  AND this was a FRESH start (not an idempotent "already running") AND interactive TTY (`[[ -t 1 ]]`)
  AND not `NO_BROWSER`/`CI` env set AND not `--no-open` AND (`open` on macOS | `xdg-open` on Linux
  present). `--open` forces it past the TTY/CI gate (still needs a launcher binary). If it can't open,
  STILL print the URL: `"(no browser opened — headless/CI; open it yourself: <url>)"`. Never fail the
  command because the browser didn't open.
- **`_ensure_setup <svc>`** (enumerated claw3d→`claw3d/node_modules`, lmstudio→`/Applications/LM Studio.app`):
  if the prereq path exists → return 0. Else: interactive TTY (and not `NO_PROMPT`/`CI`) → prompt
  `"<svc> isn't set up yet — set it up now? (~2 min) [y/N] "`; on `y` → run the install phase
  (`cmd_install <phase>`; claw3d=19, lmstudio=25) then continue; on `n`/timeout/EOF → print
  `"<svc> isn't set up — run: mayssam-ai-stack.sh install <svc>"` and exit non-zero. Non-interactive/CI/
  NO_PROMPT → do NOT auto-install; print that same exact-command line and exit non-zero.
- Idempotency: "already running" from a start script (rc==0 but it printed "already running") should
  still print _report_started but should NOT browser-open. Detect fresh-vs-idempotent by capturing the
  script's stdout and grepping for an "already running" marker, OR by a pre-check; pick the simplest
  robust approach and document it inline. (Start scripts print `ok "... already running ..."`.)

## Flags (WS-A) — parse in cmd_start, strip before svc resolution
`--no-open` (never open), `--open` (force open past TTY/CI gate). `NO_BROWSER=1` and `CI=1` env both
suppress auto-open (same as --no-open). Honor existing `NO_PROMPT`.

## Routing additions (WS-A)
- Add `run` to `is_subcommand` (line ~237 case), to the dispatch `case` (`run|start|enable) cmd_start`),
  and to the reverse-form `case` (`run|start|enable) cmd_start "$cmd"`).
- Update `usage()` text: document `run` as alias, that `start <svc>` opens UIs + prints URL/Stop, and
  `start lmstudio` / `start claw3d`. (The two help texts referenced in the spec = `usage()` here +
  WS-D's services.yml `help` blocks.)

## start scripts — invariants for WS-B / WS-C
- Exit 0 idempotently when already up (print `ok "... already running ..."`).
- Print their own progress/log lines. The AUTHORITATIVE reach line (`URL:`/`Stop:`) + browser-open come
  from cmd_start — scripts may still print a friendly "open http://…" but must not assume they own it.
- bash 5 guard + `set -Eeuo pipefail` per existing convention.

### WS-C claw3d composite (health-gated)
`bin/start-claw3d.sh` must FIRST start the bridge (`bin/start-claw3d-bridge.sh`, :7780) and wait for
`/health` (it already idempotently self-checks). If the bridge is not healthy within its timeout →
**abort** with a clear error (no "UI up, bridge dead"). THEN start the UI (:4310) + wait as today.
`installer/phases/19_claw3d.sh` must DELEGATE its launch to `bin/start-claw3d.sh` (single source of
truth) — remove the duplicated separate bridge-then-UI launch (currently lines ~95/97). Provisioning
(clone/npm/.env/settings.json) stays in phase 19. Doctor check 32 unchanged.

### WS-B lmstudio
NEW `bin/start-lmstudio.sh`: guard chain → `[[ "$(uname)" == Darwin ]]` else clear refusal naming the
right path (NOT "no start script"); `/Applications/LM Studio.app` present else refusal +
`mayssam-ai-stack.sh install lmstudio`; `lms` CLI bootstrapped (reuse `installer/lib/lmstudio.sh` helpers —
source it); idempotent (`lms_server_up` ⇒ `ok "already running"` exit 0); else
`lms server start -p 1234 --bind 0.0.0.0`; wait until `lms_server_up`; print the CPU-idle-spin warning
+ "no model auto-loads; assign one + `model sync`". Phase 25: strip `LMS_AUTOSTART`-as-RUN-path — the
"server down" note (lines ~113-127) now points to `mayssam-ai-stack.sh start lmstudio`. `LMS_AUTOSTART` may
remain ONLY as an install-time convenience, not the documented run path. `installer/lib/lmstudio.sh`
line ~292 hint text → point to `mayssam-ai-stack.sh start lmstudio`.

## Verification each agent runs before reporting DONE
`bash -n <each touched .sh>`. WS-D: `yq -e '.services' services.yml >/dev/null` parses clean + spot
`yq` each open_url back. Report a typed HANDOFF (artifact path, status, what you changed, anything you
flagged for the orchestrator).
