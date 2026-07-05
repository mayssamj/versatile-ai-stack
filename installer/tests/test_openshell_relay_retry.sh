#!/usr/bin/env bash
# test_openshell_relay_retry.sh — _openshell_exec_retry absorbs a TRANSIENT OpenShell relay
# timeout (bounded, 3 attempts) but fails IMMEDIATELY on a real in-sandbox error (no relay
# signature → not retried). Pure-offline: extracts the fn from upgrade.sh; stubs openshell/warn/sleep.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# 1. Transient relay timeout on attempts 1-2, success on 3 → returns success output, rc 0, 3 calls.
r1="$(
  svc=hermes_fleet; warn(){ :; }; sleep(){ :; }
  CC="${TMPDIR:-/tmp}/oscall1_$$"; : > "$CC"
  openshell(){ echo x >> "$CC"; local n; n=$(wc -l < "$CC");
    if (( n < 3 )); then echo 'status: DeadlineExceeded, message: "relay open timed out"'; return 1; fi
    echo 'Successfully installed hermes-agent-0.18.0'; return 0; }
  source <(sed -n '/^_openshell_exec_retry()/,/^}/p' "$UPG")
  out="$(_openshell_exec_retry sbx bash -c 'pip install')"; rc=$?
  printf 'rc=%s calls=%s out=%s' "$rc" "$(wc -l < "$CC" | tr -d ' ')" "$out"; rm -f "$CC"
)"
[[ "$r1" == *'rc=0'* && "$r1" == *'calls=3'* && "$r1" == *'Successfully installed'* ]] \
  && ok "transient relay: retried to success (rc=0, 3 attempts)" \
  || bad "transient relay not retried to success (got: $r1)"

# 2. REAL pip error (403, no relay signature) → NO retry, fails on attempt 1.
r2="$(
  svc=hermes_fleet; warn(){ :; }; sleep(){ :; }
  CC="${TMPDIR:-/tmp}/oscall2_$$"; : > "$CC"
  openshell(){ echo x >> "$CC"; echo 'ERROR: 403 Client Error: Forbidden for url: https://pypi.org/simple/hermes-agent/'; return 1; }
  source <(sed -n '/^_openshell_exec_retry()/,/^}/p' "$UPG")
  out="$(_openshell_exec_retry sbx bash -c 'pip install')"; rc=$?
  printf 'rc=%s calls=%s' "$rc" "$(wc -l < "$CC" | tr -d ' ')"; rm -f "$CC"
)"
[[ "$r2" == *'rc=1'* && "$r2" == *'calls=1'* ]] \
  && ok "real pip 403: NO retry, fails immediately (rc=1, 1 attempt)" \
  || bad "real error was retried or wrong rc (got: $r2)"

# 3. PERSISTENT relay timeout (all 3) → bounded: gives up after exactly 3 attempts, rc non-zero.
r3="$(
  svc=hermes_fleet; warn(){ :; }; sleep(){ :; }
  CC="${TMPDIR:-/tmp}/oscall3_$$"; : > "$CC"
  openshell(){ echo x >> "$CC"; echo 'status: DeadlineExceeded, message: "relay open timed out"'; return 1; }
  source <(sed -n '/^_openshell_exec_retry()/,/^}/p' "$UPG")
  out="$(_openshell_exec_retry sbx bash -c 'pip install')"; rc=$?
  printf 'rc=%s calls=%s' "$rc" "$(wc -l < "$CC" | tr -d ' ')"; rm -f "$CC"
)"
[[ "$r3" == *'rc=1'* && "$r3" == *'calls=3'* ]] \
  && ok "persistent relay: bounded at 3 attempts, then fails honestly (rc=1)" \
  || bad "persistent relay not bounded at 3 (got: $r3)"

# 4. Success on the FIRST try → no retry, no wasted attempts.
r4="$(
  svc=hermes_fleet; warn(){ :; }; sleep(){ :; }
  CC="${TMPDIR:-/tmp}/oscall4_$$"; : > "$CC"
  openshell(){ echo x >> "$CC"; echo 'Requirement already satisfied: hermes-agent'; return 0; }
  source <(sed -n '/^_openshell_exec_retry()/,/^}/p' "$UPG")
  out="$(_openshell_exec_retry sbx bash -c 'pip install')"; rc=$?
  printf 'rc=%s calls=%s' "$rc" "$(wc -l < "$CC" | tr -d ' ')"; rm -f "$CC"
)"
[[ "$r4" == *'rc=0'* && "$r4" == *'calls=1'* ]] \
  && ok "first-try success: no retry (rc=0, 1 attempt)" \
  || bad "first-try success did extra attempts (got: $r4)"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
