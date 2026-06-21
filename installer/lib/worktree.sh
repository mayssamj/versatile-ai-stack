#!/usr/bin/env bash
# worktree.sh — guard against operating the LIVE stack from a git worktree.
#
# WHY THIS EXISTS (incident 2026-06-20): the stack's containers bind-mount paths
# resolved from $AI_STACK (honcho's Postgres data dir + init.sql via the phase-03
# override, autofyn's /workspace, etc.). When `vz-ai-stack.sh install/start` (or
# any `docker compose up`) ran with $AI_STACK pointing at a git WORKTREE, those
# containers were (re)created bound to the worktree path. Removing the worktree
# then vanished the mount sources -> Postgres couldn't start -> LiteLLM returned
# HTTP 503 `no_db_connection` for every key -> doctor misread it as "key revoked".
#
# The structural fix: the live stack must only ever be operated from the MAIN
# working tree. This helper detects a linked worktree ROBUSTLY (works for the
# .claude/worktrees/ layout AND sibling worktrees) and refuses stack-MUTATING
# operations (install/start/compose/recreate, and the doctor auto-heal), pointing
# the user at the real checkout. Read-only ops (status/list/doctor-diagnose/help/
# --dry-run) are NOT guarded — you can inspect from anywhere.
#
# Sourced AFTER common.sh (uses err/warn). No-op (allows) when not a git repo
# (e.g. a tarball install) — git-clone installs are the only place worktrees exist.

# ai_stack_is_worktree — return 0 iff $AI_STACK is a LINKED git worktree (not the
# main working tree). A linked worktree has git-dir != git-common-dir; the main
# tree has them equal. Also treats a `.claude/worktrees/` path as a worktree even
# if git can't answer (belt-and-suspenders). Returns 1 (not a worktree / unknown)
# when git is unavailable or $AI_STACK isn't a repo — fail OPEN so normal installs
# are never blocked.
ai_stack_is_worktree() {
  local base="${1:-$AI_STACK}"
  # Fast path: the harness's native worktree layout.
  case "$base" in */.claude/worktrees/*) return 0 ;; esac
  command -v git >/dev/null 2>&1 || return 1
  local gd cd
  gd="$(git -C "$base" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  # --git-common-dir may be relative; resolve it against the repo for comparison.
  cd="$(git -C "$base" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$cd" in
    /*) : ;;                                    # already absolute
    *)  cd="$(cd "$base" 2>/dev/null && cd "$cd" 2>/dev/null && pwd -P)" || return 1 ;;
  esac
  gd="$(cd "$gd" 2>/dev/null && pwd -P 2>/dev/null || echo "$gd")"
  [[ -n "$gd" && -n "$cd" && "$gd" != "$cd" ]]
}

# ai_stack_main_path — echo the MAIN working tree path (where the stack should be
# operated from). Derived from git-common-dir (<main>/.git -> <main>). Empty if
# undeterminable.
ai_stack_main_path() {
  local base="${1:-$AI_STACK}" cd
  command -v git >/dev/null 2>&1 || return 0
  cd="$(git -C "$base" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$cd" in
    /*) : ;;
    *)  cd="$(cd "$base" 2>/dev/null && cd "$cd" 2>/dev/null && pwd -P)" || return 0 ;;
  esac
  # <main>/.git -> <main>  (worktrees store common-dir as the main repo's .git)
  [[ "$(basename "$cd")" == ".git" ]] && dirname "$cd" || echo ""
}

# worktree_guard <operation-label> — REFUSE a stack-mutating operation when run
# from a linked worktree. Call at the top of install/start (post-flag-parse so
# --dry-run stays exempt) and before any auto-heal that touches docker. Exits 2.
worktree_guard() {
  local op="${1:-this operation}"
  ai_stack_is_worktree || return 0
  local main; main="$(ai_stack_main_path)"
  err "Refusing to run '$op' from a git worktree:"
  err "    $AI_STACK"
  err "The LIVE stack must be operated from the main checkout — containers bind-mount"
  err "paths under \$AI_STACK, and removing a worktree would break the running stack"
  err "(see the 2026-06-20 honcho-database incident)."
  if [[ -n "$main" ]]; then
    err "Run it from the main checkout instead:"
    err "    cd $main && ./vz-ai-stack.sh ${op} ..."
  fi
  exit 2
}

# worktree_guard_soft <operation-label> — like worktree_guard but WARN + return 1
# instead of exiting, for callers that want to skip an auto-action (e.g. the
# doctor auto-heal) rather than abort the whole run.
worktree_guard_soft() {
  local op="${1:-this operation}"
  ai_stack_is_worktree || return 0
  local main; main="$(ai_stack_main_path)"
  warn "Skipping '$op' auto-recovery: running from a git worktree ($AI_STACK)."
  [[ -n "$main" ]] && warn "Recover from the main checkout: cd $main && ./vz-ai-stack.sh doctor"
  return 1
}
