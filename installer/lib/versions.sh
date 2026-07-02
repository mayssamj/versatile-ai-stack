# versions.sh — the shared, side-effect-free VERSION ORACLE.
#
# Single source of truth for "what version is installed" and "what is the latest
# upstream" per service, sourced by BOTH status.sh (status --versions) and
# upgrade.sh (--check / the pre-upgrade report / the honest version-delta
# post-check). Mirrors the services_accessors.sh contract:
#   - NO top-level side effects: sourcing defines functions and nothing else
#     (no stdout, no lock, no docker pull/build/run, no phase run).
#   - Idempotent: guarded so repeated sourcing is a no-op.
#   - Requires SERVICES_YML + the services_accessors.sh readers.
#
# HARD SAFETY CONTRACT (operator directive, MEMORY feedback_never_load_local_models):
#   NEVER load a local model. No `ollama pull|run`, no `lms load`, no inference,
#   no curl that triggers a load. Installed-version probes are LOCAL/CHEAP
#   (Layer A). Upstream probes (Layer B) are OPT-IN network, BOUNDED (a timeout
#   wrapper + curl --max-time), and best-effort (a blocked/hung registry — e.g.
#   the corporate Zscaler proxy — degrades to "-"/unknown, never hangs the caller).
#
# Three layers:
#   Layer A  svc_installed_version <svc>   -> local installed version string, or "-"
#   Layer B  svc_available_version   <svc> -> latest upstream version string, or "-"
#   Layer C  version_classify <type> <installed> <available> -> one vocabulary word

[[ -n "${__VERSIONS_SOURCED:-}" ]] && return 0
__VERSIONS_SOURCED=1

# AI_STACK is env-overridable (tests point it at a fixture); resolve only if unset.
: "${AI_STACK:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Need the per-service yq readers (svc_type/svc_image/svc_upgrade/svc_path). Guarded.
[[ -n "${__SVC_ACCESSORS_SOURCED:-}" ]] || source "$AI_STACK/installer/lib/services_accessors.sh"

# --- bounded runner ----------------------------------------------------------
# _vz_bounded <secs> <cmd...> — run a probe under a hard time bound so a hung
# registry/proxy can never stall status/upgrade. Uses coreutils timeout/gtimeout
# when present; degrades to unbounded (still best-effort + `|| true` at call
# sites) when neither exists. stdout of <cmd> is preserved for $(...) capture.
_vz_bounded() {
  local secs="$1"; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else "$@"; fi
}

# ============================ Layer A: installed ============================
_iv_docker() {
  local svc="$1" image tag dig short=""
  image="$(svc_image "$svc")"
  [[ -z "$image" || "$image" == "-" ]] && { echo "-"; return 0; }
  tag="${image##*:}"
  # no tag (e.g. qdrant/qdrant) → 'latest'
  [[ "$tag" == */* || "$tag" == "$image" ]] && tag="latest"
  # append the short LOCAL RepoDigest (cheap, no network) so a rolling tag still
  # carries a delta signal for the honest post-check. No local image → tag only.
  if command -v docker >/dev/null 2>&1; then
    dig="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
    dig="${dig##*@sha256:}"
    [[ -n "$dig" && "$dig" != "$image" ]] && short="@${dig:0:12}"
  fi
  printf '%s%s' "$tag" "$short"
}

_iv_compose() {
  # compose stacks have N images, no single version; report image count as a
  # coarse installed signal. Real per-image currency handled in the classifier.
  local svc="$1" dir n
  dir="$(svc_path "$svc")"
  { [[ -z "$dir" || "$dir" == "-" || ! -d "$dir" ]] || ! command -v docker >/dev/null 2>&1; } && { echo "-"; return 0; }
  n="$( cd "$dir" && docker compose config --images 2>/dev/null | grep -c . || true )"
  [[ -n "$n" && "$n" != "0" ]] && printf '%s imgs' "$n" || echo "-"
}

_iv_brew() {
  local svc="$1" out
  out="$(brew list --versions "$svc" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  printf '%s' "${out:--}"
}

_iv_npm() {
  local svc="$1" pkg out
  pkg="$(svc_upgrade "$svc" target)"; [[ "$pkg" == "-" || -z "$pkg" ]] && pkg="$svc"
  command -v npm >/dev/null 2>&1 || { echo "-"; return 0; }
  out="$(npm ls -g "$pkg" --depth=0 2>/dev/null | sed -n "s/.*${pkg}@\\([0-9][^[:space:]]*\\).*/\\1/p" | head -1 || true)"
  printf '%s' "${out:--}"
}

_iv_pip() {
  local svc="$1" venv pkg py out
  venv="$(svc_upgrade "$svc" venv)"; pkg="$(svc_upgrade "$svc" pkg)"
  { [[ "$venv" == "-" || -z "$venv" ]] || [[ "$pkg" == "-" || -z "$pkg" ]]; } && { echo "-"; return 0; }
  py="$AI_STACK/$venv/bin/python"; [[ "$venv" == /* ]] && py="$venv/bin/python"
  [[ -x "$py" ]] || { echo "-"; return 0; }
  # pkg may carry pip extras/specifiers (e.g. 'hermes-agent[mcp]'); strip to the base name.
  local base="${pkg%%[*}"; base="${base%%=*}"; base="${base%%[<>]*}"
  out="$("$py" -m pip show "$base" 2>/dev/null | awk -F': ' '/^Version:/{print $2}' | head -1 || true)"
  printf '%s' "${out:--}"
}

_iv_git() {
  local svc="$1" dir abs out
  dir="$(svc_upgrade "$svc" dir)"; [[ "$dir" == "-" || -z "$dir" ]] && dir="$(svc_upgrade "$svc" target)"
  [[ "$dir" == "-" || -z "$dir" ]] && dir="$(svc_path "$svc")"
  [[ "$dir" == "-" || -z "$dir" ]] && { echo "-"; return 0; }
  abs="$AI_STACK/$dir"; [[ "$dir" == /* ]] && abs="$dir"
  [[ -d "$abs/.git" ]] || { echo "-"; return 0; }
  command -v git >/dev/null 2>&1 || { echo "-"; return 0; }
  out="$(git -C "$abs" rev-parse --short HEAD 2>/dev/null || true)"
  printf '%s' "${out:--}"
}

# manual-typed services (cli-only/node-bg/python-bg/…) route on their declared
# upgrade.method — the same dispatch up_by_method uses.
_iv_by_method() {
  local svc="$1" m; m="$(svc_upgrade "$svc" method)"
  case "$m" in
    npm-global) _iv_npm "$svc" ;;
    uv-venv)    _iv_pip "$svc" ;;
    git-pull)   _iv_git "$svc" ;;
    *)          echo "-" ;;
  esac
}

# svc_installed_version <svc> — LOCAL/CHEAP installed version string, or "-".
svc_installed_version() {
  local svc="$1" type; type="$(svc_type "$svc")"
  case "$type" in
    docker)                  _iv_docker "$svc" ;;
    compose|docker-compose)  _iv_compose "$svc" ;;
    brew-service)            _iv_brew "$svc" ;;
    npm-global)              _iv_npm "$svc" ;;
    pip-package)             _iv_pip "$svc" ;;
    clone-only)              _iv_git "$svc" ;;
    *)                       _iv_by_method "$svc" ;;
  esac
}

# ============================ Layer B: available ===========================
_av_docker() {
  local svc="$1" image dig
  image="$(svc_image "$svc")"
  { [[ -z "$image" || "$image" == "-" ]] || ! command -v docker >/dev/null 2>&1; } && { echo "-"; return 0; }
  dig="$(_vz_bounded 10 docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  dig="${dig##*sha256:}"
  [[ -n "$dig" ]] && printf '@%s' "${dig:0:12}" || echo "-"
}

_av_brew() {
  local svc="$1" cur
  cur="$(_vz_bounded 10 brew outdated --json=v2 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
f=[x for x in d.get('formulae',[]) if x.get('name')=='$svc']
print(f[0]['current_version'] if f else '')" 2>/dev/null || true)"
  printf '%s' "${cur:--}"
}

_av_npm() {
  local svc="$1" pkg out
  pkg="$(svc_upgrade "$svc" target)"; [[ "$pkg" == "-" || -z "$pkg" ]] && pkg="$svc"
  command -v npm >/dev/null 2>&1 || { echo "-"; return 0; }
  out="$(_vz_bounded 12 npm view "$pkg" version 2>/dev/null | tail -1 || true)"
  printf '%s' "${out:--}"
}

_av_pip() {
  local svc="$1" pkg base out
  pkg="$(svc_upgrade "$svc" pkg)"; [[ "$pkg" == "-" || -z "$pkg" ]] && { echo "-"; return 0; }
  base="${pkg%%[*}"; base="${base%%=*}"; base="${base%%[<>]*}"
  out="$(_vz_bounded 12 curl -fsS --max-time 10 "https://pypi.org/pypi/${base}/json" 2>/dev/null | python3 -c "import sys,json
try: print(json.load(sys.stdin)['info']['version'])
except Exception: print('')" 2>/dev/null || true)"
  printf '%s' "${out:--}"
}

_av_git() {
  local svc="$1" dir abs out
  dir="$(svc_upgrade "$svc" dir)"; [[ "$dir" == "-" || -z "$dir" ]] && dir="$(svc_upgrade "$svc" target)"
  [[ "$dir" == "-" || -z "$dir" ]] && dir="$(svc_path "$svc")"
  [[ "$dir" == "-" || -z "$dir" ]] && { echo "-"; return 0; }
  abs="$AI_STACK/$dir"; [[ "$dir" == /* ]] && abs="$dir"
  { [[ ! -d "$abs/.git" ]] || ! command -v git >/dev/null 2>&1; } && { echo "-"; return 0; }
  out="$(_vz_bounded 12 git -C "$abs" ls-remote origin HEAD 2>/dev/null | awk '{print $1}' | head -1 || true)"
  [[ -n "$out" ]] && printf '%s' "${out:0:7}" || echo "-"
}

_av_by_method() {
  local svc="$1" m; m="$(svc_upgrade "$svc" method)"
  case "$m" in
    npm-global) _av_npm "$svc" ;;
    uv-venv)    _av_pip "$svc" ;;
    git-pull)   _av_git "$svc" ;;
    *)          echo "-" ;;
  esac
}

# svc_available_version <svc> — OPT-IN, BOUNDED upstream latest, or "-".
svc_available_version() {
  local svc="$1" type; type="$(svc_type "$svc")"
  case "$type" in
    docker)                  _av_docker "$svc" ;;
    brew-service)            _av_brew "$svc" ;;
    npm-global)              _av_npm "$svc" ;;
    pip-package)             _av_pip "$svc" ;;
    clone-only)              _av_git "$svc" ;;
    *)                       _av_by_method "$svc" ;;
  esac
}

# ============================ Layer C: classify ============================
# version_classify <type> <installed> <available> -> one word:
#   up-to-date | update-available | no-oracle | unknown
# (docker digest-pin / pinned-behind refinements are layered on top by check_one,
# which owns the docker registry-digest comparison.)
version_classify() {
  local _type="$1" inst="$2" avail="$3"
  if [[ -z "$inst" || "$inst" == "-" ]]; then
    [[ -n "$avail" && "$avail" != "-" ]] && { echo unknown; return 0; }
    echo no-oracle; return 0
  fi
  if [[ -z "$avail" || "$avail" == "-" ]]; then echo no-oracle; return 0; fi
  [[ "$inst" == "$avail" ]] && echo up-to-date || echo update-available
}

# reconcile_result <handler_result> <ver_before> <ver_after> -> honest RESULT.
# The upgrade DRIVER calls this AFTER a handler that optimistically sets
# "upgraded" on any exit-0 (brew/npm/uv-venv/git-pull/openshell-pip). It refuses
# to let "upgraded" stand when the installed version did not actually move:
#   - both versions known & DIFFERENT -> "upgraded"   (a real bump)
#   - both versions known & EQUAL     -> "up-to-date"  (a no-op, the lie fix)
#   - version not knowable ("-")       -> "done (unverified)"  (never claim a bump)
# Any other result (FAILED / skipped* / manual / planned / auto-latest) is a
# fact the handler already established — passed through untouched.
reconcile_result() {
  local result="$1" before="$2" after="$3"
  [[ "$result" == "upgraded" || "$result" == "up-to-date" ]] || { printf '%s' "$result"; return 0; }
  if [[ -z "$before" || "$before" == "-" || -z "$after" || "$after" == "-" ]]; then
    printf 'done (unverified)'; return 0
  fi
  [[ "$before" == "$after" ]] && printf 'up-to-date' || printf 'upgraded'
}
