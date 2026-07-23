#!/usr/bin/env bash
# cleanup.sh — reclaim disk by removing REGENERABLE artifacts: node_modules,
# Python virtualenvs (.venv/venv), framework/build caches, and (opt-in) dangling
# Docker layers. Everything it removes is rebuilt by `install`/`start`/
# `npm install`/venv creation — so deletion IS the reversible path; no backup is
# taken (a backup would defeat the space saving).
#
# ── SAFETY INVARIANT (why an rm -rf here is safe) ────────────────────────────
# A directory is eligible ONLY if BOTH hold:
#   (1) its basename matches a known regenerable-artifact pattern, AND
#   (2) `git check-ignore -q` confirms git ignores it (NOT tracked source).
# Tracked source is therefore structurally un-deletable. Belt-and-suspenders:
# the live data/ bind-mount tree and sibling git worktrees (.claude/worktrees)
# are hard-excluded from the scan so a cleanup from main never reaches them.
#
# ── DRY-RUN BY DEFAULT ───────────────────────────────────────────────────────
# With no --yes/-y it only PREVIEWS (per-dir sizes + total) and deletes nothing.
#
# Usage:
#   cleanup                      preview repo artifacts (node + venv + caches)
#   cleanup --yes                delete them
#   cleanup --node|--venv|--caches   scope to one or more categories (combinable)
#   cleanup --docker             ALSO prune dangling docker images + build cache
#                                + dangling ANONYMOUS volumes (itemized; each is
#                                tar-backed-up before removal — volumes are the
#                                one thing here `install` cannot rebuild)
#   cleanup --all                repo categories + docker
#   cleanup --yes --node         delete only node_modules
set -uo pipefail   # NOT -e: control flow below tolerates non-zero (find/grep/du)
# Libs always come from THIS script's install; the scan ROOT is separate so the
# smoke test can point cleanup at a throwaway repo via $AI_STACK.
SELF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SELF_ROOT/installer/lib/common.sh"
ROOT="${AI_STACK:-$SELF_ROOT}"
# docker.sh provides docker_anon_orphans (shared anon-volume verb, §24 2026-07-20).
# Engine note: docker.sh's source-time DOCKER_HOST hook needs env.sh (not sourced
# here) — via the mayssam-ai-stack.sh dispatch the selected engine is inherited from
# that environment; a standalone run uses the ambient socket. AI_STACK is already
# set on the dispatch path; the default below covers direct invocation.
export AI_STACK="${AI_STACK:-$SELF_ROOT}"
[[ -f "$SELF_ROOT/installer/lib/docker.sh" ]] && source "$SELF_ROOT/installer/lib/docker.sh"

# --- arg parse ---------------------------------------------------------------
DO_DELETE=0 WANT_NODE=0 WANT_VENV=0 WANT_CACHES=0 WANT_DOCKER=0 ANY_CAT=0
for a in "$@"; do
  case "$a" in
    --yes|-y)   DO_DELETE=1 ;;
    --node)     WANT_NODE=1;   ANY_CAT=1 ;;
    --venv)     WANT_VENV=1;   ANY_CAT=1 ;;
    --caches)   WANT_CACHES=1; ANY_CAT=1 ;;
    --docker)   WANT_DOCKER=1 ;;
    --all)      WANT_NODE=1; WANT_VENV=1; WANT_CACHES=1; WANT_DOCKER=1; ANY_CAT=1 ;;
    -h|--help)  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "cleanup: unknown flag '$a' (try --help)"; exit 2 ;;
  esac
done
# No repo category named → default to all three repo categories (NOT docker:
# docker layers are shared host state, so pruning them stays opt-in).
if (( ANY_CAT == 0 )); then WANT_NODE=1; WANT_VENV=1; WANT_CACHES=1; fi

# The safety gate decides "regenerable" via git tracked/ignored status, so git is
# mandatory. Without it we cannot prove anything safe to delete — fail CLOSED with
# a clear message instead of a misleading "Nothing to reclaim". (Council Bug 2.)
if (( WANT_NODE || WANT_VENV || WANT_CACHES )) \
   && ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "cleanup: $ROOT is not a git repository — the safety gate (git tracked/ignored)"
  err "         cannot operate, so nothing can be verified safe to delete. Aborting."
  exit 2
fi

# --- helpers -----------------------------------------------------------------
# ELIGIBLE = gitignored AND no git-tracked files underneath. The second clause is
# the real data-loss guard: a *committed* dist/ or venv/ shadowed by a NESTED
# .gitignore would pass check-ignore alone; requiring zero tracked files makes
# deleting tracked content structurally impossible. (Council Finding 4.)
is_ignored()  { git -C "$ROOT" check-ignore -q "$1" 2>/dev/null; }
has_tracked() { [[ -n "$(git -C "$ROOT" ls-files -- "$1" 2>/dev/null | head -1)" ]]; }
eligible()    { is_ignored "$1" && ! has_tracked "$1"; }
du_k()  { du -sk "$1" 2>/dev/null | awk '{print $1}'; }                  # size in KiB
human() { local k=$1; awk -v k="$k" 'BEGIN{ s="KMGT"; v=k; i=1;
           while(v>=1024 && i<4){v/=1024;i++}; printf "%.1f%s", v, substr(s,i,1) }'; }

# in_use <dir> — true if a LIVE process belongs to the SERVICE that owns this
# artifact, so deleting it would break a running service. We match the artifact's
# PARENT (service) dir, not the artifact dir itself: a `node claw3d/server/index.js`
# loads from claw3d/node_modules but its argv only shows ".../claw3d/", and Next.js
# serves claw3d/.next the same way — a dir-level match would MISS both and delete
# them out from under the live UI. Matching the parent also covers the binary-under-
# artifact case (python from .venv/bin, embedded-postgres under node_modules). This
# is deliberately broad: over-skipping a safe dir (user stops the service, re-runs)
# beats deleting a live one. Snapshot ps ONCE; fixed-string match.
PS_SNAPSHOT="$(ps -axo command= 2>/dev/null || true)"
# FAIL-OPEN: an empty snapshot (ps unavailable) → can't prove in-use → not skipped.
# That's the safe bias for a disk tool (it just declines to over-protect). The
# empty-svc guard stops a hypothetical root-level artifact from grepping bare "/"
# (which would match every process and permanently lock the dir). Council P0-B.
in_use() {
  local svc="${1%/*}"
  [[ -n "$svc" && -n "$PS_SNAPSHOT" ]] && grep -qF -- "$svc/" <<<"$PS_SNAPSHOT"
}

# find_artifacts <pattern-args...> — emit TAB-tagged lines: "E<TAB>dir" for
# eligible (delete), "S<TAB>dir" for pattern-matched-but-REFUSED (report only).
# The consumer reads these in the PARENT shell, so the skipped list survives —
# process substitution runs this in a subshell, and tagging is how the parent
# collects both lists (Council Bug 1). Hard-excludes data/ + ALL sibling
# worktrees (prefix glob, Finding 1); skips matches nested inside another artifact.
find_artifacts() {
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    case "$d" in "$ROOT"/data/*|"$ROOT"/.claude/worktrees*) continue ;; esac
    # A match nested INSIDE a node_modules/.venv is already covered by removing
    # that parent — skip it to avoid noise + double-counting (e.g. a bundled
    # dist/ deep inside node_modules/.pnpm/...).
    case "$d" in */node_modules/*|*/.venv/*|*/venv/*) continue ;; esac
    if eligible "$d"; then
      if in_use "$d"; then printf 'U\t%s\n' "$d"   # eligible but a live process runs from it
      else                 printf 'E\t%s\n' "$d"; fi
    else printf 'S\t%s\n' "$d"; fi
  done < <(find "$ROOT" \
              -path "$ROOT/.git" -prune -o \
              -path "$ROOT/data" -prune -o \
              -path "$ROOT/.claude/worktrees*" -prune -o \
              -type d \( "$@" \) -prune -print 2>/dev/null)
}
SKIPPED=()
IN_USE=()

# report_category <label> <reinstall-hint> <find-pattern-args...>
GRAND_K=0
report_category() {
  local label="$1" hint="$2"; shift 2
  local tag path dirs=()
  # Consume in the PARENT shell so SKIPPED[] persists (see find_artifacts).
  while IFS=$'\t' read -r tag path; do
    case "$tag" in
      E) dirs+=("$path") ;;
      S) SKIPPED+=("$path") ;;
      U) IN_USE+=("$path") ;;
    esac
  done < <(find_artifacts "$@")
  (( ${#dirs[@]} == 0 )) && return 0
  local sub_k=0 k d
  printf '\n  %s%s%s  — %s\n' "${C_YELLOW}" "$label" "${C_RESET}" "$hint"
  for d in "${dirs[@]}"; do
    k=$(du_k "$d"); k=${k:-0}; sub_k=$(( sub_k + k ))
    printf '    %7s  %s\n' "$(human "$k")" "${d#"$ROOT"/}"
    if (( DO_DELETE )); then
      # re-check eligibility right before rm (catches a .gitignore / tracking
      # change between scan and delete); warn — never silently — on a failed rm.
      # NB: in_use() is NOT re-checked here — a service that STARTS between the
      # scan and this rm (on an already-eligible dir) isn't caught; that's the
      # accepted snapshot-once TOCTOU window (Council P1-C). Stop services first.
      if eligible "$d"; then rm -rf -- "$d" || warn "could not remove $d"; fi
    fi
  done
  printf '    %7s  (subtotal)\n' "$(human "$sub_k")"
  GRAND_K=$(( GRAND_K + sub_k ))
  TARGETS=$(( TARGETS + ${#dirs[@]} ))
}

# --- run ---------------------------------------------------------------------
hdr "cleanup — regenerable artifacts$( (( DO_DELETE )) && echo ' (DELETING)' || echo ' (dry-run)')"
TARGETS=0
(( WANT_NODE ))   && report_category "node_modules" "rebuilt by 'install'/'start' (npm/pnpm install)" -name node_modules
(( WANT_VENV ))   && report_category "Python .venv"  "rebuilt by the service's install/run step" -name .venv -o -name venv
(( WANT_CACHES )) && report_category "build caches"  "regenerated on next build" \
                       -name .next -o -name .turbo -o -name dist -o -name __pycache__ \
                       -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache

if (( TARGETS == 0 )); then
  ok "Nothing to reclaim — no eligible artifacts found."
else
  printf '\n  %s%s total across %d dir(s).%s\n' "${C_GREEN}" "$(human "$GRAND_K")" "$TARGETS" "${C_RESET}"
fi

# Transparency: never silently ignore a pattern-match we refused to delete.
if (( ${#SKIPPED[@]} > 0 )); then
  warn "Skipped ${#SKIPPED[@]} pattern-matching dir(s) that are TRACKED / not gitignored (left untouched):"
  for s in "${SKIPPED[@]}"; do printf '    - %s\n' "${s#"$ROOT"/}"; done
fi

# Live-process guard: regenerable dirs a running service is using are SKIPPED by
# default (deleting them mid-run breaks the service) — never counted in the total.
if (( ${#IN_USE[@]} > 0 )); then
  warn "Skipped ${#IN_USE[@]} dir(s) backed by a LIVE process (stop the service first, then re-run):"
  for u in "${IN_USE[@]}"; do printf '    - %s\n' "${u#"$ROOT"/}"; done
fi

# --- docker (opt-in) ---------------------------------------------------------
# _cleanup_anon_volumes <dry|delete> — dangling ANONYMOUS volumes (engine label
# com.docker.volume.anonymous). Unlike images/build cache (re-pull/rebuild), a
# removed volume is NON-RECOVERABLE — so both modes ITEMIZE the set (size, age),
# and delete tar-backs-up each one first via docker_anon_orphans (fail-closed;
# AI_STACK_FORCE_WIPE=1 overrides). HOST-WIDE: dangling anon volumes from OTHER
# projects on this engine are listed too — review the list before --yes.
_cleanup_anon_volumes() {
  local mode="$1" v created size n=0 _names=()
  declare -F docker_anon_orphans >/dev/null 2>&1 || { warn "docker.sh not sourced — skipping volume scan."; return 0; }
  # One `docker system df -v` for sizes (docker volume ls has no size column);
  # keep only the volumes-table rows: VOLUME-NAME LINKS SIZE. du/human() do NOT
  # transfer here — a volume has no host path this script can stat.
  local _sizes
  _sizes="$(docker system df -v 2>/dev/null | awk '/^VOLUME NAME/{f=1;next} f&&NF==0{f=0} f&&NF>=3{print $1" "$NF}')"
  # Process substitution (NOT a pipe) so the counter/array live in this shell.
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    _names+=("$v"); n=$((n+1))
    created="$(docker volume inspect "$v" --format '{{.CreatedAt}}' 2>/dev/null | cut -c1-10)"
    size="$(awk -v vol="$v" '$1==vol{print $2}' <<<"$_sizes")"
    printf '    %7s  %s… (created %s)\n' "${size:-n/a}" "${v:0:16}" "${created:-?}"
  done < <(docker_anon_orphans list)
  if (( n == 0 )); then
    log "docker volumes: no dangling anonymous volumes."
    return 0
  fi
  if [[ "$mode" == "delete" ]]; then
    local vbak
    vbak="$ROOT/data/volume-backups/cleanup-$(date +%Y%m%d-%H%M%S)"
    log "Removing the $n volume(s) itemized above (tar backup → ${vbak#"$ROOT"/}/)..."
    docker_anon_orphans remove "$vbak" "${_names[@]}" \
      || warn "some volume(s) were KEPT (backup failed) — see warnings above"
  else
    log "docker volumes (dry-run): $n dangling anonymous volume(s) above would be tar-backed-up + removed (run with --yes)."
  fi
  return 0
}

if (( WANT_DOCKER )); then
  printf '\n'
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    warn "Docker not reachable — skipping the docker prune."
  elif (( DO_DELETE )); then
    warn "docker prune is HOST-WIDE: build cache AND dangling anonymous volumes are shared across ALL projects on this machine, not just ai-stack."
    log "Pruning dangling images + build cache (never named/in-use images)..."
    docker image prune -f   2>/dev/null | tail -1 | sed 's/^/    image:  /' || true
    docker builder prune -f 2>/dev/null | tail -1 | sed 's/^/    build:  /' || true
    ok "docker dangling layers pruned."
    _cleanup_anon_volumes delete
  else
    local_dangling=$(docker image ls -f dangling=true -q 2>/dev/null | wc -l | tr -d ' ')
    warn "--docker prune is HOST-WIDE: build cache + dangling anon volumes are shared across all projects on this machine."
    log "docker (dry-run): ${local_dangling:-0} dangling image(s) + reclaimable build cache would be pruned (run with --yes)."
    _cleanup_anon_volumes dry
  fi
fi

# --- footer ------------------------------------------------------------------
if (( DO_DELETE )); then
  (( TARGETS > 0 )) && ok "Reclaimed ~$(human "$GRAND_K"). Re-run 'install'/'start' to rebuild on demand."
else
  printf '\n'
  log "Dry-run — nothing was deleted. Re-run with ${C_BOLD:-}--yes${C_RESET:-} to delete, e.g.:"
  printf '    mayssam-ai-stack.sh cleanup --yes\n'
fi
exit 0
