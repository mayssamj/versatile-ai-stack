#!/usr/bin/env bash
# Unit tests for installer/lib/worktree.sh — the guard that refuses operating the
# LIVE stack from a git worktree (the 2026-06-20 bind-mount incident). Runs
# OFFLINE; the one real `git worktree` it creates is a THROWAWAY temp dir and is
# only used to test the DETECTION function — the stack is NEVER run from it.
# Run:  bash installer/smoke/worktree.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/worktree.sh"

hdr "Smoke worktree — guard detection (offline)"

# --- 1. the MAIN working tree is NOT a worktree (no false positive) ----------
# This is the load-bearing case: a false positive here would BRICK normal installs.
log "main checkout is NOT detected as a worktree (no install-bricking false positive)"
if ai_stack_is_worktree "$AI_STACK"; then
  err "FALSE POSITIVE: main checkout '$AI_STACK' detected as a worktree — would brick installs"; exit 1
fi
ok "main checkout correctly NOT a worktree"

# --- 2. the .claude/worktrees/ fast-path is detected -------------------------
log ".claude/worktrees/ path is detected as a worktree (fast path)"
ai_stack_is_worktree "/tmp/whatever/.claude/worktrees/x" \
  || { err "fast-path .claude/worktrees/ not detected"; exit 1; }
ok ".claude/worktrees/ fast path detected"

# --- 3. a REAL linked worktree is detected ----------------------------------
log "a real linked git worktree is detected (and the main path is recoverable)"
WT="$(mktemp -d -t aistack-wt-test.XXXXXX)/wt"
git -C "$AI_STACK" worktree add --detach "$WT" HEAD >/dev/null 2>&1 \
  || { err "could not create test worktree"; exit 1; }
# Cleanup is registered immediately so a later failure can't leak the worktree.
cleanup() { git -C "$AI_STACK" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$(dirname "$WT")"; }
trap cleanup EXIT
ai_stack_is_worktree "$WT" || { err "real linked worktree NOT detected"; exit 1; }
# ai_stack_main_path from inside the worktree must resolve back to the main checkout.
main_resolved="$(ai_stack_main_path "$WT")"
[[ "$main_resolved" == "$AI_STACK" ]] || { err "ai_stack_main_path wrong: '$main_resolved' != '$AI_STACK'"; exit 1; }
ok "real linked worktree detected + main path resolved"

# --- 4. worktree_guard ALLOWS the main tree (returns 0, no exit) -------------
log "worktree_guard allows the main tree (returns, does not exit)"
( set -Eeuo pipefail; AI_STACK="$AI_STACK"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/worktree.sh"
  worktree_guard install ) \
  || { err "worktree_guard wrongly blocked the MAIN tree (exit non-zero)"; exit 1; }
ok "worktree_guard allows main tree"

# --- 5. worktree_guard BLOCKS a worktree (exits 2) --------------------------
log "worktree_guard refuses a worktree with exit 2"
rc=0
( set -Eeuo pipefail; AI_STACK="$WT"
  source "$AI_STACK/installer/lib/common.sh" 2>/dev/null || source "$(git -C "$WT" rev-parse --show-toplevel)/installer/lib/common.sh"
  source "$WT/installer/lib/worktree.sh"
  worktree_guard install ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || { err "worktree_guard should exit 2 from a worktree, got $rc"; exit 1; }
ok "worktree_guard refuses a worktree (exit 2)"

# --- 6. worktree_guard_soft WARNs + returns 1 (does NOT exit) ----------------
log "worktree_guard_soft returns 1 from a worktree (skips, does not abort)"
rc=0
( set -Eeuo pipefail; AI_STACK="$WT"
  source "$WT/installer/lib/common.sh"; source "$WT/installer/lib/worktree.sh"
  worktree_guard_soft "auto-heal" && exit 0 || exit 1 ) >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]] || { err "worktree_guard_soft should return 1 from a worktree, got $rc"; exit 1; }
ok "worktree_guard_soft returns 1 (skip, no abort)"

ok "worktree smoke: all tests passed"
