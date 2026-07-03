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
  elif command -v perl     >/dev/null 2>&1; then
    # macOS ships no coreutils `timeout`; perl always ships. alarm() schedules a
    # SIGALRM that survives exec (POSIX), so the exec'd probe is hard-killed at
    # <secs> — a real bound so a Zscaler-blocked registry can't hang status/upgrade.
    perl -e 'my $s=shift; alarm $s; exec @ARGV or exit 127' "$secs" "$@"
  else "$@"; fi
}

# ============================ docker image helpers (shared) =================
# Moved here from upgrade.sh so BOTH status.sh and upgrade.sh share one docker
# currency oracle (status.sh cannot source upgrade.sh — it self-runs upgrade_main).
# Local RepoDigest for an image, or empty if locally-built/never-pulled.
docker_local_digest() {
  docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || true
}
# image_is_pinned <image> — true (0) for a fixed semver/sha tag, false (1) for a
# rolling tag. No ':' → 'latest' → rolling.
image_is_pinned() {
  local image="$1" tag
  tag="${image##*:}"
  [[ "$tag" == */* || "$tag" == "$image" ]] && tag="latest"
  case "$tag" in
    latest|main|main-stable|stable|nightly|edge) return 1 ;;
    *) return 0 ;;
  esac
}
# image_is_local_built <image> — true (0) for an image the stack BUILDS locally
# (ai-stack/ namespace, :local, :aistack-*) that exists in NO registry.
image_is_local_built() {
  local image="$1"
  [[ "$image" == ai-stack/* || "$image" == *:local || "$image" == *:aistack-* ]]
}
# Local image digest (just the sha256:…), or empty.
img_local_digest() {
  docker_local_digest "$1" | sed 's/.*@//' || true
}
# Remote index/manifest digest from the registry (manifest only). Bounded so a
# Zscaler-blocked / hung registry can't stall the caller.
img_remote_digest() {
  _vz_bounded 10 docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}
# check_image <image> -> pinned | build | up-to-date | update-available | unknown
check_image() {
  local image="$1" l r
  image_is_local_built "$image" && { echo build; return 0; }
  image_is_pinned "$image" && { echo pinned; return 0; }
  r="$(img_remote_digest "$image")"
  l="$(img_local_digest "$image")"
  if [[ -z "$r" ]]; then
    [[ -z "$l" ]] && { echo build; return 0; }
    echo unknown; return 0
  fi
  [[ -z "$l" ]] && { echo update-available; return 0; }
  [[ "$l" == "$r" ]] && echo up-to-date || echo update-available
}

# version_status <svc> — unified currency word over ALL types, so status.sh and
# upgrade.sh agree. docker/compose use the digest comparison (check_image); every
# other type uses installed-vs-available string classification.
#   docker  -> pinned|build|up-to-date|update-available|unknown
#   compose -> up-to-date|update-available|rebuild|unknown|manual
#   other   -> up-to-date|update-available|no-oracle|unknown
version_status() {
  local svc="$1" type; type="$(svc_type "$svc")"
  case "$type" in
    docker)
      local image; image="$(svc_image "$svc")"
      [[ -z "$image" || "$image" == "-" ]] && { echo unknown; return 0; }
      check_image "$image"
      ;;
    compose|docker-compose)
      local dir; dir="$(svc_path "$svc")"
      { [[ -z "$dir" || "$dir" == "-" || ! -d "$dir" ]]; } && { echo manual; return 0; }
      command -v docker >/dev/null 2>&1 || { echo unknown; return 0; }
      local imgs im st any_update=0 any_unknown=0 any_build=0 n=0
      imgs="$( cd "$dir" && docker compose config --images 2>/dev/null || true )"
      [[ -z "$imgs" ]] && { echo manual; return 0; }
      while IFS= read -r im; do
        [[ -z "$im" ]] && continue; n=$((n+1)); st="$(check_image "$im")"
        case "$st" in update-available) any_update=1 ;; unknown) any_unknown=1 ;; build) any_build=1 ;; esac
      done <<< "$imgs"
      (( n == 0 )) && { echo manual; return 0; }
      if   (( any_update ));               then echo update-available
      elif (( any_build || any_unknown )); then echo rebuild
      else                                      echo up-to-date; fi
      ;;
    brew-service)
      # brew outdated only lists OUTDATED formulae → svc_available_version returns
      # "-" for a current formula. version_classify would then say no-oracle/unknown.
      # Mirror check_one's brew logic so an installed-but-current formula (the steady
      # state for ollama) reads 'up-to-date', matching `upgrade --check` exactly.
      local binst; binst="$(svc_installed_version "$svc")"
      [[ -z "$binst" || "$binst" == "-" ]] && { echo unknown; return 0; }   # not installed
      local bavail; bavail="$(svc_available_version "$svc")"
      [[ -n "$bavail" && "$bavail" != "-" ]] && echo update-available || echo up-to-date
      ;;
    *)
      version_classify "$type" "$(svc_installed_version "$svc")" "$(svc_available_version "$svc")"
      ;;
  esac
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
  # compose stacks have N images, no single version. Report the count PLUS a short
  # fingerprint (cksum) of the local image digests, so the upgrade driver's
  # before/after delta can tell a real pull from a no-op `compose up` (a compose
  # no-op used to report a false 'upgraded' every run — council should-fix).
  local svc="$1" dir imgs im d n=0 digs=""
  dir="$(svc_path "$svc")"
  { [[ -z "$dir" || "$dir" == "-" || ! -d "$dir" ]] || ! command -v docker >/dev/null 2>&1; } && { echo "-"; return 0; }
  imgs="$( cd "$dir" && docker compose config --images 2>/dev/null || true )"
  [[ -z "$imgs" ]] && { echo "-"; return 0; }
  while IFS= read -r im; do
    [[ -z "$im" ]] && continue
    n=$((n+1))
    d="$(docker_local_digest "$im")"
    # A locally-built image lacks a RepoDigest ONLY on classic dockerd/overlay2 (e.g.
    # Colima) — on the default OrbStack/containerd backend a local build DOES get a
    # synthesized RepoDigest, so here this fallback is a portability no-op. WHERE it is
    # empty, fall back to the image ID so a genuine rebuild still moves the fingerprint
    # (otherwise the blank digest was constant → a real rebuild read 'up-to-date').
    [[ -z "$d" ]] && d="$(docker image inspect --format '{{.Id}}' "$im" 2>/dev/null || true)"
    digs+="${d##*@};"
  done <<< "$imgs"
  (( n == 0 )) && { echo "-"; return 0; }
  local fp; fp="$(printf '%s' "$digs" | cksum | awk '{print $1}')"
  printf '%s imgs (%s)' "$n" "$fp"
}

# _compose_lone_semver_tag <newline-separated image refs> — echo the SOLE semantic
# version tag among them (e.g. "v2026.6.19"), or "" if zero or >1 carry one. A real tag
# has no '/', so a registry host:port with no explicit tag (localhost:5000/foo) is NOT a
# tag. Lets check_one surface "N imgs (v2026.6.19)" for a single-pinned compose stack.
_compose_lone_semver_tag() {
  local st="" sn=0 im ref tag
  while IFS= read -r im; do
    [[ -z "$im" ]] && continue
    ref="${im%@*}"; tag="${ref##*:}"
    [[ "$tag" == "$ref" ]] && continue      # no ':' → no tag
    [[ "$tag" == */* ]] && continue         # the ':' was a registry host:port, not a tag
    [[ "$tag" =~ ^v?[0-9] ]] && { st="$tag"; sn=$((sn+1)); }
  done <<< "$1"
  (( sn == 1 )) && printf '%s' "$st"
}

# _npm_global_version <pkg> — installed version of a global npm package, or "" if
# absent. --json + python (not sed) so a scoped name (@scope/pkg) with a '/' is safe;
# pkg is passed as argv, never interpolated into the program. Lives here (the shared,
# sourceable oracle) so upgrade.sh's host-global reconcile can be unit-tested.
_npm_global_version() {
  local pkg="$1"
  command -v npm >/dev/null 2>&1 || { printf ''; return 0; }
  npm ls -g "$pkg" --depth=0 --json 2>/dev/null | python3 -c '
import sys, json
pkg = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
dep = (d.get("dependencies") or {}).get(pkg) or {}
print(dep.get("version", ""))
' "$pkg" 2>/dev/null || true
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
  # The stack standardizes on uv-managed venvs, which are PIP-LESS by default —
  # so `python -m pip show` returns nothing (this was the remnic_hermes blind spot).
  # Probe with `uv pip show --python` first; fall back to pip (pip-seeded venvs),
  # then to the <pkg>-<ver>.dist-info directory name under site-packages.
  if command -v uv >/dev/null 2>&1; then
    out="$(uv pip show --python "$py" "$base" 2>/dev/null | awk -F': ' '/^Version:/{print $2}' | head -1 || true)"
  fi
  [[ -z "$out" ]] && out="$("$py" -m pip show "$base" 2>/dev/null | awk -F': ' '/^Version:/{print $2}' | head -1 || true)"
  if [[ -z "$out" ]]; then
    local si; si="$(ls -d "$(dirname "$py")/.."/lib/python*/site-packages/"${base//-/_}"-*.dist-info 2>/dev/null | head -1 || true)"
    if [[ -n "$si" ]]; then si="${si##*/}"; si="${si#"${base//-/_}"-}"; out="${si%.dist-info}"; fi
  fi
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
    # installed not knowable: upstream known → unknown; nothing knowable → no-oracle.
    [[ -n "$avail" && "$avail" != "-" ]] && { echo unknown; return 0; }
    echo no-oracle; return 0
  fi
  # installed IS known here. Upstream unreachable/absent → 'unknown' (an oracle
  # exists but the probe couldn't confirm — e.g. proxy-blocked), NOT 'no-oracle'.
  # This keeps status --versions and `upgrade --check` (check_one) in agreement.
  if [[ -z "$avail" || "$avail" == "-" ]]; then echo unknown; return 0; fi
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
