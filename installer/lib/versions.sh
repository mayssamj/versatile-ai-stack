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

# --- pin / config awareness (shared: check_one AND status --versions) --------
# svc_upgrade_pin <svc> — the declared `upgrade.pin` hold-marker, or "-".
# The PHASE variable (LUMEN_VERSION, OW_VERSION, …) stays enforcement truth;
# this is a display/hold marker only — never a measured version.
svc_upgrade_pin() { svc_upgrade "$1" pin; }

# Types with NO independently versioned artifact BY DEFINITION (derived, so a
# future litellm-feature can't be forgotten): guardrails/agent-pattern/virtual-
# key/plugin are pure config; sandbox-daemon surfaces (hermes_telegram/slack)
# version with their owning service (hermes_fleet's in-sandbox hermes-agent).
VZ_CONFIG_ONLY_TYPES="litellm-feature agent-pattern litellm-virtual-key paperclip-plugin sandbox-daemon"

# svc_config_only <svc> — true (0) when the service is a configuration surface
# (config-only type, or an explicit `upgrade.method: none` on an ambiguous type).
# Gates `if`s — like is_host_global, returns 1 for "not config" ON PURPOSE.
svc_config_only() {
  local svc="$1" type t m
  type="$(svc_type "$svc")"
  for t in $VZ_CONFIG_ONLY_TYPES; do
    if [[ "$type" == "$t" ]]; then return 0; fi
  done
  m="$(svc_upgrade "$svc" method)"
  [[ "$m" == "none" ]]
}

# _compose_images <svc> — the compose stack's image list, honoring the optional
# services.yml keys `compose_file:` (path relative to the service dir — deer-flow
# keeps its compose at docker/docker-compose.yaml, invisible to a bare
# `docker compose config`) and `upgrade.check_env:` (VAR: value map exported ONLY
# for this read-only parse; %DIR% expands to the resolved service dir — deer-flow
# hard-fails `config` without 5 substitution vars incl. DEER_FLOW_DOCKER_SOCKET).
# Read-only: `config --images` parses, never pulls. Empty output on any miss.
_compose_images() {
  local svc="$1" dir cf kv
  dir="$(svc_path "$svc")"
  { [[ -z "$dir" || "$dir" == "-" || ! -d "$dir" ]]; } && return 0
  local -a args=() envs=()
  cf="$(yq -r ".services.$svc.compose_file // \"-\"" "$SERVICES_YML" 2>/dev/null || true)"
  if [[ -n "$cf" && "$cf" != "-" ]]; then args=(-f "$cf"); fi
  while IFS= read -r kv; do
    # Shape-validate: only NAME=value lines may reach `env`'s argv — a malformed
    # or multi-line YAML value would otherwise split into a fragment WITHOUT '='
    # which env treats as the COMMAND to execute (impl-council hardening).
    if [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then envs+=("${kv//\%DIR\%/$dir}"); fi
  done < <(yq -r "(.services.$svc.upgrade.check_env // {}) | to_entries | .[] | .key + \"=\" + (.value|tostring)" "$SERVICES_YML" 2>/dev/null || true)
  ( cd "$dir" && env "${envs[@]}" docker compose "${args[@]}" config --images 2>/dev/null ) || true
  return 0
}

# version_status <svc> — unified currency word over ALL types, so status.sh and
# upgrade.sh agree. docker/compose use the digest comparison (check_image); every
# other type uses installed-vs-available string classification, with declared
# pins ('pinned') and config-only surfaces ('config') classified BEFORE the
# oracle so both consumers render the same word.
#   docker  -> pinned|build|up-to-date|update-available|unknown
#   compose -> up-to-date|update-available|rebuild|unknown|manual
#   other   -> pinned|config|up-to-date|update-available|no-oracle|unknown
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
      imgs="$(_compose_images "$svc")"
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
      # v3: _av_brew is THREE-WAY (formula-arg probe): '-' = probe refused/
      # unreachable → honest 'unknown'; equal to installed → 'up-to-date'
      # (a current formula now echoes its installed version, not '-');
      # different → 'update-available'. The old arm read ANY non-'-' avail as
      # outdated, which under the new oracle would flag every current formula.
      local binst; binst="$(svc_installed_version "$svc")"
      [[ -z "$binst" || "$binst" == "-" ]] && { echo unknown; return 0; }   # not installed
      local bavail; bavail="$(svc_available_version "$svc")"
      if [[ -z "$bavail" || "$bavail" == "-" ]]; then echo unknown; return 0; fi
      [[ "$bavail" == "$binst" ]] && echo up-to-date || echo update-available
      ;;
    *)
      # Declared pin wins (even over method:none — 'pinned' is the more precise
      # word for a held-but-versioned artifact); config-only next; then the oracle.
      local _vsp; _vsp="$(svc_upgrade_pin "$svc")"
      if [[ -n "$_vsp" && "$_vsp" != "-" ]]; then echo pinned; return 0; fi
      if svc_config_only "$svc"; then echo config; return 0; fi
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
  imgs="$(_compose_images "$svc")"
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
  # NOTE: `(( sn == 1 ))` returns exit 1 when the condition is FALSE (sn=0 or >1). As the
  # function's LAST statement that made the whole function return 1, so the caller's
  # `_lt="$(_compose_lone_semver_tag …)"` assignment ABORTED under set -e + inherit_errexit
  # (crashed `upgrade --check --all` on the first compose stack with no lone semver tag —
  # honcho/autofyn/aitown). The explicit `return 0` makes the empty result a normal outcome.
  (( sn == 1 )) && printf '%s' "$st"
  return 0
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

# _svc_brew_formula <svc> — the upgrade.formula override, else the svc name
# (back-compat: ollama's brew-service path keys formula==name). blaxel_cli's
# formula is 'blaxel'; openshell's matches but declares it explicitly.
_svc_brew_formula() {
  local f; f="$(svc_upgrade "$1" formula)"
  if [[ -n "$f" && "$f" != "-" ]]; then printf '%s' "$f"; else printf '%s' "$1"; fi
  return 0
}

_iv_brew() {
  local svc="$1" formula out
  formula="$(_svc_brew_formula "$svc")"
  out="$(brew list --versions "$formula" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  printf '%s' "${out:--}"
}

# _svc_npm_bin <svc> — the npm binary the oracle AND handler must SHARE.
# `upgrade.npm_bin` pins it when the ambient prefix lies: OpenAgents' portable
# Node hijacks the rc PATH (~/.openagents/nodejs), so portless — installed under
# the homebrew npm — is invisible to (and would be mis-installed by) ambient npm.
# FAIL-CLOSED: a DECLARED npm_bin that is missing/broken echoes the sentinel
# 'npm_bin-missing' (an impossible command) so the oracle reads '-' and the
# handler skips — silently falling back to ambient npm would reintroduce the
# exact wrong-prefix mis-install the key exists to prevent.
_svc_npm_bin() {
  local b; b="$(svc_upgrade "$1" npm_bin)"
  if [[ -z "$b" || "$b" == "-" ]]; then printf 'npm'
  elif [[ -x "$b" ]]; then printf '%s' "$b"
  else printf 'npm_bin-missing'; fi
  return 0
}

_iv_npm() {
  local svc="$1" pkg out npmb
  pkg="$(svc_upgrade "$svc" target)"; [[ "$pkg" == "-" || -z "$pkg" ]] && pkg="$svc"
  npmb="$(_svc_npm_bin "$svc")"
  command -v "$npmb" >/dev/null 2>&1 || { echo "-"; return 0; }
  out="$("$npmb" ls -g "$pkg" --depth=0 2>/dev/null | sed -n "s/.*${pkg}@\\([0-9][^[:space:]]*\\).*/\\1/p" | head -1 || true)"
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
  # Truncate to EXACTLY 7 chars — the same width _av_git cuts the remote SHA to.
  # `--short` auto-LENGTHENS in larger repos (paperclip yields 9), so the same
  # commit read '6ec059ab4' vs '6ec059a' → a permanent phantom update-available
  # (live-caught 2026-07-16 right after the first sweep converged).
  [[ -n "$out" ]] && out="${out:0:7}"
  printf '%s' "${out:--}"
}

# _iv_uvtool <svc> — installed version of a uv-managed TOOL (uv tool install).
# `uv pip show` against the tool venv would desync from uv's receipt; the receipt
# (`uv tool list`) is truth. Output is 'pkg vX.Y.Z' (v-prefixed — verified live);
# strip the v so the classify comparison against PyPI's bare version can converge
# (else every --outdated re-selects an already-current tool forever).
_iv_uvtool() {
  local svc="$1" pkg out
  pkg="$(svc_upgrade "$svc" pkg)"; [[ "$pkg" == "-" || -z "$pkg" ]] && pkg="$svc"
  command -v uv >/dev/null 2>&1 || { echo "-"; return 0; }
  out="$(uv tool list 2>/dev/null | awk -v p="$pkg" '$1==p {sub(/^v/,"",$2); print $2; exit}' || true)"
  printf '%s' "${out:--}"
}

# _iv_sandbox_pip <svc> — installed version of upgrade.pkg INSIDE the service's
# openshell sandbox (host pip/uv cannot see /sandbox/.venv). Bounded docker exec
# against a RUNNING container matching the `upgrade.container` name prefix; any
# miss (docker down, container Exited, exec failure) degrades to '-' — honest
# 'unknown', never a hang. SELF-CONTAINED docker gate: ${DOCKER_OK:-1}, because
# status --versions sources this file without upgrade.sh's DOCKER_OK probe and a
# bare $DOCKER_OK would be a set -u unbound abort (check-72 crash family).
_iv_sandbox_pip() {
  local svc="$1" pkg pref c out
  pkg="$(svc_upgrade "$svc" pkg)"; pref="$(svc_upgrade "$svc" container)"
  { [[ "$pkg" == "-" || -z "$pkg" ]] || [[ "$pref" == "-" || -z "$pref" ]]; } && { echo "-"; return 0; }
  if (( ${DOCKER_OK:-1} == 0 )) || ! command -v docker >/dev/null 2>&1; then echo "-"; return 0; fi
  c="$(_vz_bounded 10 docker ps --filter "name=$pref" --filter "status=running" --format '{{.Names}}' 2>/dev/null | head -1 || true)"
  [[ -z "$c" ]] && { echo "-"; return 0; }
  out="$(_vz_bounded 10 docker exec "$c" /sandbox/.venv/bin/pip show "$pkg" 2>/dev/null | awk -F': ' '/^Version:/{print $2}' | head -1 || true)"
  printf '%s' "${out:--}"
}

# --- uv-reqs: multi-package requirements-file oracle (docs_mcp) ---------------
# Behind-names side channel: _av_uvreqs runs inside command substitution
# (avail="$(svc_available_version …)") — a SUBSHELL — so a plain global can
# never reach the caller. The display-only list of behind requirement names
# ("docling mcp openai") is passed through a FILE instead. Never parsed for logic.
_uvreqs_behind_file() { printf '%s' "$AI_STACK/installer/state/.uvreqs_behind"; return 0; }

# _uvreqs_names <reqs-file-abs> — ordered base names (comments/extras/specifiers
# stripped). ONE shared extractor so _iv/_av iterate identically — a fingerprint
# built over a different name order would never converge.
_uvreqs_names() {
  local f="$1" line base
  [[ -f "$f" ]] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    if [[ -n "$line" ]]; then
      base="${line%%[*}"; base="${base%%[<>=!~]*}"
      if [[ -n "$base" ]]; then printf '%s\n' "$base"; fi
    fi
  done < "$f"
  return 0
}

# _uvreqs_paths <svc> — echo "py|reqs" (resolved + validated), or nothing.
_uvreqs_paths() {
  local svc="$1" venv reqs py rf
  venv="$(svc_upgrade "$svc" venv)"; reqs="$(svc_upgrade "$svc" reqs)"
  { [[ "$venv" == "-" || -z "$venv" ]] || [[ "$reqs" == "-" || -z "$reqs" ]]; } && return 0
  py="$AI_STACK/$venv/bin/python"; [[ "$venv" == /* ]] && py="$venv/bin/python"
  rf="$AI_STACK/$reqs"; [[ "$reqs" == /* ]] && rf="$reqs"
  if [[ -x "$py" && -f "$rf" ]]; then printf '%s|%s' "$py" "$rf"; fi
  return 0
}

# _iv_uvreqs <svc> — fingerprint over the INSTALLED versions of the req names:
# "N reqs (cksum)". FAIL-CLOSED: any unreadable name → '-' (a partial
# fingerprint is a lying fingerprint — council A-B1).
_iv_uvreqs() {
  local svc="$1" pp py rf n=0 vers="" name v
  pp="$(_uvreqs_paths "$svc")"; [[ -z "$pp" ]] && { echo "-"; return 0; }
  py="${pp%%|*}"; rf="${pp##*|}"
  command -v uv >/dev/null 2>&1 || { echo "-"; return 0; }
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    v="$(uv pip show --python "$py" "$name" 2>/dev/null | awk -F': ' '/^Version:/{print $2}' | head -1 || true)"
    [[ -z "$v" ]] && { echo "-"; return 0; }
    n=$((n+1)); vers+="${name}==${v};"
  done < <(_uvreqs_names "$rf")
  (( n == 0 )) && { echo "-"; return 0; }
  printf '%s reqs (%s)' "$n" "$(printf '%s' "$vers" | cksum | awk '{print $1}')"
}

# _av_uvreqs <svc> — fingerprint over the versions THE HANDLER WOULD INSTALL:
# the same scoped command as up_uv_reqs, with --dry-run. Council A-B1: a
# PyPI-latest fingerprint can NEVER converge when the resolver holds a req below
# latest (sibling caps are the ecosystem norm); the dry-run uses the SAME
# resolver, so oracle == handler by construction. Scoped with --upgrade-package
# per name — a bare -U drags the whole closure (torch, GB wheels; verified).
# uv prints the '+/-' plan to STDERR (verified live) → capture 2>&1.
# FAIL-CLOSED: any miss (venv, uv, resolve failure, unreadable name) → '-'.
_av_uvreqs() {
  local svc="$1" pp py rf n=0 vers="" name v newv out behind=""
  rm -f "$(_uvreqs_behind_file)" 2>/dev/null || true
  pp="$(_uvreqs_paths "$svc")"; [[ -z "$pp" ]] && { echo "-"; return 0; }
  py="${pp%%|*}"; rf="${pp##*|}"
  command -v uv >/dev/null 2>&1 || { echo "-"; return 0; }
  local -a names=() upargs=()
  while IFS= read -r name; do
    if [[ -n "$name" ]]; then names+=("$name"); upargs+=(--upgrade-package "$name"); fi
  done < <(_uvreqs_names "$rf")
  (( ${#names[@]} == 0 )) && { echo "-"; return 0; }
  # FAIL-CLOSED on the resolver's EXIT CODE, not just empty output (impl-council
  # blocking): a failed resolve emits error text on stderr which 2>&1 folds into
  # $out — non-empty, so an -z guard alone reads a network flake as 'up-to-date'.
  # uv exits 0 both when current and when upgrades are planned; non-zero only on
  # failure, and _vz_bounded is non-zero on timeout in all three arms.
  # Probe budget: ONE bounded resolver hit (≤90s) + N local `uv pip show` reads —
  # no per-package network probes.
  local _dr_rc=0
  out="$(_vz_bounded 90 uv pip install --python "$py" -r "$rf" "${upargs[@]}" --dry-run 2>&1)" || _dr_rc=$?
  if (( _dr_rc != 0 )) || [[ -z "$out" ]]; then echo "-"; return 0; fi
  for name in "${names[@]}"; do
    v="$(uv pip show --python "$py" "$name" 2>/dev/null | awk -F': ' '/^Version:/{print $2}' | head -1 || true)"
    [[ -z "$v" ]] && { echo "-"; return 0; }
    newv="$(printf '%s\n' "$out" | awk -v p="$name" '$1=="+" { split($2,a,"=="); if (a[1]==p) print a[2] }' | head -1 || true)"
    if [[ -n "$newv" && "$newv" != "$v" ]]; then behind+="$name "; v="$newv"; fi
    n=$((n+1)); vers+="${name}==${v};"
  done
  if [[ -n "$behind" ]]; then printf '%s' "${behind% }" > "$(_uvreqs_behind_file)" 2>/dev/null || true; fi
  printf '%s reqs (%s)' "$n" "$(printf '%s' "$vers" | cksum | awk '{print $1}')"
}

# manual-typed services (cli-only/node-bg/python-bg/…) route on their declared
# upgrade.method — the same dispatch up_by_method uses.
_iv_by_method() {
  local svc="$1" m; m="$(svc_upgrade "$svc" method)"
  case "$m" in
    npm-global)  _iv_npm "$svc" ;;
    uv-venv)     _iv_pip "$svc" ;;
    git-pull)    _iv_git "$svc" ;;
    uv-tool)     _iv_uvtool "$svc" ;;
    sandbox-pip) _iv_sandbox_pip "$svc" ;;
    uv-reqs)     _iv_uvreqs "$svc" ;;
    brew)        _iv_brew "$svc" ;;
    *)           echo "-" ;;
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

# _av_brew — THREE-WAY semantics with a FORMULA-ARG probe (council A-B2). The
# old no-arg `brew outdated` listed ONLY outdated formulae, so a CURRENT
# method:brew service read '-' → 'unknown' → the 'currency NOT confirmed'
# warning forever. With the formula as an argument:
#   refusal / no output (untrusted tap, not installed, network) → '-' (unknown)
#   listed in outdated JSON                                     → current_version
#   rc-any + valid JSON + absent + installed                    → installed (up-to-date)
# NOTE: `brew outdated <f>` exits NON-ZERO when <f> IS outdated — decide on the
# JSON, never on rc. Formula passed to python as ARGV (never interpolated —
# the old '$svc'-in-source form was a quoting hazard).
_av_brew() {
  local svc="$1" formula out cur inst
  formula="$(_svc_brew_formula "$svc")"
  out="$(_vz_bounded 12 brew outdated --json=v2 "$formula" 2>/dev/null || true)"
  [[ -z "$out" ]] && { echo "-"; return 0; }
  # Parse failure must be DISTINGUISHABLE from 'valid JSON, formula not listed'
  # (impl-council): garbled/truncated stdout would otherwise fall through to the
  # installed fallback and read a probe miss as confirmed currency.
  cur="$(printf '%s' "$out" | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print('__PARSE_ERR__'); raise SystemExit
f=[x for x in d.get('formulae',[]) if x.get('name')==sys.argv[1]]
print(f[0]['current_version'] if f else '')" "$formula" 2>/dev/null || true)"
  if [[ "$cur" == *"__PARSE_ERR__"* ]]; then echo "-"; return 0; fi
  if [[ -n "$cur" ]]; then printf '%s' "$cur"; return 0; fi
  inst="$(brew list --versions "$formula" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  if [[ -n "$inst" ]]; then printf '%s' "$inst"; else echo "-"; fi
  return 0
}

_av_npm() {
  local svc="$1" pkg out npmb
  pkg="$(svc_upgrade "$svc" target)"; [[ "$pkg" == "-" || -z "$pkg" ]] && pkg="$svc"
  npmb="$(_svc_npm_bin "$svc")"
  command -v "$npmb" >/dev/null 2>&1 || { echo "-"; return 0; }
  out="$(_vz_bounded 12 "$npmb" view "$pkg" version 2>/dev/null | tail -1 || true)"
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
  local svc="$1" dir abs out br=""
  dir="$(svc_upgrade "$svc" dir)"; [[ "$dir" == "-" || -z "$dir" ]] && dir="$(svc_upgrade "$svc" target)"
  [[ "$dir" == "-" || -z "$dir" ]] && dir="$(svc_path "$svc")"
  [[ "$dir" == "-" || -z "$dir" ]] && { echo "-"; return 0; }
  abs="$AI_STACK/$dir"; [[ "$dir" == /* ]] && abs="$dir"
  { [[ ! -d "$abs/.git" ]] || ! command -v git >/dev/null 2>&1; } && { echo "-"; return 0; }
  # Compare against the TRACKED branch, not the remote's default HEAD: a clone
  # sitting on a non-default branch (or an upstream that moved its default) would
  # otherwise read update-available forever while `pull --ff-only` no-ops — a
  # nag loop that never converges. Fall back to origin HEAD when detached.
  br="$(git -C "$abs" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [[ -n "$br" ]]; then
    out="$(_vz_bounded 12 git -C "$abs" ls-remote origin "refs/heads/$br" 2>/dev/null | awk '{print $1}' | head -1 || true)"
  fi
  [[ -z "${out:-}" ]] && out="$(_vz_bounded 12 git -C "$abs" ls-remote origin HEAD 2>/dev/null | awk '{print $1}' | head -1 || true)"
  [[ -n "$out" ]] && printf '%s' "${out:0:7}" || echo "-"
}

_av_by_method() {
  local svc="$1" m; m="$(svc_upgrade "$svc" method)"
  case "$m" in
    npm-global)          _av_npm "$svc" ;;
    uv-venv)             _av_pip "$svc" ;;
    git-pull)            _av_git "$svc" ;;
    # uv-tool and sandbox-pip artifacts both live on PyPI (upgrade.pkg) — the
    # upstream probe is the same bounded PyPI JSON read.
    uv-tool|sandbox-pip) _av_pip "$svc" ;;
    uv-reqs)             _av_uvreqs "$svc" ;;
    brew)                _av_brew "$svc" ;;
    *)                   echo "-" ;;
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
