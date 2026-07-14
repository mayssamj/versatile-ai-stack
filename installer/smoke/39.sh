#!/usr/bin/env bash
# smoke/39.sh — phase 39 (fleet memory) OFFLINE/hermetic smoke.
#
# Unlike the live E2E smokes (27/30), slice-1 wiring is host `claude mcp add -s user`,
# which mutates the REAL ~/.claude and needs a running claude + docs-mcp + mempalace. So
# this smoke instead exercises the wiring LOGIC hermetically with a stub `claude` on PATH:
# no real config is touched, no models loaded, no network. It proves:
#   A. claude-absent  → register helpers skip non-fatally (return 0)
#   B. stdio register → remove-then-add (idempotent) against the mempalace-mcp wrapper
#   C. http register  → correct `--transport http <name> <url>` flag shape (docs-mcp)
#   D. doctor check 74 → skip-clean when Phase 39 unstamped; names the exact missing MCPs
#      when stamped; passes when both are present.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/memory_mcp.sh"

hdr "Smoke 39 — fleet memory (claude-cli wiring, hermetic)"
fail() { err "Smoke 39 FAIL — $*"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleetmem-smoke-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
export CLAUDE_CALLS="$TMP/claude-calls.log"; : > "$CLAUDE_CALLS"
export CLAUDE_LIST="$TMP/mcp-list.txt";    : > "$CLAUDE_LIST"

# stub `claude`: log argv; `mcp list` echoes $CLAUDE_LIST; everything else logs + exits 0.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CLAUDE_CALLS"
[[ "$1" == "mcp" && "$2" == "list" ]] && cat "$CLAUDE_LIST"
exit 0
STUB
chmod +x "$BIN/claude"

# A. claude ABSENT → non-fatal skip (return 0). Restricted PATH hides any real claude.
( PATH="/usr/bin:/bin"; _mem_claude_register_stdio mempalace /x/y >/dev/null 2>&1 ) \
  || fail "A: register_stdio must return 0 when claude is absent"
ok "A: claude-absent → non-fatal skip"

# B. stdio register = remove-then-add against the wrapper.
: > "$CLAUDE_CALLS"
PATH="$BIN:$PATH" _mem_claude_register_stdio mempalace "$AI_STACK/bin/mempalace-mcp" >/dev/null 2>&1 || true
grep -q "mcp remove -s user mempalace" "$CLAUDE_CALLS" || fail "B: expected 'mcp remove' before add"
grep -q "mcp add -s user mempalace -- $AI_STACK/bin/mempalace-mcp" "$CLAUDE_CALLS" \
  || fail "B: expected 'mcp add -s user mempalace -- <wrapper>'"
ok "B: stdio register = remove-then-add (idempotent)"

# C. http register flag shape (docs-mcp).
: > "$CLAUDE_CALLS"
PATH="$BIN:$PATH" _mem_claude_register_http docs-mcp "http://localhost:8765/mcp" >/dev/null 2>&1 || true
grep -q "mcp add -s user --transport http docs-mcp http://localhost:8765/mcp" "$CLAUDE_CALLS" \
  || fail "C: expected 'mcp add -s user --transport http docs-mcp <url>'"
ok "C: http register flag shape correct"

# D. doctor check 74. Source it against a HERMETIC AI_STACK ($TMP) so the phase-stamp
#    probe reads our temp state dir, not the real one. Arrays declared so `set -u` sourcing is safe.
declare -a CHECKS=(); declare -A CHECK_TITLE=()
source "$AI_STACK/installer/doctor/checks/74_fleet_memory_mcp.sh"
_fm_resolve_openshell() { echo ""; }   # hermetic: stub out the live hermes-fleet sandbox probe
mkdir -p "$TMP/installer/state"

# D1. unstamped → skip-clean (0), even with claude present.
( PATH="$BIN:$PATH"; AI_STACK="$TMP" fleet_memory_mcp_diagnose >/dev/null 2>&1 ) \
  || fail "D1: unstamped Phase 39 must skip-clean (return 0)"
ok "D1: doctor skip-clean when Phase 39 not installed"

# D2. stamped + empty registration list → return 1 naming BOTH missing MCPs.
touch "$TMP/installer/state/phase_39.done"; : > "$CLAUDE_LIST"
d2="$(PATH="$BIN:$PATH" AI_STACK="$TMP" fleet_memory_mcp_diagnose 2>&1)" && d2rc=0 || d2rc=$?
[[ "$d2rc" -eq 1 ]]                        || fail "D2: stamped+empty must return 1 (got $d2rc)"
grep -q "mempalace' not registered" <<<"$d2" || fail "D2: must name mempalace missing"
grep -q "docs-mcp' not registered"  <<<"$d2" || fail "D2: must name docs-mcp missing"
ok "D2: doctor flags both missing MCPs when stamped"

# D3. stamped + both listed → return 0.
printf 'mempalace: %s - ok\ndocs-mcp: http://localhost:8765/mcp - ok\n' "$AI_STACK/bin/mempalace-mcp" > "$CLAUDE_LIST"
( PATH="$BIN:$PATH"; AI_STACK="$TMP" fleet_memory_mcp_diagnose >/dev/null 2>&1 ) \
  || fail "D3: both MCPs registered must return 0"
ok "D3: doctor passes when both MCPs registered"

ok "Smoke 39 PASS — fleet-memory claude-cli wiring logic verified hermetically"
