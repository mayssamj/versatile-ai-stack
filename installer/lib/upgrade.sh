#!/usr/bin/env bash
# upgrade.sh — `vz-ai-stack.sh upgrade <service|all> [--dry-run]`.
#
# Generic, type-dispatched upgrade verb. For each enabled service it pulls/
# rebuilds the new artifact, recreates via the canonical path, then re-verifies
# with a DETERMINISTIC per-service probe (health URL / container_running), NOT a
# doctor substring filter (doctor's filter matches check NAMES — openwebui/etc.
# match zero checks → vacuous green; litellm over-matches a Pi check).
#
# Hard rules (this file owns the install lock, so it must never deadlock):
#   - NEVER shell back to `vz-ai-stack.sh install <phase>` (re-acquires the lock →
#     exit 3). Docker recreate goes through the lock-free
#     `bin/start-<svc>.sh --recreate`; phase re-asserts run the phase SCRIPT
#     directly via `bash installer/phases/<id>_*.sh` (no lock_acquire in any).
#   - Loads NO CHAT models: ollama upgrade is `brew upgrade ollama` (binary only),
#     docker is `docker pull` (image only) + recreate. CAVEAT: a `phase-rerun` of
#     lumen (phase 16) can `ollama pull` the ~150MB EMBEDDER if its precheck fails
#     (embedding plane is kept by design) — no CHAT model is ever pulled.
#   - EXHAUSTIVE but honest: a service with a services.yml `upgrade:` block is
#     version-bumped by its method (npm-global/uv-venv/git-pull/rebuild); everything
#     else RE-RUNS its install phase (AI_STACK_UPGRADE=1 is exported as a forward
#     convention — no phase reads it yet, so today phase-rerun RE-ASSERTS config via
#     the phase's own precheck-guarded logic and only fetches a new version where the
#     phase is version-UNPINNED). RESULT is labeled `re-asserted` (not `upgraded`) so
#     the summary never implies a version bump that didn't happen. NOTE: a phase-rerun
#     of an opt-in sim (metagpt/aitown/…) runs that phase's live model smoke, which
#     bills the subscription/metered route when its precheck doesn't short-circuit.
#   - Registers NO doctor checks → the doctor invariant is untouched.
#
# This runs as its OWN process (vz-ai-stack.sh dispatches `"$BASH" upgrade.sh "$@"`),
# so the lock's EXIT/INT/TERM trap (common.sh) cleanly removes LOCKDIR on exit.

# bash 5+ required (inherit_errexit + assoc arrays). Self-gate: if invoked under macOS's
# stock 3.2 — a stripped-PATH cron `bash upgrade.sh`, or any bare-`bash` dispatch — re-
# exec under brew-bash BEFORE `shopt -s inherit_errexit` below would abort on it. Makes
# the script robust regardless of caller AND guarantees $BASH (used for our OWN sub-
# dispatches below) is the bash-5 path. Mirrors the vz-ai-stack.sh gate.
if (( BASH_VERSINFO[0] < 5 )); then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$_c" ]] && exec "$_c" "$0" "$@"
  done
  echo "upgrade.sh requires bash 5+ (macOS ships 3.2); run: brew install bash" >&2
  exit 1
fi

set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AI_STACK
LIB="$AI_STACK/installer/lib"

# Source only side-effect-free libs. NEVER status.sh (prints the table at top
# level) or vz-ai-stack.sh (runs main() on source).
source "$LIB/common.sh"
source "$LIB/env.sh"
source "$LIB/docker.sh"
source "$LIB/prompt.sh"
source "$LIB/services_accessors.sh"
source "$LIB/versions.sh"   # shared version oracle (installed/available/classify/reconcile)

trap 'err "ERR line $LINENO: $BASH_COMMAND (exit=$?)"' ERR

DRY=0
DOCKER_OK=1            # set 0 if `docker info` fails (skip docker/compose)
CHECK=0               # --check  : read-only "what has an update?" report, no mutate
OUTDATED=0            # --outdated: upgrade ONLY services the check finds outdated
JSON=0                # --json   : machine-readable check output
ALL_ROWS=0            # --all    : include 'manual' (non-checkable) rows in --check
PREFLIGHT=0           # 1 while printing the pre-upgrade version report (before mutating)
NO_CHECK=0            # --no-check: skip the pre-upgrade version report (faster; e.g. offline)
SUMMARY=()             # rows: "svc<TAB>strategy<TAB>result<TAB>version<TAB>reverify"
_SUMMARY_PRINTED=0     # idempotency guard: the explicit call AND the EXIT-trap both call print_summary
CHECK_ROWS=()          # rows: "svc<TAB>type<TAB>current<TAB>available<TAB>status"
CHECK_STATUS=""; CHECK_CUR=""; CHECK_AVAIL=""   # set by check_one

# --- usage -------------------------------------------------------------------
upgrade_usage() {
  cat <<'EOF'
vz-ai-stack.sh upgrade <service|all> [--dry-run]   upgrade a service (or all enabled)
vz-ai-stack.sh upgrade hermes                      GROUP: upgrade EVERY hermes surface to latest
                                                   (fleet pip + workspace UI image + Telegram/Slack gateways)
vz-ai-stack.sh upgrade --check [service|all|hermes] READ-ONLY: show which have an update available
vz-ai-stack.sh upgrade --outdated [--dry-run]      upgrade ONLY services found outdated (docker/
                                                   compose/brew CURRENCY only — NOT the fleet/pip plane)
vz-ai-stack.sh upgrade --check --all               include non-checkable (manual) services too
                                                   (--all has NO effect with --outdated)
vz-ai-stack.sh upgrade --check --json              machine-readable availability report

  Type-dispatched (services.yml): docker→pull+recreate, compose→pull+up,
  brew→brew upgrade, openshell→in-sandbox update + phase re-assert. Every other
  service is EXHAUSTIVE now: a declared `upgrade:` block version-bumps it directly
  (npm-global / uv-venv / git-pull / rebuild), else its install phase is re-run
  (AI_STACK_UPGRADE=1) to re-assert/upgrade — nothing is a silent no-op. Bare
  `upgrade all` also upgrades the host npm globals (meridian, claude-code; codex is
  npx-always-latest). `upgrade <meridian|claude-code>` upgrades one host global.

  --check is non-mutating: docker/compose by registry manifest DIGEST, ollama by
  `brew outdated`, and npm/pip(uv-venv)/git-clone services by npm/PyPI/git ls-remote
  (bounded — a blocked registry degrades to 'unknown', never hangs). Only services
  with no version oracle (config-only / sandbox CLIs) stay 'manual'.

  Every upgrade run first prints an installed→available version report (skip with
  --no-check), and the summary's VERSION column shows what actually moved — a no-op
  reads 'up-to-date', a real move 'a→b', an unverifiable path 'done (unverified)'.
  A swallowed brew/pip failure now reports FAILED instead of a false 'upgraded',
  and `upgrade all` skips services not installed on this host (no unsolicited installs).

  --dry-run    print the per-service plan (current→new) and change nothing.
  --no-check   skip the pre-upgrade version report (faster / offline).
  Set AI_STACK_ASSUME_YES=1 to auto-accept the version-pinned re-pull prompt.
  See installed vs available anytime:  vz-ai-stack.sh status --versions

  --outdated is a fast docker/compose/brew CURRENCY sweep. It does NOT reach the
  sandbox/CLI/pip/fleet plane (in-sandbox hermes agent, pi, mempalace, docs_mcp) or
  the host npm globals — those read 'manual' and can never hit the outdated gate. It
  prints a footer naming what it skipped. For the true "upgrade everything" motion
  (incl. the fleet brain), use `upgrade all`; for just the hermes surfaces, `upgrade hermes`.

  Typical flow:
    vz-ai-stack.sh upgrade --check        # see what's available
    vz-ai-stack.sh upgrade --outdated     # pull the docker/compose/brew images that moved
    vz-ai-stack.sh upgrade all            # exhaustive: also the fleet pip + host globals
    vz-ai-stack.sh upgrade openwebui      # or upgrade selectively from the list
EOF
}

# --- summary recording -------------------------------------------------------
# record_row svc strategy result reverify [version]
# Stored order: svc <TAB> strategy <TAB> result <TAB> version <TAB> reverify.
# `version` is the installed before→after string (VER column); 5th arg is optional
# (defaults "-") so existing 4-arg callers (host globals) keep working unchanged.
record_row() {
  local ver="${5:--}"
  SUMMARY+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$ver"$'\t'"$4")
}

print_summary() {
  # Idempotent: the explicit post-loop call AND the EXIT-trap safety net
  # (upgrade_on_exit) may both invoke this — print exactly once.
  (( _SUMMARY_PRINTED )) && return 0
  _SUMMARY_PRINTED=1
  printf '\n'
  hdr "Upgrade summary"
  # VERSION shows installed before→after: a no-op reads e.g. '0.16.0' (unchanged),
  # a real bump '0.16.0→0.18.0', an unverifiable path '-'. This is the honesty
  # surface — even if REVERIFY says 'ok' (something is alive), VERSION shows
  # whether the version actually moved (council finding #1).
  local fmt='%-20s %-13s %-18s %-22s %s\n'
  printf "$fmt" SERVICE STRATEGY RESULT VERSION REVERIFY
  printf "$fmt" "--------------------" "-------------" "------------------" "----------------------" "--------"
  local row svc strat res ver rev
  for row in "${SUMMARY[@]}"; do
    IFS=$'\t' read -r svc strat res ver rev <<<"$row"
    printf "$fmt" "$svc" "$strat" "$res" "$ver" "$rev"
  done
  note "VERSION: a value = installed (unchanged) · a→b = moved · - = unverifiable.   REVERIFY: ok = probe passed · warn = probe RAN and failed after a bounded readiness grace (on a service THIS run UPGRADED → RESULT becomes 'FAILED (unhealthy: upgraded)' and the run exits non-zero; on an untouched up-to-date/re-asserted service it is informational only — use doctor/status for ambient health) · n/a = no probe for this type (NOT a failure) · - = not probed (failed/skipped/dry-run)."
}

# upgrade_on_exit — EXIT-trap safety net. GUARANTEES the honesty summary is printed even
# if a bug aborts the run mid-loop (the `$var→` crash killed the whole run AND ate the
# summary — the structural version of that bug), and releases the lock. It MUST be
# trapped AFTER lock_acquire so it supersedes the lock's own EXIT trap (common.sh sets
# `rm -rf LOCKDIR`); we redo that cleanup here. INT/TERM keep the lock trap (a user
# interrupt doesn't need a summary). A `set -u` unbound abort is NOT catchable by
# `|| handler` in a non-subshell (verified), so this EXIT trap — not a per-service
# guard — is the only thing that can save the summary.
upgrade_on_exit() {
  local _rc=$?
  # Subshell-isolate the print: even if print_summary itself aborts (the bug class this
  # very net guards against), the lock is STILL released below.
  (( ${#SUMMARY[@]} > 0 )) && ( print_summary ) || true
  lock_release                                          # single source of truth (common.sh)
  return "$_rc"
}

# _arm_upgrade_traps — install the mutate-phase signal handlers; call RIGHT AFTER
# lock_acquire so it supersedes the lock's own EXIT/INT/TERM trap. EXIT: print the summary
# + release the lock even on an abort. INT/TERM: STOP the run (exit 130/143) so the EXIT
# trap then frees the lock + prints the partial — Ctrl-C must NOT release the lock and let
# the loop keep mutating (a concurrency hazard). A function (not inline traps) so a test can
# exercise the REAL arming instead of a hand-copied trap line.
_arm_upgrade_traps() {
  trap 'upgrade_on_exit' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# --- image helpers -----------------------------------------------------------
# docker_local_digest / image_is_pinned / image_is_local_built / img_local_digest
# / img_remote_digest / check_image now live in installer/lib/versions.sh (the
# shared oracle, sourced above) so status.sh reuses the SAME docker currency
# logic. up_docker/up_compose/check_one call them from there unchanged.

# check_one <svc> — sets CHECK_STATUS / CHECK_CUR / CHECK_AVAIL.
# CHECK_STATUS ∈ update-available | up-to-date | pinned | rebuild | manual | unknown
check_one() {
  local svc="$1" type; type="$(svc_type "$svc")"
  CHECK_STATUS="manual"; CHECK_CUR="-"; CHECK_AVAIL="-"

  case "$type" in
    docker)
      local image; image="$(svc_image "$svc")"
      [[ -z "$image" || "$image" == "-" ]] && { CHECK_STATUS="unknown"; return 0; }
      if (( DOCKER_OK == 0 )); then CHECK_STATUS="unknown"; return 0; fi
      CHECK_STATUS="$(check_image "$image")"
      local l; l="$(img_local_digest "$image")"; [[ -n "$l" ]] && CHECK_CUR="${l:0:19}…"
      if [[ "$CHECK_STATUS" == "update-available" ]]; then
        # This `if` is the docker arm's TERMINAL statement, so its body's last command is
        # check_one's return value. `[[ -n "$r" ]] && CHECK_AVAIL=…` returns 1 when the
        # (redundant, best-effort) 2nd registry fetch flakes to empty — which under a
        # Zscaler-MITM proxy is an ordinary transient — aborting the bare check_one call in
        # the --check/--outdated/preflight paths. Use if/fi so an empty digest just leaves
        # CHECK_AVAIL='-' (display-only) instead of crashing the run. (2026-07-14 crash fix.)
        local r; r="$(img_remote_digest "$image")"; if [[ -n "$r" ]]; then CHECK_AVAIL="${r:0:19}…"; fi
      fi
      ;;
    compose|docker-compose)
      local dir; dir="$(svc_path "$svc")"
      { [[ -z "$dir" || "$dir" == "-" || ! -d "$dir" ]] || (( DOCKER_OK == 0 )); } && { CHECK_STATUS="manual"; return 0; }
      local imgs; imgs="$( cd "$dir" && docker compose config --images 2>/dev/null || true )"
      [[ -z "$imgs" ]] && { CHECK_STATUS="manual"; return 0; }
      local im st any_update=0 any_unknown=0 any_build=0 n=0
      while IFS= read -r im; do
        [[ -z "$im" ]] && continue
        n=$((n+1))
        st="$(check_image "$im")"
        case "$st" in
          update-available) any_update=1 ;;
          unknown)          any_unknown=1 ;;   # real image, registry unreachable
          build)            any_build=1 ;;     # locally-built app image (honcho-api etc.)
        esac
      done <<< "$imgs"
      (( n == 0 )) && { CHECK_STATUS="manual"; return 0; }   # only blank lines → nothing checked
      CHECK_CUR="${n} imgs"
      # Surface a lone pinned semantic version (e.g. "2 imgs (v2026.6.19)") — the
      # actionable fact the bare count hides — but only when it fits the CURRENT column.
      # Display-only; the reconcile fingerprint in _iv_compose is untouched.
      local _lt; _lt="$(_compose_lone_semver_tag "$imgs")"
      if [[ -n "$_lt" ]]; then
        local _cand="${n} imgs (${_lt})"
        (( ${#_cand} <= 22 )) && CHECK_CUR="$_cand"
      fi
      # Precedence: a confirmed registry update wins. Otherwise, any image we
      # couldn't digest-check (locally-built OR registry-unreachable) → 'rebuild':
      # for a compose stack the remediation is identical — `upgrade` runs
      # `compose pull && up -d`, which refreshes reachable images AND rebuilds
      # local ones. Only when every image is confirmed current → up-to-date.
      if   (( any_update ));               then CHECK_STATUS="update-available"; CHECK_AVAIL="pull"
      elif (( any_build || any_unknown )); then CHECK_STATUS="rebuild"
      else                                      CHECK_STATUS="up-to-date"; fi
      ;;
    brew-service)
      local out
      # Bound `brew outdated` (it can hit the network to refresh) so the preflight,
      # which now runs check_one on the plain upgrade path, honors the all-probes-
      # bounded contract on a proxy-blocked host (council should-fix).
      out="$(_vz_bounded 12 brew outdated --json=v2 2>/dev/null \
        | python3 -c "import sys,json
d=json.load(sys.stdin)
f=[x for x in d.get('formulae',[]) if x['name']=='$svc']
print(f\"{f[0]['installed_versions'][0]}\t{f[0]['current_version']}\") if f else print('')" 2>/dev/null || true)"
      if [[ -n "$out" ]]; then
        CHECK_CUR="$(printf '%s' "$out" | cut -f1)"
        CHECK_AVAIL="$(printf '%s' "$out" | cut -f2)"
        CHECK_STATUS="update-available"
      else
        # Not in `brew outdated`. Distinguish genuinely-current from
        # not-installed/unreachable: if the formula isn't installed, `brew list`
        # yields nothing → report 'unknown' rather than a false 'up-to-date'.
        # `|| true`: brew list exits 1 for an uninstalled formula (would abort).
        local cur; cur="$(brew list --versions "$svc" 2>/dev/null | awk '{print $2}' || true)"
        if [[ -z "$cur" ]]; then CHECK_STATUS="unknown"
        else CHECK_STATUS="up-to-date"; CHECK_CUR="$cur"; fi
      fi
      ;;
    *)
      # Previously a blanket 'manual'. Now consult the shared oracle: npm-global,
      # pip/uv-venv, and clone/git services (and any cli-only with a declared
      # upgrade: block) DO have a version — surface installed + upstream instead of
      # hiding them (council finding #7). A type with no oracle stays 'manual';
      # installed-known-but-upstream-unreachable is honest 'unknown', not a false
      # 'up-to-date'.
      local inst avail
      inst="$(svc_installed_version "$svc" 2>/dev/null || echo -)"
      if [[ -z "$inst" || "$inst" == "-" ]]; then CHECK_STATUS="manual"; return 0; fi
      CHECK_CUR="$inst"
      avail="$(svc_available_version "$svc" 2>/dev/null || echo -)"
      if [[ -z "$avail" || "$avail" == "-" ]]; then
        CHECK_AVAIL="-"; CHECK_STATUS="unknown"
      else
        CHECK_AVAIL="$avail"; CHECK_STATUS="$(version_classify "$type" "$inst" "$avail")"
      fi
      ;;
  esac
  # check_one communicates via the CHECK_* globals; callers never read its exit code.
  # Explicit success so no arm's terminal construct can ever return non-zero and abort
  # the bare `check_one "$svc"` call under set -Eeuo pipefail (crash-class guard).
  return 0
}

# collect_targets <out-array-name> [target] — fill an array with the enabled
# services to act on (or the single named target).
collect_targets() {
  local -n _out="$1"; local target="${2:-all}" name
  _out=()
  if [[ "$target" == "all" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$(svc_enabled "$name")" == "true" ]]; then _out+=("$name"); fi
    done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
  elif [[ "$target" == "hermes" ]]; then
    # Group alias — DATA-DRIVEN: every enabled service tagged `group: hermes` in services.yml
    # (tag a new hermes surface → it auto-joins; no hardcoded list to drift out of sync).
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$(svc_enabled "$name")" == "true" ]]; then _out+=("$name"); fi
    done < <(yq -r '.services | to_entries | .[] | select(.value.group == "hermes") | .key' "$SERVICES_YML")
  else
    _out=("$target")
  fi
  # Explicit success: the while bodies now use if/fi (not `[[ ]] && _out+=`, whose false
  # result on the LAST-iterated disabled service made the while — hence this function —
  # return 1, aborting the bare `collect_targets …` call under set -Eeuo pipefail; a
  # latent sibling of the up_npm_global crash). Belt-and-suspenders so no future edit
  # reintroduces a non-zero fall-through. (2026-07-14.)
  return 0
}

# print_check_report — render CHECK_ROWS as a table (or JSON) + a next-step footer.
print_check_report() {
  local row svc type cur avail status
  if (( JSON )); then
    printf '['
    local first=1
    for row in "${CHECK_ROWS[@]}"; do
      IFS=$'\t' read -r svc type cur avail status <<<"$row"
      (( first )) || printf ','; first=0
      printf '{"service":"%s","type":"%s","current":"%s","available":"%s","status":"%s"}' \
        "$svc" "$type" "$cur" "$avail" "$status"
    done
    printf ']\n'
    return 0
  fi
  local title="Upgrade availability (read-only — nothing downloaded or changed)"
  (( PREFLIGHT )) && title="Versions before upgrade (installed → available upstream; read-only)"
  printf '\n'; hdr "$title"
  local fmt='%-20s %-15s %-22s %-22s %s\n'
  printf "$fmt" SERVICE TYPE CURRENT AVAILABLE STATUS
  printf "$fmt" "--------------------" "---------------" "----------------------" "----------------------" "------"
  local -a outdated=(); local hidden=0 unconfirmed=0
  for row in "${CHECK_ROWS[@]}"; do
    IFS=$'\t' read -r svc type cur avail status <<<"$row"
    # Hide non-checkable ('manual') rows unless --all — they carry no signal. The
    # pre-upgrade preflight shows every targeted service (the operator asked to see
    # what's about to change).
    if [[ "$status" == "manual" ]] && (( ALL_ROWS == 0 )) && (( PREFLIGHT == 0 )); then hidden=$((hidden+1)); continue; fi
    printf "$fmt" "$svc" "$type" "$cur" "$avail" "$status"
    case "$status" in
      update-available) outdated+=("$svc") ;;
      unknown|rebuild)  unconfirmed=$((unconfirmed+1)) ;;   # currency NOT confirmed
    esac
  done
  printf '\n'
  if (( hidden )); then
    note "$hidden service(s) not version-checkable (sandbox/CLI/npm/pip) hidden — use --check --all to list them."
  fi
  if (( ${#outdated[@]} )); then
    ok "${#outdated[@]} update(s) available: ${outdated[*]}"
    if (( PREFLIGHT == 0 )); then
      note "Upgrade all of them:   vz-ai-stack.sh upgrade --outdated"
      note "Or selectively:        vz-ai-stack.sh upgrade <service>   (e.g. vz-ai-stack.sh upgrade ${outdated[0]})"
    fi
  fi
  # Honest all-clear: only claim currency when NOTHING is outdated AND nothing was
  # left unconfirmed (unknown/rebuild/proxy-blocked). Otherwise say so explicitly
  # instead of a green "everything up to date" that over-claims (council finding #7).
  if (( ${#outdated[@]} == 0 )); then
    if (( unconfirmed == 0 )); then
      ok "Everything that can be auto-checked is up to date."
    else
      warn "No confirmed updates, but $unconfirmed service(s) could NOT be verified (unknown/rebuild — registry/proxy blocked or locally-built). Currency is NOT confirmed for those."
    fi
  elif (( unconfirmed )); then
    note "$unconfirmed additional service(s) could not be verified (unknown/rebuild) — currency not confirmed for those."
  fi
  note "Legend: pinned=fixed tag (no rolling updates) · build=locally-built docker image (no registry; 'upgrade <svc>' rebuilds it) · rebuild=compose stack with locally-built/uncheckable images (run upgrade to pull+rebuild) · manual=no version oracle · unknown=registry/proxy unreachable or no local image · up-to-date/update-available=installed vs upstream latest"
}

# --- phase / start-script resolution (lock-free recreate paths) --------------
# Resolve a phase id (verbatim from svc_phase) to its unique script path.
resolve_phase_script_inline() {
  local id="$1"
  local m=( "$AI_STACK/installer/phases/${id}_"*.sh )
  # nullglob → a no-match leaves m EMPTY, so bare `${m[0]}` is an UNBOUND-VARIABLE abort
  # under set -u (config drift: a typo'd services.yml `phase:`, or a phase script renamed/
  # deleted without updating services.yml — a failure class this repo has already hit).
  # Guard the array access AND end with `return 0`, so a no-match is a normal empty result
  # (every caller already handles "" via `if [[ -z "$script" ]]; then … RESULT=FAILED …`),
  # never a non-zero that aborts the bare `script="$(resolve_phase_script_inline …)"` call
  # under set -Eeuo pipefail (same crash class as the up_npm_global/collect_targets fixes).
  (( ${#m[@]} )) && [[ -e "${m[0]}" ]] && printf '%s' "${m[0]}"
  return 0
}

# Recreate a docker service via its per-service start script (lock-free).
# Tries both key forms: bin/start-<key>.sh then bin/start-<key//_/->.sh.
# Echoes ok/warn into the caller's RESULT via return code (0 ok, 1 fail).
recreate_via_start_script() {
  local svc="$1" script
  for script in "$AI_STACK/bin/start-${svc}.sh" "$AI_STACK/bin/start-${svc//_/-}.sh"; do
    if [[ -x "$script" ]]; then
      "$BASH" "$script" --recreate
      return $?
    fi
  done
  err "$svc: no start script (tried bin/start-${svc}.sh, bin/start-${svc//_/-}.sh); recreate manually"
  return 1
}

# --- reverify (deterministic; registers NO doctor checks) --------------------
# Echoes "ok", "warn" (probe RAN and failed), or "n/a" (no probe for this strategy);
# never aborts the run. "n/a" must NOT read as a failure — it means "nothing to probe".
reverify() {
  local svc="$1" strategy="$2" h; local -i attempt
  # F1 promotes this from an advisory column to the EXIT-CODE oracle (a 'warn' now
  # fails the run). A service that was just pulled+recreated can legitimately need a
  # moment to become healthy — litellm alone documents a 60s+ uvicorn/Prisma cold
  # start (bin/start-litellm.sh) and NO start script waits for readiness — so an
  # instant single-shot probe would false-FAIL a successful upgrade and train the
  # operator to distrust the exit code (§24 council: architect+adversarial). We give
  # a FAILING probe a bounded readiness grace: retry a few times, a few seconds apart.
  #   - A healthy service returns on attempt 1 → NO extra probes (so litellm's
  #     /health model-pings are NOT amplified; the grace loop only spins while failing).
  #   - A genuinely-broken service still ends 'warn' after the window → still FAILED.
  #   - Bounded, never unbounded: ~5 attempts × 4s (typical cold-start ~16s; the
  #     pathological all-timeout case is capped by curl --max-time, still finite).
  local -i tries=5 gap=4
  h="$(svc_health "$svc")"
  if [[ "$h" != "-" && -n "$h" ]]; then
    for (( attempt=1; attempt<=tries; attempt++ )); do
      curl -fsS --max-time 10 "$h" >/dev/null 2>&1 && { echo ok; return 0; }
      if (( attempt < tries )); then sleep "$gap"; fi
    done
    echo warn; return 0
  fi
  case "$strategy" in
    docker)
      for (( attempt=1; attempt<=tries; attempt++ )); do
        container_running "$svc" && { echo ok; return 0; }
        if (( attempt < tries )); then sleep "$gap"; fi
      done
      echo warn
      ;;
    compose)
      for (( attempt=1; attempt<=tries; attempt++ )); do
        docker ps --format '{{.Names}}' | grep -qE "^$(svc_project "$svc")(-|$)" && { echo ok; return 0; }
        if (( attempt < tries )); then sleep "$gap"; fi
      done
      echo warn
      ;;
    *)
      echo "n/a"   # brew/openshell/phase-rerun w/ no health: URL — no probe exists (NOT a failure)
      ;;
  esac
}

# --- per-strategy handlers ---------------------------------------------------
# Each handler sets RESULT (a string) and STRATEGY (for reverify dispatch), or
# records its own row + returns when there is nothing to reverify (manual/skip).

up_docker() {
  local svc="$1"
  local image cur new
  image="$(svc_image "$svc")"
  STRATEGY=docker
  if [[ -z "$image" || "$image" == "-" ]]; then
    RESULT=FAILED
    err "$svc: no image declared"
    return 0
  fi

  # Locally-built image (e.g. ai-stack/chatdev:local) — exists in NO registry, so
  # `docker pull` would fail "pull access denied" and hard-FAIL the whole `upgrade all`.
  # "Upgrade" for a derived image = REBUILD via its per-service start script
  # (start-<svc>.sh --recreate rebuilds the image), exactly like the deerflow case in
  # up_compose. Skip the pull (and the pointless pinned-pull prompt) entirely.
  if image_is_local_built "$image"; then
    if (( DRY )); then
      note "PLAN $svc docker: $image is locally built (no registry) — would rebuild via its start script (start-$svc.sh --recreate), no pull"
      RESULT="planned"; return 0
    fi
    if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
    # Heads-up at the upgrade layer: the rebuild is a docker build (can take several
    # minutes), not a quick pull — so `upgrade all` doesn't look like it hung here.
    note "$svc: locally-built image ($image) — rebuilding via its start script (docker build; first build can take several minutes; no registry pull)…"
    # A rebuild that produces a byte-identical image is a no-op — compare the image ID
    # before/after so we don't over-claim 'upgraded' on an unchanged rebuild (STRATEGY
    # stays 'docker' → reconcile_result skips it, so this is the only honesty backstop
    # here). If either inspect fails (empty id) the delta is UNKNOWABLE → 'done
    # (unverified)', never a blind 'upgraded' (same philosophy as reconcile_result).
    local _bid _aid
    _bid="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
    if recreate_via_start_script "$svc"; then
      _aid="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
      if   [[ -z "$_aid" || -z "$_bid" ]]; then RESULT="done (unverified)"
      elif [[ "$_aid" == "$_bid" ]];       then RESULT="up-to-date"
      else                                      RESULT="upgraded"; fi
    else RESULT=FAILED; fi
    return 0
  fi

  cur="$(docker_local_digest "$image")"
  [[ -z "$cur" ]] && cur="unknown"

  if (( DRY )); then
    note "PLAN $svc docker: current=$cur; would: docker pull $image; recreate via bin/start-$svc.sh --recreate if digest changes"
    RESULT="planned"
    return 0
  fi

  if (( DOCKER_OK == 0 )); then
    RESULT="skipped (docker unavailable)"
    return 0
  fi

  # Pinned-tag guard (live only): a re-pull of the same fixed tag is a no-op.
  if image_is_pinned "$image"; then
    if ! confirm "$image is version-pinned; a re-pull of the same tag is a no-op. Pull anyway?" N; then
      RESULT="skipped-pinned"
      return 0
    fi
  fi

  if ! docker pull "$image"; then
    RESULT=FAILED
    err "$svc: docker pull $image failed"
    return 0
  fi
  new="$(docker_local_digest "$image")"

  if [[ -n "$new" && "$new" == "$cur" ]]; then
    RESULT="up-to-date"
    note "$svc: digest unchanged ($new) — skipping recreate"
    return 0
  fi

  note "$svc: digest moved (old=$cur) — rollback with: docker pull ${image}@${cur}"
  if recreate_via_start_script "$svc"; then
    RESULT="upgraded"
  else
    RESULT=FAILED
  fi
}

up_compose() {
  local svc="$1" dir
  dir="$(svc_path "$svc")"
  STRATEGY=compose

  case "$svc" in
    deerflow)
      # wrapper supports `build`
      if (( DRY )); then
        note "PLAN $svc docker-compose: would: bash bin/start-deerflow.sh build (rebuild images + up)"
        RESULT="planned"; return 0
      fi
      if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
      if "$BASH" "$AI_STACK/bin/start-deerflow.sh" build; then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
    autofyn)
      # start-autofyn.sh has NO pull — run pull && up -d directly in svc_path.
      if [[ -z "$dir" || "$dir" == "-" ]]; then
        note "$svc: no path declared; run manually: docker compose pull && docker compose up -d"
        RESULT="manual"; return 0
      fi
      if (( DRY )); then
        note "PLAN $svc docker-compose: would: (cd $dir && docker compose pull && docker compose up -d)"
        RESULT="planned"; return 0
      fi
      if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
      if ( cd "$dir" && docker compose pull && docker compose up -d ); then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
    hermes_workspace)
      # The override (written by phase 05) declares a locally-BUILT image
      # `hermes-workspace:aistack-hardened` (no registry). Two needs:
      #   1. `compose pull` must SKIP it (else "pull access denied") → --ignore-buildable.
      #   2. plain `up -d` reuses the EXISTING local image, so it would NOT refresh a
      #      bumped base. Mirror phase 05: rebuild the hardened image first, reading the
      #      (resolved) build config STRAIGHT FROM the override — phase 05's persisted
      #      source of truth, so no duplicated digest pins and no drift.
      # (See the `*)` branch's CAUTION note below on why --ignore-buildable is only
      # safe for build-only / no-registry-counterpart images.)
      if [[ -z "$dir" || "$dir" == "-" ]]; then
        note "$svc: no path declared; run manually in its dir: docker build the hardened image, then docker compose pull --ignore-buildable && docker compose up -d"
        RESULT="manual"; return 0
      fi
      local ovr="$dir/docker-compose.override.yml" ws_img="" ws_ctx="" ws_df="Dockerfile" ws_base="" can_build=0
      if [[ -f "$ovr" ]] && command -v yq >/dev/null 2>&1; then
        ws_img="$(yq -r '.services.hermes-workspace.image // ""' "$ovr" 2>/dev/null)"
        ws_ctx="$(yq -r '.services.hermes-workspace.build.context // ""' "$ovr" 2>/dev/null)"
        ws_df="$(yq -r '.services.hermes-workspace.build.dockerfile // "Dockerfile"' "$ovr" 2>/dev/null)"
        ws_base="$(yq -r '.services.hermes-workspace.build.args.WS_BASE // ""' "$ovr" 2>/dev/null)"
      fi
      # Buildable only if the override carries a RESOLVED build config: image, context,
      # dockerfile AND WS_BASE all present, and WS_BASE a concrete ref (not a still-
      # unexpanded ${VAR}, which would pass an empty build-arg). ws_df is checked too —
      # `// "Dockerfile"` only defaults on null/missing, NOT a present-but-empty key.
      [[ -n "$ws_img" && -n "$ws_ctx" && -n "$ws_df" && -n "$ws_base" && "$ws_base" != *'${'* ]] && can_build=1
      if (( DRY )); then
        if (( can_build )); then
          note "PLAN $svc compose: would: (cd $dir && docker build -t $ws_img --build-arg WS_BASE=$ws_base -f $ws_ctx/$ws_df $ws_ctx) then docker compose pull --ignore-buildable && docker compose up -d"
        else
          note "PLAN $svc compose: override has no resolved hardened-image build config — would SKIP rebuild (run 'vz-ai-stack.sh install 05'), then (cd $dir && docker compose pull --ignore-buildable && docker compose up -d)"
        fi
        RESULT="planned"; return 0
      fi
      if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
      if (( can_build )); then
        if ! ( cd "$dir" && docker build -t "$ws_img" --build-arg "WS_BASE=$ws_base" -f "$ws_ctx/$ws_df" "$ws_ctx" ); then
          # Degrade gracefully (phase 05 posture): keep the existing local image and
          # still bring the stack up, but flag the failed refresh so the summary is honest.
          # NOTE: by design upgrade does NOT mutate the override here — `install 05` owns
          # the self-healing build-config revert; we just route the user to it.
          warn "$svc: hardened image rebuild FAILED — running the existing local image; re-run 'vz-ai-stack.sh install 05' to repair"
          # Surface a degrade-time `up -d` failure (e.g. image never built locally) —
          # do NOT swallow it; RESULT stays FAILED either way.
          ( cd "$dir" && docker compose pull --ignore-buildable && docker compose up -d ) \
            || warn "$svc: degrade 'up -d' also failed — containers may be DOWN; re-run 'vz-ai-stack.sh install 05'"
          RESULT=FAILED; return 0
        fi
      else
        warn "$svc: override lacks a resolved hardened-image build config — skipping rebuild (re-run 'vz-ai-stack.sh install 05'); pulling peers + up -d only. If the hardened image was never built or was GC'd, 'up -d' will fail until install 05 rebuilds it."
      fi
      if ( cd "$dir" && docker compose pull --ignore-buildable && docker compose up -d ); then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
    *)
      # honcho: plain compose pull && up -d in svc_path. (hermes_workspace has its
      # own branch above; autofyn has its own branch above too.)
      # --ignore-buildable: skip images that have a `build:` section but a local-only
      # tag. Without it `compose pull` errors "pull access denied" on such a tag — it
      # exists locally, not in any registry. No-op for honcho (its buildable services
      # api/deriver are build-only, no image: tag to pull).
      # CAUTION: only safe for stacks whose buildable images have NO registry
      # counterpart. A dual-mode service (build: AND a pullable registry image:, like
      # autofyn) MUST get its own branch — --ignore-buildable would skip its real
      # registry pull. Do not route such a service here.
      if [[ -z "$dir" || "$dir" == "-" ]]; then
        note "$svc: no path declared; run manually: docker compose pull --ignore-buildable && docker compose up -d"
        RESULT="manual"; return 0
      fi
      if (( DRY )); then
        note "PLAN $svc compose: would: (cd $dir && docker compose pull --ignore-buildable && docker compose up -d)"
        RESULT="planned"; return 0
      fi
      if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
      if ( cd "$dir" && docker compose pull --ignore-buildable && docker compose up -d ); then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
  esac
}

up_brew() {
  local svc="$1"
  STRATEGY=brew
  # ollama only. BINARY ONLY — never `ollama pull` (24GB RAM; KEEP_ALIVE=30m warm-not-resident).
  if (( DRY )); then
    if [[ "$svc" == ollama ]]; then
      note "PLAN $svc brew-service: would: brew upgrade $svc, then RE-ASSERT OLLAMA_HOST=0.0.0.0 via the deps env-patch (PlistBuddy + launchctl bootout/bootstrap) — NOT 'brew services restart', which regenerates the plist and wipes it, rebinding 127.0.0.1 so LiteLLM's local-* models 500. (If deps.sh can't load, falls back to brew services restart.) NO model pull."
    else
      note "PLAN $svc brew-service: would: brew upgrade $svc && brew services restart $svc (binary only; NO model pull)"
    fi
    brew outdated --verbose "$svc" || true
    RESULT="planned"
    return 0
  fi
  # Capture the exit code instead of swallowing it with `|| true`: a bottle
  # download / formula-lock / TLS-MITM (Zscaler) failure MUST surface as FAILED,
  # not a green 'upgraded' on the old binary (council finding #3). A genuine
  # no-op ('already installed') still exits 0 → RESULT='upgraded' here, which the
  # driver then reconciles to 'up-to-date' via the brew version delta.
  local _brew_rc=0
  brew upgrade "$svc" || _brew_rc=$?
  if (( _brew_rc != 0 )); then
    err "$svc: 'brew upgrade $svc' failed (rc=$_brew_rc) — NOT upgraded (bottle/download/proxy?). Old binary still installed."
    RESULT=FAILED; return 0
  fi
  if [[ "$svc" == ollama ]]; then
    # `brew upgrade ollama` REGENERATES the launchd plist and DROPS OLLAMA_HOST=0.0.0.0,
    # rebinding 127.0.0.1 so in-stack containers (LiteLLM via ollama:host-gateway) can no
    # longer reach it → every local-* model 500s ("no fallback model group"). Re-assert the
    # cross-container env-patch the stack's way instead of `brew services restart` (which
    # would re-wipe it). _dep_ollama_patch_env enforces 0.0.0.0/*/30m + reloads via
    # launchctl bootout/bootstrap. deps.sh is functions-only → safe to source here.
    # Source first (if this context hasn't already), THEN gate the call on the function
    # actually being defined — so the fallback branch is unambiguously reachable if
    # deps.sh fails to load or the function was renamed (review finding).
    declare -f _dep_ollama_patch_env >/dev/null 2>&1 || source "$LIB/deps.sh" 2>/dev/null || true
    if declare -f _dep_ollama_patch_env >/dev/null 2>&1; then
      # The 0.0.0.0 rebind is LOAD-BEARING: if it fails, every in-container local-*
      # model 500s and a loopback health probe can't see it. Surface it as FAILED,
      # not a warn behind a green row (council finding #3).
      if ! _dep_ollama_patch_env; then
        err "$svc: OLLAMA_HOST=0.0.0.0 re-assert FAILED — in-container local-* models will 500. Fix: 'lsof -nP -iTCP:11434' (want *:11434), then 'vz-ai-stack.sh doctor ollama_models'"
        RESULT=FAILED; return 0
      fi
    else
      warn "$svc: could not load deps.sh to re-assert OLLAMA_HOST — falling back to brew services restart (may rebind 127.0.0.1; LiteLLM local-* models would 500)"
      brew services restart "$svc" || true
    fi
  else
    brew services restart "$svc" || true
  fi
  RESULT="upgraded"   # driver reconciles to 'up-to-date' when the brew version string didn't move
}

# _openshell_exec_retry <sandbox> <cmd...> — run `openshell sandbox exec -n <sandbox> --no-tty`
# with a BOUNDED retry on the TRANSIENT relay signature ONLY. The OpenShell gateway occasionally
# answers `status: DeadlineExceeded, message: "relay open timed out"` — a gRPC transient that
# should NOT red a whole upgrade (the sandbox is fine, the relay blipped). But a REAL in-sandbox
# error (PyPI 403, a resolver conflict, a genuine crash) must FAIL immediately — its output does
# NOT carry the relay signature, so it is never retried. Echoes combined stdout+stderr; returns the
# command's exit code (or the last attempt's on give-up). 3 attempts, 3s backoff (≤6s worst case,
# perl-alarm-free — no coreutils `timeout` on the target host). Reads `$svc` from the caller for the msg.
_openshell_exec_retry() {
  local sandbox="$1"; shift
  local attempt out rc
  for attempt in 1 2 3; do
    out="$(openshell sandbox exec -n "$sandbox" --no-tty </dev/null -- "$@" 2>&1)"; rc=$?
    if (( rc == 0 )); then printf '%s' "$out"; return 0; fi
    # Retry ONLY the relay/deadline transient — never a real in-sandbox failure. Signatures are
    # the ones actually OBSERVED in this repo's incident history (CHANGELOG + 04f_hermes_fleet.sh);
    # do NOT add speculative gRPC codes (e.g. "status: Unavailable" has zero occurrences here).
    if (( attempt < 3 )) && grep -qiE 'relay open timed out|DeadlineExceeded|relay .*(timed out|timeout)' <<<"$out"; then
      warn "${svc:-openshell}: OpenShell relay transient (attempt $attempt/3: $(grep -oiE 'relay open timed out|DeadlineExceeded' <<<"$out" | head -1)) — retrying in 3s…" >&2
      sleep 3; continue
    fi
    printf '%s' "$out"; return "$rc"
  done
}

up_openshell() {
  local svc="$1" sandbox phase script
  sandbox="$(svc_sandbox "$svc")"
  phase="$(svc_phase "$svc")"
  STRATEGY=openshell

  # Same install-stamp guard as up_phase_rerun (council should-fix): never re-run a
  # phase's full installer for a service not installed on this host — otherwise
  # `upgrade all` could unsolicited-install pi-v1 (and mint a LiteLLM key) / a
  # sandbox on a box that never opted in. Core always-installed services
  # (openshell / hermes_*) carry their stamp, so they are never skipped.
  if [[ "$phase" != "-" && -n "$phase" ]] && declare -f stamp_check >/dev/null 2>&1 && ! stamp_check "$phase"; then
    note "$svc: phase $phase not installed on this host (no stamp) — skipping ('upgrade' not 'install'; run 'vz-ai-stack.sh install $phase')"
    RESULT="skipped (not installed)"; return 0
  fi

  case "$svc" in
    pi)
      # PyPI is proxy-403'd in pi-v1; phase 15 pre-stages a tarball. Never raw pip -U.
      if (( DRY )); then
        note "PLAN $svc openshell: openshell sandbox exec -n $sandbox --no-tty </dev/null -- bash -c 'hermes --version'; would re-run phase $phase directly"
        : # dry-run: NO live sandbox probe (a dry-run must change/touch nothing)
        RESULT="planned"; return 0
      fi
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      # Phase 15 re-stages hermes in the pi sandbox but short-circuits to a no-op when
      # already current; the in-sandbox version isn't readable (STRATEGY=openshell →
      # reconcile can't help), so a phase exit-0 does NOT prove a version moved. Report
      # 're-asserted' (honest; matches the sibling openshell cases), not a false 'upgraded'.
      if "$BASH" "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
      ;;
    hermes_fleet)
      if (( DRY )); then
        note "PLAN $svc openshell: openshell sandbox exec -n $sandbox --no-tty </dev/null -- hermes --version; would: pip -U hermes-agent in $sandbox + re-run phase $phase"
        : # dry-run: NO live sandbox probe (a dry-run must change/touch nothing)
        RESULT="planned"; return 0
      fi
      # Do NOT swallow the pip result with `|| true` then claim 'upgraded' off the
      # phase re-run (council finding #2, hermes 0.16→0.18 miss). Capture the exit
      # code AND parse pip's own outcome so RESULT reflects what actually happened
      # to the version — the installed hermes lives inside the sandbox, so
      # svc_installed_version can't read it and reconcile can't help here.
      # A missing 'sandbox:' in services.yml → svc_sandbox returns "-" → `exec -n "-"`
      # dies with a cryptic "sandbox not found" that misreads as a PyPI 403. Fail CLEAR.
      if [[ -z "$sandbox" || "$sandbox" == "-" ]]; then
        err "$svc: no 'sandbox:' declared in services.yml → can't exec the in-sandbox pip upgrade. Add 'sandbox: hermes-fleet-v1' under services.$svc."
        RESULT=FAILED; return 0
      fi
      local _pip_rc=0 _pip_out
      # Bounded retry on a TRANSIENT OpenShell relay timeout (a gRPC blip shouldn't red the upgrade);
      # a REAL pip error (PyPI 403, resolver conflict) carries no relay signature → fails immediately.
      _pip_out="$(_openshell_exec_retry "$sandbox" bash -c 'python3 -m pip install --upgrade hermes-agent')" || _pip_rc=$?
      printf '%s\n' "$_pip_out" | tail -5
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      if (( _pip_rc != 0 )); then
        # PyPI 403 through the proxy / expired sandbox token / resolver conflict:
        # hermes was NOT upgraded. Re-assert config (best-effort) but report the truth.
        warn "$svc: in-sandbox 'pip install --upgrade hermes-agent' FAILED (rc=$_pip_rc) — hermes NOT upgraded (PyPI 403 via proxy? sandbox token expired? persistent 'relay open timed out' after 3 retries — which can ALSO be a version-skewed openshell client shadowing the gateway binary, see 'install 04' diagnostics?). Pre-stage a tarball like Phase 15, or re-run 'install 04f'."
        "$BASH" "$script" >/dev/null 2>&1 || true
        RESULT="FAILED (pip)"; return 0
      fi
      local _newv
      _newv="$(sed -n 's/.*Successfully installed[^,]*hermes-agent-\([0-9][^ ]*\).*/\1/p' <<<"$_pip_out" | tail -1)"
      # Plumb the pip-reported version into the summary's VERSION column — the
      # in-sandbox hermes version isn't readable by svc_installed_version, so
      # without this the flagship service would show '-' even on a real 0.16→0.18.
      if [[ -n "$_newv" ]]; then note "$svc: hermes-agent now $_newv (pip)"; VER_OVERRIDE="$_newv"; fi
      # Trust pip's own report of what changed rather than the always-green phase re-run.
      if   grep -q 'Successfully installed' <<<"$_pip_out"; then RESULT="upgraded"
      elif grep -qi 'already satisfied'     <<<"$_pip_out"; then RESULT="up-to-date"
      else RESULT="done (unverified)"; fi
      # Still re-assert the gateway/profile config via the phase; a phase failure is real.
      if ! "$BASH" "$script"; then RESULT=FAILED; fi
      # Honesty guard: the phase re-run (04f → Sourcegraph MCP setup) can DOWNGRADE hermes
      # via a pinned pip install — a silent revert that would over-claim "upgraded → $VER_OVERRIDE".
      # Re-read the ACTUAL in-sandbox version; if it regressed below what pip installed, tell
      # the truth (never claim a bump that got reverted). §24 council finding.
      if [[ -n "$VER_OVERRIDE" && "$RESULT" != FAILED* ]]; then
        local _postv
        # Retry a transient relay blip HERE too (§24 both reviewers): a flake on THIS read — not
        # the pip call — would otherwise leave _postv empty and SILENTLY no-op the revert-detection
        # guard below, hiding a real pinned-dep downgrade. The helper folds stderr into stdout, so a
        # persistent relay error still seds to empty (skip, unchanged fallback) after 3 bounded tries.
        # `|| true`: on a persistent relay failure OR a broken hermes entrypoint,
        # _openshell_exec_retry returns non-zero. Without this guard the bare
        # command-substitution assignment aborts the WHOLE `upgrade all` run under
        # `set -Eeuo pipefail` + inherit_errexit (killing every remaining service),
        # instead of falling through to the empty-`_postv` "skip, unchanged" path the
        # comment above already assumes. Mirrors the guarded sibling at the pip call.
        # (2026-07-05 takeover fix.)
        _postv="$(_openshell_exec_retry "$sandbox" bash -c 'hermes --version 2>/dev/null' | sed -n 's/.*[vV]\([0-9][0-9.]*\).*/\1/p' | head -1)" || true
        if [[ -n "$_postv" && "$_postv" != "$VER_OVERRIDE" ]]; then
          warn "$svc: hermes is $_postv after the config re-assert, NOT the $VER_OVERRIDE that pip installed — a pinned dep (e.g. Sourcegraph MCP) reverted it."
          RESULT="FAILED (reverted to $_postv)"; VER_OVERRIDE="$_postv"
        fi
      fi
      ;;
    hermes_telegram)
      # Shares hermes-fleet-v1 with hermes_fleet — NEVER pip here. Just re-assert
      # the gateway by re-running phase 20 directly. Order-independent.
      if (( DRY )); then
        note "PLAN $svc sandbox-daemon: sandbox upgrade owned by hermes_fleet; would re-run phase $phase directly to re-assert gateway only (no pip)"
        RESULT="planned"; return 0
      fi
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      # Re-running the phase re-asserts the gateway config; it does NOT bump a
      # version (no pip here) — so report 're-asserted', not a false 'upgraded'.
      if TELEGRAM_NOPIP=1 "$BASH" "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
      ;;
    *)
      # Any other openshell-type without a special case: re-run its phase. This
      # re-asserts config (no version-moving step), so 're-asserted', not 'upgraded'.
      if (( DRY )); then
        note "PLAN $svc openshell: would re-run phase $phase directly"
        RESULT="planned"; return 0
      fi
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      if "$BASH" "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
      ;;
  esac
}

# --- exhaustive upgrade: direct version-bump + phase-rerun (Part B) -----------
# Every manual-typed service now DOES something on upgrade instead of a no-op note:
# a service with a declared services.yml `upgrade:` block is version-bumped by its
# method handler; anything else re-runs its install phase (the phase owns the real
# mechanism — no duplicated per-service upgrade logic) with AI_STACK_UPGRADE=1 so a
# version-fetching phase can force-latest. Config/pinned/pattern services simply
# re-assert. NOTHING silently falls through to "manual note".

# up_phase_rerun <svc> — re-run the service's install phase DIRECTLY (lock-free,
# like up_openshell) with AI_STACK_UPGRADE=1. Honest fallback: re-asserts/upgrades
# via the phase's OWN logic. If no phase resolves, degrade to the note.
#
# AI_STACK_UPGRADE=1 CONTRACT (a phase may read it; it is set ONLY here, on the
# upgrade path — never on a plain `install`). It signals "upgrade mode" and drives
# behavior in BOTH directions, so a phase reader is explicit about which:
#   - DO-MORE: 04f_hermes_fleet re-runs `pip install --upgrade hermes-agent` even
#     when hermes is already present (force a version bump).
#   - DO-LESS: the opt-in sim phases (32? no — 33/34/37) SKIP their live model
#     smoke + embedder pre-fetch (no unsolicited metered inference / local-model
#     load on a routine `upgrade`), re-assert config, and stamp.
# CAVEAT: `AI_STACK_UPGRADE=1 vz-ai-stack.sh install 33` therefore skips the smoke
# too — the flag means the mode, not the entrypoint. Use a plain `install` (or
# `test <phase>`) for the full verified smoke.
up_phase_rerun() {
  local svc="$1" phase script
  phase="$(svc_phase "$svc")"
  STRATEGY=phase-rerun
  if [[ "$phase" == "-" || -z "$phase" ]]; then up_manual_note "$svc"; return 0; fi
  script="$(resolve_phase_script_inline "$phase")"
  if [[ -z "$script" ]]; then err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0; fi
  # DO NOT re-run a full install phase for a service that was never installed on
  # this host (council finding #5): `upgrade all` iterates the enabled CATALOG,
  # and re-running an opt-in sim's phase would INSTALL it unsolicited AND run its
  # live model smoke — billing a metered route / loading a local model, colliding
  # with the hard NEVER-load-local-models directive. The install stamp is the
  # cheap installed-vs-catalog signal; absent → skip with a visible row.
  # (An installed service's stamp is present → the phase runs and short-circuits
  # on its own precheck, so no smoke fires there either.)
  if declare -f stamp_check >/dev/null 2>&1 && ! stamp_check "$phase"; then
    note "$svc: phase $phase is not installed on this host (no stamp) — skipping (this is 'upgrade', not 'install'; run 'vz-ai-stack.sh install $phase' to install it)"
    RESULT="skipped (not installed)"; return 0
  fi
  if (( DRY )); then
    note "PLAN $svc phase-rerun: AI_STACK_UPGRADE=1 bash installer/phases/${phase}_*.sh (re-assert/upgrade via its own installer)"
    RESULT="planned"; return 0
  fi
  note "$svc: re-running phase $phase to re-assert/upgrade (AI_STACK_UPGRADE=1)…"
  if AI_STACK_UPGRADE=1 "$BASH" "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
}

# up_npm_global <svc> — npm install -g <upgrade.target>@latest (+ optional restart).
up_npm_global() {
  local svc="$1" pkg restart
  pkg="$(svc_upgrade "$svc" target)"; restart="$(svc_upgrade "$svc" restart)"
  STRATEGY=npm-global
  [[ "$pkg" == "-" || -z "$pkg" ]] && { err "$svc: upgrade.method npm-global needs upgrade.target (npm pkg)"; RESULT=FAILED; return 0; }
  if (( DRY )); then note "PLAN $svc npm-global: npm install -g ${pkg}@latest$([[ "$restart" != "-" ]] && echo "  (then restart $restart)")"; RESULT="planned"; return 0; fi
  command -v npm >/dev/null 2>&1 || { warn "$svc: npm not on PATH — skipping"; RESULT="skipped (no npm)"; return 0; }
  if npm install -g "${pkg}@latest" 2>&1 | tail -3; then RESULT="upgraded"; else err "$svc: npm install -g ${pkg}@latest failed"; RESULT=FAILED; return 0; fi
  # Only restart the dependent service if the npm upgrade actually succeeded —
  # restarting after a FAILED upgrade would just recreate on the old artifact + mask the failure.
  # MUST be an `if` (not a trailing `[[ ]] && {…}`): as the function's LAST statement the
  # `&&` list returns 1 whenever there's no restart (restart="-", the common case, e.g.
  # byterover_cli) — and a non-zero return from this function, called bare by up_by_method,
  # trips `set -Eeuo pipefail`+the ERR trap and ABORTS the whole `upgrade all` run. An `if`
  # with a false condition returns 0, so the function ends clean. (2026-07-14 crash fix.)
  if [[ "$RESULT" == "upgraded" && "$restart" != "-" && -n "$restart" ]]; then
    note "$svc: restarting $restart"
    recreate_via_start_script "$restart" || warn "$svc: restart of $restart returned non-zero (non-fatal)"
  fi
}

# up_uv_venv <svc> — uv pip install --python <upgrade.venv>/bin/python -U <upgrade.pkg>.
# For UNPINNED libs only (a version-pinned service should use phase-rerun instead).
up_uv_venv() {
  local svc="$1" venv pkg py
  venv="$(svc_upgrade "$svc" venv)"; pkg="$(svc_upgrade "$svc" pkg)"
  STRATEGY=uv-venv
  { [[ "$venv" == "-" || -z "$venv" ]] || [[ "$pkg" == "-" || -z "$pkg" ]]; } && { err "$svc: uv-venv needs upgrade.venv + upgrade.pkg"; RESULT=FAILED; return 0; }
  py="$AI_STACK/$venv/bin/python"
  if (( DRY )); then note "PLAN $svc uv-venv: uv pip install --python $venv/bin/python -U $pkg"; RESULT="planned"; return 0; fi
  command -v uv >/dev/null 2>&1 || { warn "$svc: uv not on PATH — skipping"; RESULT="skipped (no uv)"; return 0; }
  [[ -x "$py" ]] || { warn "$svc: venv missing ($py) — run its install phase first"; RESULT="skipped (no venv)"; return 0; }
  # shellcheck disable=SC2086 -- pkg may carry pip specifiers; intentional word-split.
  if uv pip install --python "$py" -U $pkg 2>&1 | tail -3; then RESULT="upgraded"; else RESULT=FAILED; return 0; fi
}

# up_git_pull <svc> — git -C <upgrade.dir|target> pull --ff-only (clone-only artifacts).
up_git_pull() {
  local svc="$1" dir abs
  dir="$(svc_upgrade "$svc" dir)"; [[ "$dir" == "-" ]] && dir="$(svc_upgrade "$svc" target)"
  STRATEGY=git-pull
  [[ "$dir" == "-" || -z "$dir" ]] && { err "$svc: git-pull needs upgrade.dir (or upgrade.target)"; RESULT=FAILED; return 0; }
  abs="$AI_STACK/$dir"
  if (( DRY )); then note "PLAN $svc git-pull: git -C $dir pull --ff-only"; RESULT="planned"; return 0; fi
  [[ -d "$abs/.git" ]] || { warn "$svc: $abs is not a git clone — run its install phase first"; RESULT="skipped (no clone)"; return 0; }
  if git -C "$abs" pull --ff-only 2>&1 | tail -3; then RESULT="upgraded"; else RESULT=FAILED; return 0; fi
}

# up_by_method <svc> — dispatch on services.yml `upgrade.method`; no block → phase re-run.
up_by_method() {
  local svc="$1" method
  svc_has_upgrade "$svc" || { up_phase_rerun "$svc"; return 0; }
  method="$(svc_upgrade "$svc" method)"
  case "$method" in
    npm-global)  up_npm_global "$svc" ;;
    uv-venv)     up_uv_venv "$svc" ;;
    git-pull)    up_git_pull "$svc" ;;
    rebuild)
      STRATEGY=rebuild
      if (( DRY )); then note "PLAN $svc rebuild: bash bin/start-$svc.sh --recreate"; RESULT="planned"; return 0; fi
      if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
      if recreate_via_start_script "$svc"; then RESULT="upgraded"; else RESULT=FAILED; fi ;;
    phase-rerun) up_phase_rerun "$svc" ;;
    *) warn "$svc: unknown upgrade.method '$method' — falling back to phase re-run"; up_phase_rerun "$svc" ;;
  esac
}

# --- host npm globals not modeled as services.yml services -------------------
# Meridian (Claude subscription daemon) + Claude Code CLI are host `npm i -g`
# packages, so `upgrade all` covers them too (operator asked for them explicitly).
# Codex is invoked via `npx --yes @openai/codex` = ALWAYS-latest, so it needs no
# upgrade step. name:pkg pairs.
HOST_NPM_GLOBALS=( "meridian:@rynfar/meridian" "claude-code:@anthropic-ai/claude-code" )

# is_host_global returns 1 for a non-member ON PURPOSE (it gates an `if`); codex is
# a valid host-global NAME (handled specially) even though it's not npm-installed.
is_host_global() { local n="$1"; [[ "$n" == codex ]] && return 0; local p; for p in "${HOST_NPM_GLOBALS[@]}"; do [[ "${p%%:*}" == "$n" ]] && return 0; done; return 1; }
# host_global_pkg ALWAYS exits 0 (echoes "" if not found) — it's called in $(...)
# under set -e + the ERR trap, so a bare non-zero from the loop would abort the run.
host_global_pkg() { local n="$1" p; for p in "${HOST_NPM_GLOBALS[@]}"; do [[ "${p%%:*}" == "$n" ]] && { printf '%s' "${p#*:}"; return 0; }; done; return 0; }

# up_host_npm_global <name> — npm install -g <pkg>@latest; records its own summary row
# WITH an honest RESULT + VERSION. These host globals bypass upgrade_one, so they miss
# its reconcile — do it here: npm exits 0 even on a no-op ('changed 0 packages'), so
# compare the real installed version before/after and only claim 'upgraded' on a move.
up_host_npm_global() {
  local name="$1" pkg
  STRATEGY=npm-global; RESULT=""
  # codex is npx-always-latest — no install step. Short-circuit BEFORE the pkg lookup.
  if [[ "$name" == codex ]]; then
    note "codex: invoked via 'npx --yes @openai/codex' (always fetches latest) — nothing to upgrade"
    record_row codex npm-global "auto-latest (npx)" "-"; return 0
  fi
  pkg="$(host_global_pkg "$name")"
  if (( DRY )); then note "PLAN $name npm-global (host): npm install -g ${pkg}@latest"; record_row "$name" npm-global "planned" "-"; return 0; fi
  if ! command -v npm >/dev/null 2>&1; then record_row "$name" npm-global "skipped (no npm)" "-"; return 0; fi
  local _before _after verdisp="-"
  _before="$(_npm_global_version "$pkg")"
  if npm install -g "${pkg}@latest" 2>&1 | tail -3; then RESULT="upgraded"; else RESULT=FAILED; err "$name: npm install -g ${pkg}@latest failed"; fi
  if [[ "$RESULT" == "upgraded" ]]; then
    _after="$(_npm_global_version "$pkg")"
    RESULT="$(reconcile_result "$RESULT" "${_before:--}" "${_after:--}")"   # no-op → 'up-to-date'
    if   [[ -n "$_after" && "$_after" != "$_before" ]]; then verdisp="${_before:--}→${_after}"
    elif [[ -n "$_after" ]];                              then verdisp="$_after"; fi
    # Restart heads-up ONLY on a real move (the package actually changed on disk).
    if [[ "$RESULT" == "upgraded" ]]; then
      case "$name" in
        claude-code) note "claude-code upgraded on disk — restart your Claude Code session to run the new version." ;;
        meridian)    note "meridian package upgraded — restart the daemon to run it: bash bin/start-meridian.sh" ;;
      esac
    fi
  fi
  # host globals have no health probe → REVERIFY is 'n/a' on success, '-' on failure
  # (mirrors upgrade_one: FAILED* gets no probe). 'n/a' must NOT read as a failure.
  local _rev="n/a"; [[ "$RESULT" == FAILED* ]] && _rev="-"
  record_row "$name" npm-global "$RESULT" "$_rev" "$verdisp"
}

up_manual_note() {
  local svc="$1" phase
  phase="$(svc_phase "$svc")"
  STRATEGY=manual
  if [[ "$phase" != "-" ]]; then
    note "$svc: no separately-upgradable artifact; re-run 'vz-ai-stack.sh install $phase' to re-assert config"
  else
    note "$svc: no separately-upgradable artifact and no resolvable phase; verify manually"
  fi
  RESULT="manual"
}

# --- per-service driver ------------------------------------------------------
upgrade_one() {
  local svc="$1" type
  type="$(svc_type "$svc")"
  RESULT=""
  STRATEGY=""

  # Capture the installed version BEFORE the mutation so we can prove afterwards
  # whether it actually moved (council finding #1: the summary must never imply a
  # bump that didn't happen). Local/cheap probe; "-" when not knowable.
  local VER_BEFORE VER_AFTER
  VER_BEFORE="$(svc_installed_version "$svc" 2>/dev/null || echo -)"
  VER_OVERRIDE=""   # a handler (e.g. up_openshell) may set the observed new version (global, reset per svc)

  # Override hook: an explicit `upgrade:` block in services.yml WINS over the type's
  # default handler (e.g. hermes_workspace is 'compose' but must phase-rerun to re-resolve
  # the latest agent image, not blind-pull the old pin). Manual types already route to
  # up_by_method, so this only changes docker/compose/brew/openshell services that opt in.
  if svc_has_upgrade "$svc"; then up_by_method "$svc"; else
  case "$type" in
    docker)                                  up_docker "$svc" ;;
    compose|docker-compose)                  up_compose "$svc" ;;
    brew-service)                            up_brew "$svc" ;;
    openshell|hermes-profiles)               up_openshell "$svc" ;;
    sandbox-daemon)                          up_openshell "$svc" ;;
    cli-only|clone-only|npm-global|pip-package|litellm-feature|agent-pattern|paperclip-plugin|litellm-virtual-key)
                                             up_by_method "$svc" ;;
    # python-bg / node-bg are host background daemons (docs_mcp, paperclip, claw3d,
    # unsloth, aionui, openwork, understand). No pullable artifact / compose stack;
    # "upgrade" = version-bump via a declared upgrade: block, else re-run the install
    # phase (AI_STACK_UPGRADE=1) to re-assert config + restart. up_by_method routes both.
    python-bg|node-bg)                       up_by_method "$svc" ;;
    *)
      STRATEGY="$type"
      RESULT="skipped (unknown type)"
      warn "$svc: unknown type '$type'; skipping"
      ;;
  esac
  fi

  # Reconcile the OPTIMISTIC handlers (they set 'upgraded' on any exit-0) against
  # the observed installed-version delta, so a no-op can't masquerade as a bump.
  # docker keeps its OWN digest delta (up_docker sets up-to-date/upgraded); compose
  # now reconciles too via the _iv_compose digest fingerprint; up_openshell already
  # set an honest RESULT from pip's real outcome; phase-rerun stays 're-asserted'.
  VER_AFTER="$(svc_installed_version "$svc" 2>/dev/null || echo -)"
  case "$STRATEGY" in
    brew|npm-global|uv-venv|git-pull|compose)
      RESULT="$(reconcile_result "$RESULT" "$VER_BEFORE" "$VER_AFTER")"
      ;;
  esac
  # Build the VERSION display: a handler-reported new version (e.g. hermes_fleet's
  # in-sandbox pip) wins; else unchanged → just the version; a real move →
  # before→after; unknowable → '-'.
  local verdisp
  if   [[ -n "$VER_OVERRIDE" ]];            then verdisp="$VER_OVERRIDE"
  elif [[ "$VER_BEFORE" == "$VER_AFTER" ]]; then verdisp="$VER_BEFORE"
  else                                           verdisp="${VER_BEFORE}→${VER_AFTER}"; fi
  [[ -z "$verdisp" ]] && verdisp="-"

  # Dry-run, manual, skip, planned, and FAILED paths don't get a live reverify.
  local rev="-"
  if (( DRY == 0 )); then
    case "$RESULT" in
      FAILED*|skipped*|manual|planned) rev="-" ;;
      *) rev="$(reverify "$svc" "$STRATEGY")"
         # Fail the run ONLY when THIS run actually CHANGED the artifact and the post-change
         # probe RAN and FAILED ('warn') — "the mutation we just did left the service unhealthy"
         # (SOUL §4/§18 end-to-end DoD; the exit gate reads RESULT, field 3). Two RESULT values
         # mean a real mutation ran: 'upgraded' (confirmed move) and 'done (unverified)' (a real
         # npm/git/brew/rebuild/in-sandbox-pip ran but the version couldn't be read back — still
         # a change). Both trip the gate. We must NOT fail a no-op: 'up-to-date' (digest unchanged,
         # never recreated) and 're-asserted' (a phase re-run that commonly SHORT-CIRCUITS on its
         # precheck, changing nothing) are not this run's verdict — flagging them was the false
         # alarm that red-flagged an untouched up-to-date litellm (2026-07-14). Their warn stays
         # visible in the REVERIFY column (informational) but doesn't fail the exit; doctor/status
         # own ambient health. 'ok'/'n/a' are never failures. Explicit `if` so the arm returns 0.
         if [[ "$rev" == "warn" && ( "$RESULT" == "upgraded" || "$RESULT" == "done (unverified)" ) ]]; then
           RESULT="FAILED (unhealthy: ${RESULT})"
         fi
         ;;
    esac
  fi
  record_row "$svc" "$STRATEGY" "$RESULT" "$rev" "$verdisp"
}

# --- main --------------------------------------------------------------------
upgrade_main() {
  local target="" arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run)        DRY=1 ;;
      --check)          CHECK=1 ;;
      --outdated)       OUTDATED=1 ;;
      --json)           JSON=1 ;;
      --all|-a)         ALL_ROWS=1 ;;
      --no-check)       NO_CHECK=1 ;;     # skip the pre-upgrade version report
      check)            CHECK=1 ;;        # friendly bare aliases
      outdated)         OUTDATED=1 ;;
      -h|--help)        upgrade_usage; exit 0 ;;
      -*)               err "Unknown flag: $arg"; upgrade_usage; exit 2 ;;
      *)
        if [[ -z "$target" ]]; then target="$arg"
        else err "Unexpected extra argument: $arg"; upgrade_usage; exit 2; fi
        ;;
    esac
  done

  if (( CHECK && OUTDATED )); then
    err "--check and --outdated are mutually exclusive."; upgrade_usage; exit 2
  fi
  # --all (ALL_ROWS) is only consumed by print_check_report (the bare `--check` table);
  # the --outdated path never renders that table, so --all is inert here. Warn (don't
  # abort — the command is still valid) so `upgrade --all --outdated` doesn't leave the
  # operator believing --all widened the sweep. The exhaustive "everything" motion is
  # `upgrade all` (a target), not the `--all` flag.
  if (( ALL_ROWS && OUTDATED )); then
    warn "--all has no effect with --outdated (it only affects a bare '--check' listing); --outdated already scans every enabled service. Did you mean 'vz-ai-stack.sh upgrade all'?"
  fi

  # Docker-info guard: only blocks docker/compose handlers, not brew/openshell.
  if ! docker info >/dev/null 2>&1; then
    DOCKER_OK=0
    warn "docker unavailable; docker/compose services will be reported 'unknown'/skipped"
  fi

  # --- read-only availability report (no lock, no mutation) ------------------
  if (( CHECK )); then
    local -a list=(); collect_targets list "${target:-all}"
    local svc
    for svc in "${list[@]}"; do
      [[ "$(svc_type "$svc")" == "unknown" ]] && { err "Unknown service: $svc"; exit 2; }
      check_one "$svc"
      CHECK_ROWS+=("$svc"$'\t'"$(svc_type "$svc")"$'\t'"$CHECK_CUR"$'\t'"$CHECK_AVAIL"$'\t'"$CHECK_STATUS")
    done
    print_check_report
    return 0
  fi

  # --- build the list to upgrade ---------------------------------------------
  local -a targets=()
  local -a hg_targets=()   # host npm globals (meridian/claude-code/codex)
  # A named host-global target (e.g. `upgrade meridian`) is handled standalone.
  if [[ -n "$target" && "$target" != "all" ]] && is_host_global "$target"; then
    lock_acquire
    _arm_upgrade_traps   # EXIT keeps the summary+lock on an abort; INT/TERM stop the run (supersedes the lock's traps)
    hdr "Upgrade plan ($([[ $DRY == 1 ]] && echo dry-run || echo live))"
    up_host_npm_global "$target"
    print_summary
    local row res
    for row in "${SUMMARY[@]}"; do res="$(printf '%s' "$row" | cut -f3)"; [[ "$res" == FAILED* ]] && { err "Upgrade FAILED."; exit 1; }; done
    return 0
  fi
  if (( OUTDATED )); then
    # Run the same read-only check across all enabled, then upgrade only the
    # ones that came back 'update-available'.
    local -a list=(); collect_targets list "${target:-all}"
    local svc; local -a skipped_manual=() unconfirmed=()
    hdr "Scanning for available updates…"
    for svc in "${list[@]}"; do
      check_one "$svc"
      case "$CHECK_STATUS" in
        update-available)
          targets+=("$svc")
          note "  $svc: $CHECK_STATUS ($CHECK_CUR → $CHECK_AVAIL)" ;;
        manual)
          # No version oracle for --outdated (docker/compose/brew currency only): the
          # sandbox/CLI/pip/fleet plane — the in-sandbox hermes agent, pi, mempalace,
          # docs_mcp, etc. NEVER upgraded by --outdated (can't reach the gate above).
          skipped_manual+=("$svc") ;;
        unknown|rebuild)
          # Currency NOT confirmed: a docker/compose image whose registry digest we
          # couldn't read (proxy/Zscaler-blocked, or docker down → DOCKER_OK=0) or a
          # locally-built image. --outdated leaves these untouched too — disclose them
          # SEPARATELY so a proxy-blocked registry can't masquerade as full coverage
          # (parity with --check's print_check_report 'unconfirmed' warning; audit F3).
          unconfirmed+=("$svc") ;;
      esac
    done
    # ALWAYS disclose what --outdated could NOT act on — not only when nothing is
    # outdated. A rolling upstream (litellm/phoenix/qdrant/…) almost always shows >=1
    # outdated, so the old disclosure (gated on targets==0) effectively never printed
    # and a green summary implied a coverage it never had (audit F3). Two honest buckets:
    if (( ${#skipped_manual[@]} )); then
      note "${#skipped_manual[@]} service(s) NOT version-checkable by --outdated — the sandbox/CLI/pip/fleet plane (in-sandbox hermes agent, pi, mempalace, docs_mcp …): ${skipped_manual[*]}"
      note "  → for those (plus the host globals meridian/claude-code, which aren't modeled as services) run 'vz-ai-stack.sh upgrade all', or 'upgrade hermes' for the hermes surfaces, or upgrade one by name."
    fi
    if (( ${#unconfirmed[@]} )); then
      warn "${#unconfirmed[@]} service(s) with currency NOT confirmed (registry/proxy unreachable or locally-built) — NOT upgraded by --outdated: ${unconfirmed[*]}. Re-check when the registry is reachable, or 'upgrade <svc>' to rebuild/pull explicitly."
    fi
    if (( ${#targets[@]} == 0 )); then
      ok "Nothing auto-checkable is outdated — docker/compose/brew currency is up to date."
      return 0
    fi
    ok "${#targets[@]} service(s) to upgrade: ${targets[*]}"
  else
    if [[ -z "$target" ]]; then
      err "upgrade requires a target: a service name, 'all', --check, or --outdated."
      upgrade_usage
      exit 2
    fi
    if [[ "$target" == "all" ]]; then
      collect_targets targets all
      hg_targets=(meridian claude-code codex)   # exhaustive: host npm globals too
    elif [[ "$target" == "hermes" ]]; then
      collect_targets targets hermes            # group alias → all enabled hermes surfaces
      (( ${#targets[@]} )) || { err "no enabled hermes services to upgrade"; exit 2; }
      ok "upgrade hermes → ${targets[*]}"
    else
      if [[ "$(svc_type "$target")" == "unknown" ]]; then
        err "Unknown service: $target"
        echo "Upgradable (enabled) services:" >&2
        local name
        while IFS= read -r name; do
          [[ -z "$name" ]] && continue
          [[ "$(svc_enabled "$name")" == "true" ]] && printf '  - %s\n' "$name" >&2
        done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
        exit 2
      fi
      [[ "$(svc_enabled "$target")" != "true" ]] && warn "$target is disabled; upgrading anyway (explicit intent)"
      targets=("$target")
    fi
  fi

  # --- pre-upgrade version report (operator asked to SEE installed vs available
  # BEFORE upgrading). Read-only; bounded. --outdated already printed a scan;
  # --no-check skips this (offline/fast). Shows every target, including 'manual'.
  if (( NO_CHECK == 0 && OUTDATED == 0 )) && (( ${#targets[@]} > 0 )); then
    note "Checking installed vs available versions before upgrading… (bounded; pass --no-check to skip)"
    CHECK_ROWS=()
    local psvc
    for psvc in "${targets[@]}"; do
      [[ "$(svc_type "$psvc")" == "unknown" ]] && continue
      check_one "$psvc"
      CHECK_ROWS+=("$psvc"$'\t'"$(svc_type "$psvc")"$'\t'"$CHECK_CUR"$'\t'"$CHECK_AVAIL"$'\t'"$CHECK_STATUS")
    done
    PREFLIGHT=1; print_check_report; PREFLIGHT=0
    CHECK_ROWS=()
  fi

  # --- mutate: acquire the lock and run the upgrade loop ---------------------
  lock_acquire
  _arm_upgrade_traps   # EXIT keeps the summary+lock on an abort; INT/TERM stop the run (supersedes the lock's traps)

  hdr "Upgrade plan ($([[ $DRY == 1 ]] && echo dry-run || echo live))"
  local svc
  for svc in "${targets[@]}"; do
    upgrade_one "$svc"
  done
  # Exhaustive: host npm globals not modeled as services (bare `upgrade all`).
  local hg
  for hg in "${hg_targets[@]}"; do
    up_host_npm_global "$hg"
  done

  print_summary

  # Exit 1 iff any hard FAILED.
  local row res
  for row in "${SUMMARY[@]}"; do
    res="$(printf '%s' "$row" | cut -f3)"
    [[ "$res" == FAILED* ]] && { err "One or more upgrades FAILED."; exit 1; }
  done
  return 0
}

upgrade_main "$@"
