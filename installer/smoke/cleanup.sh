#!/usr/bin/env bash
# smoke/cleanup.sh — proves the `cleanup` command's SAFETY INVARIANT, the only
# thing that makes a disk-reclaiming `rm -rf` safe to ship:
#
#   A directory is deleted ONLY if it (1) matches a regenerable-artifact pattern
#   AND (2) git ignores it. Tracked source is structurally un-deletable; the live
#   data/ tree and sibling worktrees are hard-excluded.
#
# The test stands up a THROWAWAY git repo (never the real one), points cleanup.sh
# at it via $AI_STACK, and asserts: dry-run deletes nothing; --yes removes only
# the gitignored artifact in scope; a TRACKED node_modules and an out-of-scope
# .venv both survive.
set -Eeuo pipefail
AI_STACK_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AI_STACK="$AI_STACK_REAL"   # for common.sh's own logging; cleanup runs get $AI_STACK=$TMP per-invocation
source "$AI_STACK_REAL/installer/lib/common.sh"

hdr "Smoke cleanup — delete-only-if-(pattern AND gitignored)"

CLEANUP="$AI_STACK_REAL/installer/lib/cleanup.sh"
[[ -f "$CLEANUP" ]] || { err "cleanup.sh not found at $CLEANUP"; exit 1; }

# --- throwaway fixture repo --------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" config user.email t@t.t
git -C "$TMP" config user.name t

# gitignored artifacts (SHOULD be reclaimable)
printf 'node_modules/\n.venv/\n.next/\n' > "$TMP/.gitignore"
mkdir -p "$TMP/pkg/node_modules/dep"   ; echo x > "$TMP/pkg/node_modules/dep/i.js"
mkdir -p "$TMP/svc/.venv/lib"          ; echo x > "$TMP/svc/.venv/lib/p.py"
mkdir -p "$TMP/ui/.next/cache"         ; echo x > "$TMP/ui/.next/cache/c"

# TRACKED source (MUST never be touched) — a dir literally named node_modules,
# force-added so it is committed source, not ignored.
mkdir -p "$TMP/vendored/node_modules" ; echo keep > "$TMP/vendored/node_modules/keep.txt"
echo keep > "$TMP/src.txt"

# NESTED-.gitignore TRAP (Council Finding 4): a COMMITTED dist/ shadowed by a
# nested .gitignore that ignores dist/. `git check-ignore` alone would call this
# "ignored" and delete committed source — the has-tracked clause must refuse it.
mkdir -p "$TMP/sub/dist"               ; echo keep > "$TMP/sub/dist/keep.txt"
printf 'dist/\n' > "$TMP/sub/.gitignore"

git -C "$TMP" add -f src.txt vendored/node_modules/keep.txt .gitignore \
  sub/.gitignore sub/dist/keep.txt
git -C "$TMP" commit -qm init

pass=0; fail=0
check() { # check <desc> <test-expr...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; pass=$(( pass + 1 ));
  else err "FAIL: $desc"; fail=$(( fail + 1 )); fi
}

# 1. DRY-RUN deletes nothing and reports the two in-scope gitignored dirs.
out="$(AI_STACK="$TMP" bash "$CLEANUP" 2>&1)"
check "dry-run preserves gitignored node_modules" test -d "$TMP/pkg/node_modules"
check "dry-run preserves gitignored .venv"        test -d "$TMP/svc/.venv"
check "dry-run lists node_modules" bash -c "grep -q 'node_modules' <<<\"\$1\"" _ "$out"
check "dry-run lists .venv"        bash -c "grep -q '.venv'        <<<\"\$1\"" _ "$out"

# 2. The TRACKED node_modules is surfaced as SKIPPED (the "    - <path>" form),
#    never as a deletion target (the "  <size>  <path>" form).
check "tracked node_modules shown as Skipped, not a deletion target" \
  bash -c "grep -qE '^[[:space:]]+- vendored/node_modules' <<<\"\$1\"" _ "$out"

# 3. EXECUTE scoped to --node: only the gitignored node_modules goes.
AI_STACK="$TMP" bash "$CLEANUP" --node --yes >/dev/null 2>&1
check "--yes --node removes gitignored node_modules" test '!' -d "$TMP/pkg/node_modules"
check "--yes --node leaves TRACKED node_modules"     test -d "$TMP/vendored/node_modules"
check "--yes --node leaves out-of-scope .venv"       test -d "$TMP/svc/.venv"
check "TRACKED keep.txt intact"                      test -f "$TMP/vendored/node_modules/keep.txt"

# 4. SKIPPED transparency (Council Bug 1): the TRACKED node_modules matches the
#    pattern but is refused — it MUST surface in the "Skipped" warning, not vanish.
check "dry-run warns it Skipped the tracked match" \
  bash -c "grep -qi 'Skipped' <<<\"\$1\"" _ "$out"

# 5. NESTED-.gitignore data-loss guard (Council Finding 4): committed sub/dist
#    is pattern-matched + check-ignore'd as ignored, but has a tracked file —
#    --caches --yes MUST leave it alone.
AI_STACK="$TMP" bash "$CLEANUP" --caches --yes >/dev/null 2>&1
check "--caches removes gitignored .next"            test '!' -d "$TMP/ui/.next"
check "--caches SPARES committed dist (nested .gitignore trap)" test -d "$TMP/sub/dist"
check "committed dist/keep.txt intact"               test -f "$TMP/sub/dist/keep.txt"

# 6. Bad flag exits 2 (not 0, not a silent no-op). Capture rc without tripping -e.
rc=0; AI_STACK="$TMP" bash "$CLEANUP" --bogus >/dev/null 2>&1 || rc=$?
check "unknown flag exits 2" test "$rc" -eq 2

# 7. Empty repo (no artifacts) → clean exit 0 with an honest message.
EMPTY="$(mktemp -d)"; git -C "$EMPTY" init -q
emptyrc=0; emptyout="$(AI_STACK="$EMPTY" bash "$CLEANUP" 2>&1)" || emptyrc=$?
check "empty repo exits 0"                  test "$emptyrc" -eq 0
check "empty repo says Nothing to reclaim"  bash -c "grep -qi 'Nothing to reclaim' <<<\"\$1\"" _ "$emptyout"
rm -rf "$EMPTY"

# 8. Non-git dir → fail CLOSED (exit 2), never a misleading 'Nothing to reclaim'.
NOGIT="$(mktemp -d)"; mkdir -p "$NOGIT/pkg/node_modules"
rc=0; AI_STACK="$NOGIT" bash "$CLEANUP" >/dev/null 2>&1 || rc=$?
check "non-git dir aborts (exit 2)" test "$rc" -eq 2
rm -rf "$NOGIT"

# 9. LIVE-process guard: a gitignored node_modules with a running process rooted
#    inside it MUST be skipped (not deleted) even with --yes, and reported.
mkdir -p "$TMP/live/node_modules/bin"
# A harmless long-lived process whose argv contains the dir path (so `ps -axo
# command=` shows "<dir>/..."), exactly how node/python/postgres appear in ps.
# The '; :' compound keeps bash from exec-replacing itself with sleep (which would
# drop the $0 marker path from argv).
bash -c 'sleep 30; :' "$TMP/live/node_modules/bin/marker" &
LIVEPID=$!
sleep 0.3   # let ps see it
liveout="$(AI_STACK="$TMP" bash "$CLEANUP" --node 2>&1)"
check "dry-run flags the in-use dir as LIVE"  bash -c "grep -qi 'LIVE process' <<<\"\$1\"" _ "$liveout"
AI_STACK="$TMP" bash "$CLEANUP" --node --yes >/dev/null 2>&1
check "--yes SPARES the in-use node_modules"  test -d "$TMP/live/node_modules"
kill "$LIVEPID" 2>/dev/null || true; wait "$LIVEPID" 2>/dev/null || true
# Once the process is gone, it becomes deletable.
liveout2="$(AI_STACK="$TMP" bash "$CLEANUP" --node 2>&1)"
check "after process exits, dir is reclaimable" \
  bash -c "grep -q 'live/node_modules' <<<\"\$1\" && ! grep -qi 'LIVE process' <<<\"\$1\"" _ "$liveout2"

echo
if (( fail == 0 )); then ok "cleanup smoke PASSED ($pass checks)"; exit 0
else err "cleanup smoke FAILED ($fail of $((pass+fail)))"; exit 1; fi
