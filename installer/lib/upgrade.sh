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
# This runs as its OWN process (vz-ai-stack.sh dispatches `bash upgrade.sh "$@"`),
# so the lock's EXIT/INT/TERM trap (common.sh) cleanly removes LOCKDIR on exit.

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
SUMMARY=()             # rows: "svc<TAB>strategy<TAB>result<TAB>reverify"
CHECK_ROWS=()          # rows: "svc<TAB>type<TAB>current<TAB>available<TAB>status"
CHECK_STATUS=""; CHECK_CUR=""; CHECK_AVAIL=""   # set by check_one

# --- usage -------------------------------------------------------------------
upgrade_usage() {
  cat <<'EOF'
vz-ai-stack.sh upgrade <service|all> [--dry-run]   upgrade a service (or all enabled)
vz-ai-stack.sh upgrade --check [service|all]       READ-ONLY: show which have an update available
vz-ai-stack.sh upgrade --outdated [--dry-run]      upgrade ONLY the services found outdated
vz-ai-stack.sh upgrade --check --all               include non-checkable (manual) services too
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

  Typical flow:
    vz-ai-stack.sh upgrade --check        # see what's available
    vz-ai-stack.sh upgrade --outdated     # upgrade everything that's behind
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
        local r; r="$(img_remote_digest "$image")"; [[ -n "$r" ]] && CHECK_AVAIL="${r:0:19}…"
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
}

# collect_targets <out-array-name> [target] — fill an array with the enabled
# services to act on (or the single named target).
collect_targets() {
  local -n _out="$1"; local target="${2:-all}" name
  _out=()
  if [[ "$target" == "all" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      [[ "$(svc_enabled "$name")" == "true" ]] && _out+=("$name")
    done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
  else
    _out=("$target")
  fi
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
  [[ -e "${m[0]}" ]] && printf '%s' "${m[0]}"
}

# Recreate a docker service via its per-service start script (lock-free).
# Tries both key forms: bin/start-<key>.sh then bin/start-<key//_/->.sh.
# Echoes ok/warn into the caller's RESULT via return code (0 ok, 1 fail).
recreate_via_start_script() {
  local svc="$1" script
  for script in "$AI_STACK/bin/start-${svc}.sh" "$AI_STACK/bin/start-${svc//_/-}.sh"; do
    if [[ -x "$script" ]]; then
      bash "$script" --recreate
      return $?
    fi
  done
  err "$svc: no start script (tried bin/start-${svc}.sh, bin/start-${svc//_/-}.sh); recreate manually"
  return 1
}

# --- reverify (deterministic; registers NO doctor checks) --------------------
# Echoes "ok" or "warn"; never aborts the run.
reverify() {
  local svc="$1" strategy="$2" h
  h="$(svc_health "$svc")"
  if [[ "$h" != "-" && -n "$h" ]]; then
    if curl -fsS --max-time 10 "$h" >/dev/null 2>&1; then echo ok; else echo warn; fi
    return 0
  fi
  case "$strategy" in
    docker)
      if container_running "$svc"; then echo ok; else echo warn; fi
      ;;
    compose)
      if docker ps --format '{{.Names}}' | grep -qE "^$(svc_project "$svc")(-|$)"; then
        echo ok
      else
        echo warn
      fi
      ;;
    *)
      echo warn   # brew/openshell/manual — no automated probe
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
    if recreate_via_start_script "$svc"; then RESULT="upgraded"; else RESULT=FAILED; fi
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
      if bash "$AI_STACK/bin/start-deerflow.sh" build; then RESULT="upgraded"; else RESULT=FAILED; fi
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
      if bash "$script"; then RESULT="upgraded"; else RESULT=FAILED; fi
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
      local _pip_rc=0 _pip_out
      _pip_out="$(openshell sandbox exec -n "$sandbox" --no-tty </dev/null -- bash -c 'python3 -m pip install --upgrade hermes-agent' 2>&1)" || _pip_rc=$?
      printf '%s\n' "$_pip_out" | tail -5
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      if (( _pip_rc != 0 )); then
        # PyPI 403 through the proxy / expired sandbox token / resolver conflict:
        # hermes was NOT upgraded. Re-assert config (best-effort) but report the truth.
        warn "$svc: in-sandbox 'pip install --upgrade hermes-agent' FAILED (rc=$_pip_rc) — hermes NOT upgraded (PyPI 403 via proxy? sandbox token expired?). Pre-stage a tarball like Phase 15, or re-run 'install 04f'."
        bash "$script" >/dev/null 2>&1 || true
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
      if ! bash "$script"; then RESULT=FAILED; fi
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
      if TELEGRAM_NOPIP=1 bash "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
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
      if bash "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
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
  if AI_STACK_UPGRADE=1 bash "$script"; then RESULT="re-asserted"; else RESULT=FAILED; fi
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
  [[ "$RESULT" == "upgraded" && "$restart" != "-" && -n "$restart" ]] && { note "$svc: restarting $restart"; recreate_via_start_script "$restart" || warn "$svc: restart of $restart returned non-zero (non-fatal)"; }
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

# up_host_npm_global <name> — npm install -g <pkg>@latest; records its own summary row.
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
  if npm install -g "${pkg}@latest" 2>&1 | tail -3; then RESULT="upgraded"; else RESULT=FAILED; err "$name: npm install -g ${pkg}@latest failed"; fi
  # Heads-up: the npm PACKAGE is upgraded but a running daemon/session keeps the OLD
  # code until it restarts — surface the follow-up so the operator isn't surprised.
  if [[ "$RESULT" == "upgraded" ]]; then
    case "$name" in
      claude-code) note "claude-code upgraded on disk — restart your Claude Code session to run the new version." ;;
      meridian)    note "meridian package upgraded — restart the daemon to run it: bash bin/start-meridian.sh" ;;
    esac
  fi
  record_row "$name" npm-global "$RESULT" "-"
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
  else                                           verdisp="$VER_BEFORE→$VER_AFTER"; fi
  [[ -z "$verdisp" ]] && verdisp="-"

  # Dry-run, manual, skip, planned, and FAILED paths don't get a live reverify.
  local rev="-"
  if (( DRY == 0 )); then
    case "$RESULT" in
      FAILED*|skipped*|manual|planned) rev="-" ;;
      *) rev="$(reverify "$svc" "$STRATEGY")" ;;
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
    local svc
    hdr "Scanning for available updates…"
    for svc in "${list[@]}"; do
      check_one "$svc"
      if [[ "$CHECK_STATUS" == "update-available" ]]; then
        targets+=("$svc")
        note "  $svc: $CHECK_STATUS ($CHECK_CUR → $CHECK_AVAIL)"
      fi
    done
    if (( ${#targets[@]} == 0 )); then
      ok "Nothing to upgrade — all auto-checkable services are up to date."
      note "(sandbox/CLI/npm/pip services aren't version-checked; upgrade those by name if needed.)"
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
