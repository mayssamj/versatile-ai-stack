#!/usr/bin/env bash
# smoke/sandbox-present.sh — regression test for common.sh's sandbox_present(), the
# EPIPE-safe `openshell sandbox list` presence probe. OFFLINE/hermetic: no openshell, no
# gateway, no sandbox, no models, no network — a stub `osh` shim stands in for the real
# Rust binary.
#
# WHAT IT PINS (the 2026-07-16 incident): `sandbox list | grep -q "$name"` reports a
# sandbox ABSENT when it is PRESENT. grep -q exits on the matching MIDDLE row, closing the
# pipe; the Rust openshell binary (SIGPIPE=SIG_IGN) then PANICS on its next write and exits
# 101; `set -o pipefail` promotes that 101 to the pipeline status, so the `if` is FALSE even
# though grep MATCHED, and `2>/dev/null` hides the panic. awk is immune — it DRAINS stdin.
#
# The shim emulates Rust exactly: `trap '' PIPE` (SIG_IGN) + exit 101 when a write fails.
# It sleeps between rows so the reader has certainly exited before the post-match write —
# that turns the real-world 8/10 flake into a DETERMINISTIC 10/10 reproduction.
#
# MUST run under /bin/bash: the race does NOT reproduce under zsh.
#   bash installer/smoke/sandbox-present.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke sandbox_present — openshell EPIPE/pipefail race (hermetic)"
fail() { err "Smoke sandbox-present FAIL — $*"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sbpresent-smoke-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
OSH="$TMP/osh"

# Stub openshell: header + 3 rows, target in the MIDDLE. Rust semantics — SIGPIPE ignored,
# panic-equivalent exit 101 the moment a write to the closed pipe fails.
cat > "$OSH" <<'SHIM'
#!/usr/bin/env bash
trap '' PIPE                      # Rust sets SIGPIPE=SIG_IGN — do NOT die quietly
[[ "$1" == "sandbox" && "$2" == "list" ]] || exit 2
emit() { printf '%s\n' "$1" || { echo "thread 'main' panicked: failed printing to stdout: Broken pipe (os error 32)" >&2; exit 101; }; }
emit "NAME             PHASE"
emit "pi-v1            Ready"
emit "hermes-fleet-v1  Ready"     # <- the row a grep -q for the fleet matches
sleep 0.2                          # let the reader exit + close the pipe (determinism)
emit "zulu-v1          Ready"      # <- this write EPIPEs -> exit 101
exit 0
SHIM
chmod +x "$OSH"

# 0. The shim must actually reproduce the race, else every later assertion is vacuous.
#    PIPESTATUS proves the mechanism: openshell=101 while grep=0 (grep DID match).
set +e
"$OSH" sandbox list 2>/dev/null | grep -q hermes-fleet-v1
ps=("${PIPESTATUS[@]}")
set -e
[[ "${ps[0]}" == "101" ]] || fail "0: shim did not EPIPE-panic (openshell rc=${ps[0]}, expected 101) — test is vacuous"
[[ "${ps[1]}" == "0"   ]] || fail "0: grep did not match (rc=${ps[1]}) — test is vacuous"
ok "0: race reproduced — PIPESTATUS=[${ps[0]} ${ps[1]}] (openshell panicked 101, grep matched 0)"

# 1. CONTROL — the OLD `grep -q` form under pipefail must get it WRONG (sandbox present,
#    verdict "absent"). This is the bug; if it ever stops firing, the fix is untestable.
if "$OSH" sandbox list 2>/dev/null | grep -q hermes-fleet-v1; then
  fail "1: control unexpectedly TRUE — the grep -q form is supposed to lose this race"
fi
ok "1: control — 'sandbox list | grep -q' says ABSENT for a PRESENT sandbox (the bug)"

# 2. THE FIX — sandbox_present must say PRESENT, under the same pipefail shell.
sandbox_present "$OSH" hermes-fleet-v1 \
  || fail "2: sandbox_present must be TRUE for a present sandbox (EPIPE race not handled)"
ok "2: sandbox_present — TRUE for a present sandbox despite the EPIPE panic"

# 3. No false positives: an absent sandbox is absent (and the shim exits 0, not 101, here —
#    a full drain — so this also proves we honor a clean 'not found').
if sandbox_present "$OSH" nope-v1; then fail "3: sandbox_present must be FALSE for an absent sandbox"; fi
ok "3: sandbox_present — FALSE for an absent sandbox"

# 4. Column-exact, not substring: `grep -q hermes` would match; $1==n must not.
if sandbox_present "$OSH" hermes; then fail "4: sandbox_present must match the NAME column exactly, not a substring"; fi
ok "4: sandbox_present — exact NAME-column match (no substring false positive)"

# 5. Header row is never a match (NR>1).
if sandbox_present "$OSH" NAME; then fail "5: sandbox_present must skip the header row"; fi
ok "5: sandbox_present — header row skipped"

# 6. Empty osh path → FALSE, never a crash (callers pass "$(_mem_resolve_openshell)" raw).
if sandbox_present "" hermes-fleet-v1; then fail "6: sandbox_present must be FALSE when osh is empty"; fi
ok "6: sandbox_present — FALSE (no crash) when the openshell path is empty"

# 7. A failing openshell (gateway down) → FALSE, not a spurious TRUE.
if sandbox_present "$TMP/does-not-exist" hermes-fleet-v1; then fail "7: sandbox_present must be FALSE when openshell cannot run"; fi
ok "7: sandbox_present — FALSE when the openshell CLI itself fails"

# 8. Empty NAME → FALSE. `awk '$1==n'` with n="" matches a trailing BLANK row (awk sets $1=""
#    on an empty line), so an unset/empty caller arg would report a sandbox PRESENT. Latent
#    today (all 7 call sites pass literals) — pinned so it stays that way.
OSH_BLANK="$TMP/osh-blank"
cat > "$OSH_BLANK" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "sandbox" && "$2" == "list" ]] || exit 2
printf '%s\n' "NAME             PHASE" "pi-v1            Ready" ""
SHIM
chmod +x "$OSH_BLANK"
if sandbox_present "$OSH_BLANK" ""; then fail "8: sandbox_present must be FALSE for an empty name (trailing blank row)"; fi
ok "8: sandbox_present — FALSE for an empty name (no trailing-blank-row false positive)"

# --- sandbox_ready: presence is NOT enough; the WIRING branches gate on Ready ---------
# A fleet that is present-but-Creating cannot be `sandbox exec`'d, so wiring is impossible —
# but _mem_hermes_*_wired is LENIENT about a non-Ready fleet, which made verify-then-stamp
# VACUOUS (false "verified" + stamp on an unwired fleet). sandbox_ready is the gate.
OSH_MIX="$TMP/osh-mixed"
cat > "$OSH_MIX" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "sandbox" && "$2" == "list" ]] || exit 2
printf '%s\n' "NAME             PHASE" "ready-v1         Ready" "creating-v1      Creating" "term-v1          Terminating"
SHIM
chmod +x "$OSH_MIX"

sandbox_ready "$OSH_MIX" ready-v1 || fail "9: sandbox_ready must be TRUE for a Ready sandbox"
ok "9: sandbox_ready — TRUE for a Ready sandbox"

# 10. THE M2 CASE: present, but NOT Ready. sandbox_present says yes; sandbox_ready must not.
sandbox_present "$OSH_MIX" creating-v1 || fail "10: precondition — sandbox_present must be TRUE for a Creating sandbox"
if sandbox_ready "$OSH_MIX" creating-v1; then fail "10: sandbox_ready must be FALSE for a Creating (present-but-not-Ready) sandbox"; fi
ok "10: sandbox_ready — FALSE for a present-but-Creating sandbox (present=TRUE, ready=FALSE)"

if sandbox_ready "$OSH_MIX" term-v1; then fail "11: sandbox_ready must be FALSE for a Terminating sandbox"; fi
ok "11: sandbox_ready — FALSE for a Terminating sandbox"

if sandbox_ready "$OSH_MIX" nope-v1; then fail "12: sandbox_ready must be FALSE for an absent sandbox"; fi
if sandbox_ready "" ready-v1;         then fail "12: sandbox_ready must be FALSE when osh is empty"; fi
if sandbox_ready "$OSH_MIX" "";       then fail "12: sandbox_ready must be FALSE for an empty name"; fi
ok "12: sandbox_ready — FALSE for absent / empty-osh / empty-name"

# 13. sandbox_ready inherits the EPIPE immunity (same awk form) — prove it on the racing shim.
sandbox_ready "$OSH" hermes-fleet-v1 \
  || fail "13: sandbox_ready must be TRUE for a present+Ready sandbox despite the EPIPE panic"
ok "13: sandbox_ready — TRUE despite the EPIPE panic (drains stdin like sandbox_present)"

ok "Smoke sandbox_present PASS — EPIPE/pipefail race handled; grep -q form proven broken; Ready-gate pinned"
