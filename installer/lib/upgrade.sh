#!/usr/bin/env bash
# upgrade.sh — `install.sh upgrade <service|all> [--dry-run]`.
#
# Generic, type-dispatched upgrade verb. For each enabled service it pulls/
# rebuilds the new artifact, recreates via the canonical path, then re-verifies
# with a DETERMINISTIC per-service probe (health URL / container_running), NOT a
# doctor substring filter (doctor's filter matches check NAMES — openwebui/etc.
# match zero checks → vacuous green; litellm over-matches a Pi check).
#
# Hard rules (this file owns the install lock, so it must never deadlock):
#   - NEVER shell back to `install.sh install <phase>` (re-acquires the lock →
#     exit 3). Docker recreate goes through the lock-free
#     `bin/start-<svc>.sh --recreate`; phase re-asserts run the phase SCRIPT
#     directly via `bash installer/phases/<id>_*.sh` (no lock_acquire in any).
#   - Loads NO models: ollama upgrade is `brew upgrade ollama` (binary only),
#     LM Studio is a manual note, docker is `docker pull` (image only) + recreate.
#   - Registers NO doctor checks → the 40/40 invariant is untouched.
#
# This runs as its OWN process (install.sh dispatches `bash upgrade.sh "$@"`),
# so the lock's EXIT/INT/TERM trap (common.sh) cleanly removes LOCKDIR on exit.

set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AI_STACK
LIB="$AI_STACK/installer/lib"

# Source only side-effect-free libs. NEVER status.sh (prints the table at top
# level) or install.sh (runs main() on source).
source "$LIB/common.sh"
source "$LIB/env.sh"
source "$LIB/docker.sh"
source "$LIB/prompt.sh"
source "$LIB/services_accessors.sh"

trap 'err "ERR line $LINENO: $BASH_COMMAND (exit=$?)"' ERR

DRY=0
DOCKER_OK=1            # set 0 if `docker info` fails (skip docker/compose)
SUMMARY=()             # rows: "svc<TAB>strategy<TAB>result<TAB>reverify"

# --- usage -------------------------------------------------------------------
upgrade_usage() {
  cat <<'EOF'
install.sh upgrade <service|all> [--dry-run]

  Pull/rebuild + recreate a service (or all enabled), type-dispatched.
  --dry-run    print the per-service plan (current→new) and change nothing.

  Set AI_STACK_ASSUME_YES=1 to auto-accept the version-pinned re-pull prompt.
EOF
}

# --- summary recording -------------------------------------------------------
# record_row svc strategy result reverify
record_row() {
  SUMMARY+=("$1	$2	$3	$4")
}

print_summary() {
  printf '\n'
  hdr "Upgrade summary"
  local fmt='%-22s %-16s %-16s %s\n'
  printf "$fmt" SERVICE STRATEGY RESULT REVERIFY
  printf "$fmt" "----------------------" "----------------" "----------------" "--------"
  local row svc strat res rev
  for row in "${SUMMARY[@]}"; do
    IFS=$'\t' read -r svc strat res rev <<<"$row"
    printf "$fmt" "$svc" "$strat" "$res" "$rev"
  done
}

# --- image helpers -----------------------------------------------------------
# Local RepoDigest for an image, or empty if locally-built/never-pulled.
docker_local_digest() {
  docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || true
}

# image_is_pinned <image> — true (0) for a fixed semver/sha tag, false (1) for
# a rolling tag. No ':' → 'latest' → rolling.
image_is_pinned() {
  local image="$1" tag
  tag="${image##*:}"
  # If the part after the last ':' still contains a '/', there was no tag
  # (e.g. qdrant/qdrant) → treat as latest.
  [[ "$tag" == */* || "$tag" == "$image" ]] && tag="latest"
  case "$tag" in
    latest|main|main-stable|stable|nightly|edge) return 1 ;;
    *) return 0 ;;
  esac
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
    *)
      # honcho, hermes_workspace: plain compose pull && up -d in svc_path.
      if [[ -z "$dir" || "$dir" == "-" ]]; then
        note "$svc: no path declared; run manually: docker compose pull && docker compose up -d"
        RESULT="manual"; return 0
      fi
      if (( DRY )); then
        note "PLAN $svc compose: would: (cd $dir && docker compose pull && docker compose up -d)"
        RESULT="planned"; return 0
      fi
      if (( DOCKER_OK == 0 )); then RESULT="skipped (docker unavailable)"; return 0; fi
      if ( cd "$dir" && docker compose pull && docker compose up -d ); then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
  esac
}

up_brew() {
  local svc="$1"
  STRATEGY=brew
  # ollama only. BINARY ONLY — never `ollama pull` (24GB RAM / KEEP_ALIVE=0).
  if (( DRY )); then
    note "PLAN $svc brew-service: would: brew upgrade $svc && brew services restart $svc (binary only; NO model pull)"
    brew outdated --verbose "$svc" || true
    RESULT="planned"
    return 0
  fi
  brew upgrade "$svc" || true            # no-op if already current
  brew services restart "$svc" || true
  RESULT="upgraded"
}

up_openshell() {
  local svc="$1" sandbox phase script
  sandbox="$(svc_sandbox "$svc")"
  phase="$(svc_phase "$svc")"
  STRATEGY=openshell

  case "$svc" in
    pi)
      # PyPI is proxy-403'd in pi-v1; phase 15 pre-stages a tarball. Never raw pip -U.
      if (( DRY )); then
        note "PLAN $svc openshell: openshell sandbox exec -n $sandbox --no-tty </dev/null -- bash -c 'hermes --version'; would re-run phase $phase directly"
        openshell sandbox exec -n "$sandbox" --no-tty </dev/null -- bash -c 'hermes --version' || true
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
        openshell sandbox exec -n "$sandbox" --no-tty </dev/null -- bash -c 'hermes --version' || true
        RESULT="planned"; return 0
      fi
      openshell sandbox exec -n "$sandbox" --no-tty </dev/null -- bash -c 'python3 -m pip install --upgrade hermes-agent' || true
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      if bash "$script"; then RESULT="upgraded"; else RESULT=FAILED; fi
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
      if TELEGRAM_NOPIP=1 bash "$script"; then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
    *)
      # Any other openshell-type without a special case: re-run its phase.
      if (( DRY )); then
        note "PLAN $svc openshell: would re-run phase $phase directly"
        RESULT="planned"; return 0
      fi
      script="$(resolve_phase_script_inline "$phase")"
      if [[ -z "$script" ]]; then
        err "$svc: cannot resolve phase $phase script"; RESULT=FAILED; return 0
      fi
      if bash "$script"; then RESULT="upgraded"; else RESULT=FAILED; fi
      ;;
  esac
}

up_manual_note() {
  local svc="$1" phase
  phase="$(svc_phase "$svc")"
  STRATEGY=manual
  if [[ "$phase" != "-" ]]; then
    note "$svc: no separately-upgradable artifact; re-run 'install.sh install $phase' to re-assert config"
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

  case "$type" in
    docker)                                  up_docker "$svc" ;;
    compose|docker-compose)                  up_compose "$svc" ;;
    brew-service)                            up_brew "$svc" ;;
    openshell|hermes-profiles)               up_openshell "$svc" ;;
    sandbox-daemon)                          up_openshell "$svc" ;;
    cli-only|clone-only|npm-global|pip-package|litellm-feature|agent-pattern|paperclip-plugin|litellm-virtual-key)
                                             up_manual_note "$svc" ;;
    *)
      STRATEGY="$type"
      RESULT="skipped (unknown type)"
      warn "$svc: unknown type '$type'; skipping"
      ;;
  esac

  # Dry-run, manual, skip, and FAILED paths don't get a live reverify.
  local rev="-"
  if (( DRY == 0 )); then
    case "$RESULT" in
      upgraded|up-to-date)
        rev="$(reverify "$svc" "$STRATEGY")"
        ;;
      *)
        rev="-"
        ;;
    esac
  fi
  record_row "$svc" "$STRATEGY" "$RESULT" "$rev"
}

# --- main --------------------------------------------------------------------
upgrade_main() {
  local target=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY=1 ;;
      -h|--help) upgrade_usage; exit 0 ;;
      -*) err "Unknown flag: $arg"; upgrade_usage; exit 2 ;;
      *)
        if [[ -z "$target" ]]; then target="$arg"
        else err "Unexpected extra argument: $arg"; upgrade_usage; exit 2; fi
        ;;
    esac
  done

  if [[ -z "$target" ]]; then
    err "upgrade requires a target: a service name or 'all'."
    upgrade_usage
    exit 2
  fi

  lock_acquire

  # Docker-info guard: only blocks docker/compose handlers, not brew/openshell.
  if ! docker info >/dev/null 2>&1; then
    DOCKER_OK=0
    warn "docker unavailable; docker/compose services will be skipped"
  fi

  # Build the target list.
  local -a targets=()
  if [[ "$target" == "all" ]]; then
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      [[ "$(svc_enabled "$name")" == "true" ]] && targets+=("$name")
    done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
  else
    # Validate the service exists.
    if [[ "$(svc_type "$target")" == "unknown" ]]; then
      err "Unknown service: $target"
      echo "Upgradable (enabled) services:" >&2
      while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ "$(svc_enabled "$name")" == "true" ]] && printf '  - %s\n' "$name" >&2
      done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
      exit 2
    fi
    if [[ "$(svc_enabled "$target")" != "true" ]]; then
      warn "$target is disabled; upgrading anyway (explicit intent)"
    fi
    targets=("$target")
  fi

  hdr "Upgrade plan ($([[ $DRY == 1 ]] && echo dry-run || echo live))"
  local svc
  for svc in "${targets[@]}"; do
    upgrade_one "$svc"
  done

  print_summary

  # Exit 1 iff any hard FAILED.
  local row res
  for row in "${SUMMARY[@]}"; do
    res="$(printf '%s' "$row" | cut -f3)"
    [[ "$res" == "FAILED" ]] && { err "One or more upgrades FAILED."; exit 1; }
  done
  return 0
}

upgrade_main "$@"
