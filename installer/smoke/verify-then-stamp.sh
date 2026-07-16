#!/usr/bin/env bash
# smoke/verify-then-stamp.sh — regression test for CHANGE 2 of the 2026-07-16 incident:
# the VERIFY-THEN-STAMP contract in phases 39 (fleet_memory) / 40 (honcho_mcp) /
# 41 (falkordb_mcp). OFFLINE/hermetic: no openshell, no gateway, no sandbox, no models,
# no network, no npm/docker/claude — a stub `openshell` shim + a fake in-sandbox
# config.yaml + a THROWAWAY AI_STACK (so stamp_mark/stamp_check write to a temp state
# dir, NEVER the real installer/state/).
#
# WHAT IT PINS (the incident): before change 2, a phase's wiring branch was
#   `configure_hermes_mcp_… || warn …` immediately followed by an UNCONDITIONAL
#   `stamp_mark`. So a run that ATTEMPTED wiring but the wiring did NOT land still
#   stamped .done, and only doctor check 74/75/76 (red) ever noticed. Change 2 gates the
#   stamp on the doctor's OWN post-condition assertion (_mem_hermes_{docs,honcho,falkordb}_wired).
#
# SCOPE / HONESTY (SOUL §19 fact-vs-claim): running a whole phase top-to-bottom is
# impractical hermetically (npm install / honcho embedding self-heal / claude mcp add /
# docker policy set / worktree_guard). So this smoke tests the EXTRACTED verify-then-stamp
# BRANCH — a faithful copy of the block that is byte-shared across all three phases —
# driving it with the REAL helpers under test: sandbox_ready + the _mem_hermes_*_wired
# family (installer/lib/{common,memory_mcp}.sh) + the REAL stamp_mark/stamp_check
# (installer/lib/common.sh). What is PINNED here: those real helpers + the real stamp
# mechanism produce the right stamp/exit outcome in each of the four incident scenarios.
# What is NOT pinned here (only READ): that the three phase FILES still literally contain
# that branch shape — that invariant is guarded by doctor check 78 (verify_then_stamp_guard),
# the drift guard. The two are complementary: this proves the CONTRACT is correct; check 78
# proves the phases still IMPLEMENT it.
#
# Runs clean under BOTH /opt/homebrew/bin/bash (5) and /bin/bash (3.2); no bash-4 features.
#   bash installer/smoke/verify-then-stamp.sh      (or: vz-ai-stack.sh test verify-then-stamp)
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vts-smoke-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# THROWAWAY AI_STACK — common.sh derives STATE_DIR from it, so stamp_mark/stamp_check
# write here, never into the real installer/state/. Source the REAL libs under test.
export AI_STACK="$TMP/stack"; mkdir -p "$AI_STACK"
source "$REPO/installer/lib/common.sh"       # log/ok/err/note + stamp_mark/stamp_check + sandbox_ready
source "$REPO/installer/lib/memory_mcp.sh"    # _mem_hermes_{docs,honcho,falkordb}_wired

hdr "Smoke verify-then-stamp — phases 39/40/41 stamp-gate contract (hermetic)"
fail() { err "Smoke verify-then-stamp FAIL — $*"; exit 1; }

# --- stub openshell: drives sandbox_ready (via $SB_LIST) and the _mem_hermes_*_wired
#     in-sandbox config probe (via $FAKE_CONFIG). Faithful to what the real helpers call:
#       sandbox list                                   → table on stdout
#       sandbox exec … -- bash -c '<prog>' _ KEY ENDPT → WIRED/MISSING for KEY+ENDPT in config
OSH="$TMP/osh"
cat > "$OSH" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == "sandbox" && "$2" == "list" ]]; then
  printf '%s\n' "NAME             PHASE"
  [[ -n "${SB_LIST:-}" && -f "$SB_LIST" ]] && cat "$SB_LIST"
  exit 0
fi
if [[ "$1" == "sandbox" && "$2" == "exec" ]]; then
  # The real profile_wired passes `… -- bash -c '<prog>' _ "$key" "$endpoint"`, so KEY and
  # ENDPOINT are the last two positional args. Grab them portably (bash 3.2-safe).
  key=""; endpoint=""
  for a in "$@"; do key="$endpoint"; endpoint="$a"; done
  f="${FAKE_CONFIG:-/nonexistent}"
  if [[ -f "$f" ]] && grep -q "$key:" "$f" && grep -q "$endpoint" "$f"; then echo WIRED; else echo MISSING; fi
  exit 0
fi
exit 2
SHIM
chmod +x "$OSH"

SANDBOX=hermes-fleet-v1
STAMP_FILE() { echo "$STATE_DIR/phase_${1}.done"; }   # STATE_DIR is set by common.sh

# Fixtures.
SB_READY="$TMP/sb-ready";    printf '%s\n' "hermes-fleet-v1  Ready"    > "$SB_READY"
SB_CREATING="$TMP/sb-creat"; printf '%s\n' "hermes-fleet-v1  Creating" > "$SB_CREATING"
SB_EMPTY="$TMP/sb-empty";    : > "$SB_EMPTY"                            # header only → no sandbox
CFG_WIRED="$TMP/cfg-wired"                                             # a fully-wired profile
cat > "$CFG_WIRED" <<'CFG'
mcp_servers:
  docs: { url: "http://host.docker.internal:8765/mcp" }
  honcho: { url: "http://host.docker.internal:7082/mcp" }
  falkordb: { url: "http://host.docker.internal:7083/mcp" }
CFG
CFG_UNWIRED="$TMP/cfg-unwired"; printf '%s\n' "mcp_servers: {}" > "$CFG_UNWIRED"

# vts_branch <phase> <key> <port> — a FAITHFUL COPY of the verify-then-stamp block shared by
# phases 39/40/41 (the `configure_hermes_mcp_… || warn` line is elided — its rc is advisory and
# there is no real fleet to configure). Run it in a SUBSHELL so its `exit 1` is captured.
# VTS_MUTATE=1 reverts it to the PRE-FIX (buggy) form — used only by the mutation demonstration.
vts_branch() {
  local phase="$1" key="$2" port="$3"
  if [[ "${VTS_MUTATE:-0}" == "1" ]]; then
    # PRE-CHANGE-2 BUG: attempt wiring, then stamp UNCONDITIONALLY (no post-condition gate).
    if sandbox_ready "$OSH" "$SANDBOX"; then : ; fi   # (configure … || warn)
    stamp_mark "$phase"; return 0
  fi
  if sandbox_ready "$OSH" "$SANDBOX"; then
    # (configure_hermes_mcp_${key} "$OSH" "$SANDBOX" "$port" || warn … — elided)
    if "_mem_hermes_${key}_wired" "$OSH" "$port"; then
      ok "  [$key] hermes fleet wiring verified"
    else
      err "  [$key] hermes fleet wiring did NOT land — NOT stamping Phase $phase"
      exit 1
    fi
  else
    note "  [$key] hermes fleet sandbox not present or not Ready — genuine skip (opt-in record)"
  fi
  stamp_mark "$phase"
}

# run_case <phase> <key> <port> <sb-list> <fake-cfg> — reset stamp, drive vts_branch, echo "rc:stamp"
run_case() {
  local phase="$1" key="$2" port="$3"
  rm -f "$(STAMP_FILE "$phase")"
  SB_LIST="$4" FAKE_CONFIG="$5"; export SB_LIST FAKE_CONFIG
  local rc=0; ( vts_branch "$phase" "$key" "$port" ) >/dev/null 2>&1 || rc=$?
  local stamped=no; [[ -f "$(STAMP_FILE "$phase")" ]] && stamped=yes
  echo "${rc}:${stamped}"
}

# The three phases and their post-condition key/port (39→docs:8765, 40→honcho:7082, 41→falkordb:7083).
# docs' helper ignores the port arg (endpoint is fixed 8765); pass it anyway — harmless.
PHASES="39:docs:8765 40:honcho:7082 41:falkordb:7083"

# 0. ANTI-VACUOUS: prove the fixtures actually drive the real helper three different ways,
#    else every later assertion is meaningless (cf. sandbox-present.sh assertion 0).
SB_LIST="$SB_READY" FAKE_CONFIG="$CFG_WIRED";   export SB_LIST FAKE_CONFIG
_mem_hermes_docs_wired "$OSH"        || fail "0: real _mem_hermes_docs_wired must be TRUE for a Ready+wired fleet"
SB_LIST="$SB_READY" FAKE_CONFIG="$CFG_UNWIRED"; export FAKE_CONFIG
if _mem_hermes_docs_wired "$OSH"; then fail "0: real _mem_hermes_docs_wired must be FALSE for a Ready+UNWIRED fleet"; fi
SB_LIST="$SB_EMPTY"  FAKE_CONFIG="$CFG_WIRED";  export SB_LIST FAKE_CONFIG
_mem_hermes_docs_wired "$OSH"        || fail "0: real _mem_hermes_docs_wired must be lenient (TRUE) when no fleet is Ready"
ok "0: fixtures drive the REAL _mem_hermes_docs_wired three ways (wired=T, unwired=F, no-fleet=lenient-T) — assertions are not vacuous"

for spec in $PHASES; do
  phase="${spec%%:*}"; rest="${spec#*:}"; key="${rest%%:*}"; port="${rest##*:}"

  # 1. wiring ATTEMPTED (fleet Ready) + post-condition FAILS → err, exit 1, NO stamp.
  [[ "$(run_case "$phase" "$key" "$port" "$SB_READY" "$CFG_UNWIRED")" == "1:no" ]] \
    || fail "1[$phase/$key]: Ready+unwired must exit 1 and NOT stamp"
  ok "1[$phase/$key]: wiring attempted + post-condition FAILS → exit 1, NO stamp"

  # 2. wiring ATTEMPTED (fleet Ready) + post-condition PASSES → stamp written, exit 0.
  [[ "$(run_case "$phase" "$key" "$port" "$SB_READY" "$CFG_WIRED")" == "0:yes" ]] \
    || fail "2[$phase/$key]: Ready+wired must exit 0 and stamp"
  ok "2[$phase/$key]: wiring attempted + post-condition PASSES → exit 0, stamp written"

  # 3a. THE INVARIANT: a GENUINE no-sandbox fleet MUST STILL STAMP + exit 0 — that stamp is the
  #     OPT-IN RECORD that arms 04f_hermes_fleet.sh (stamp_check 39/40/41) so a fleet built LATER
  #     still gets wired. A "tidy-up" that dropped the else-branch would silently kill this.
  [[ "$(run_case "$phase" "$key" "$port" "$SB_EMPTY" "$CFG_UNWIRED")" == "0:yes" ]] \
    || fail "3a[$phase/$key]: GENUINE no-sandbox must STILL stamp (opt-in record) + exit 0"
  ok "3a[$phase/$key]: genuine no-sandbox → STILL stamps + exit 0 (opt-in-survives-rebuild) — highest-value line"

  # 3b. present-but-NOT-Ready (Creating) → same genuine-skip path: stamp + exit 0.
  [[ "$(run_case "$phase" "$key" "$port" "$SB_CREATING" "$CFG_UNWIRED")" == "0:yes" ]] \
    || fail "3b[$phase/$key]: present-but-not-Ready must take the skip path → stamp + exit 0"
  ok "3b[$phase/$key]: present-but-not-Ready (Creating) → skip path stamps + exit 0"

  # 4. idempotence: a re-run against an already-wired fleet does not fail (stamp stays).
  run_case "$phase" "$key" "$port" "$SB_READY" "$CFG_WIRED" >/dev/null
  [[ "$(run_case "$phase" "$key" "$port" "$SB_READY" "$CFG_WIRED")" == "0:yes" ]] \
    || fail "4[$phase/$key]: re-run against a wired fleet must stay exit 0 + stamped"
  ok "4[$phase/$key]: idempotent — re-run against a wired fleet stays exit 0, stamped"
done

# Always-on NON-VACUITY CONTROL (§24 SHOULDFIX; mirrors sandbox-present.sh's assertion 0):
# re-run THIS suite with the change-2 stamp gate reverted (VTS_MUTATE=1 makes vts_branch
# stamp UNCONDITIONALLY, the pre-incident form) and assert it FAILS. This proves — on every
# run, without an operator remembering to do it by hand — that the assertions above genuinely
# catch the 2026-07-16 regression and cannot pass vacuously. The `[[ -z VTS_MUTATE ]]` guard
# stops infinite recursion: the mutated sub-run does not re-enter this block.
if [[ -z "${VTS_MUTATE:-}" ]]; then
  if VTS_MUTATE=1 "${BASH:-bash}" "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
    fail "CONTROL: with the verify-then-stamp gate reverted (VTS_MUTATE=1) the suite still PASSED — the assertions are vacuous"
  fi
  ok "control: VTS_MUTATE=1 (change-2 gate reverted) makes this suite FAIL — non-vacuity proven"
fi

ok "Smoke verify-then-stamp PASS — verify-then-stamp contract pinned for phases 39/40/41 (attempt-fails→no-stamp; verified→stamp; genuine-skip→STILL-stamp; idempotent)"
