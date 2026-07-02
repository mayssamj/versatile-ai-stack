#!/usr/bin/env bash
# test_foreground_server_signal_exit.sh — offline unit test for run_foreground_server()
# in vz-ai-stack.sh. Foreground commands (tutorial-serve / models-serve / fleet-studio /
# understand-dashboard / `logs -f`) exit non-zero when stopped by a signal; the top-level
# `set -Eeuo pipefail` + ERR trap would then print a spurious `✗ ERR line N (exit=143)`
# after a CLEAN shutdown. The helper maps ONLY the two graceful-stop signals — SIGINT/130
# (Ctrl-C) and SIGTERM/143 — to 0, while any other non-zero (SIGKILL/137, real errors)
# still propagates. No network, no model, no live server. Run: bash this.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VZ="$HERE/../../vz-ai-stack.sh"
[[ -f "$VZ" ]] || { echo "  [skip] vz-ai-stack.sh not found at $VZ"; exit 0; }

# Extract the REAL function definition from vz-ai-stack.sh (not a copy — no drift) and
# eval it here. Sourcing the whole file would run `main "$@"`, so we pull just the func.
FUNC_SRC="$(sed -n '/^run_foreground_server() {/,/^}/p' "$VZ")"
[[ -n "$FUNC_SRC" ]] || { echo "  FAIL: could not extract run_foreground_server from $VZ"; exit 1; }
eval "$FUNC_SRC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$TMP/$1"; chmod +x "$TMP/$1"; }
mk sigint.sh  'kill -INT $$; sleep 5'    # Ctrl-C  -> 130 -> mapped to 0
mk sigterm.sh 'kill -TERM $$; sleep 5'   # SIGTERM -> 143 -> mapped to 0
mk sigkill.sh 'kill -KILL $$; sleep 5'   # SIGKILL -> 137 -> MUST propagate
mk exit1.sh   'exit 1'                   # bind/real error -> MUST propagate
mk exit0.sh   'exit 0'                   # clean -> 0

PASS=0; FAIL=0
check() { # <label> <script> <want-rc>
  local got; run_foreground_server bash "$TMP/$2"; got=$?
  if [[ "$got" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok   $1: rc=$got"
  else FAIL=$((FAIL+1)); echo "  FAIL $1: rc=$got want $3"; fi
}
check "SIGINT(130) clean stop"  sigint.sh  0
check "SIGTERM(143) clean stop" sigterm.sh 0
check "SIGKILL(137) propagates" sigkill.sh 137
check "exit 1 propagates"       exit1.sh   1
check "exit 0 passthrough"      exit0.sh   0

# End-to-end guard: under the SAME `set -Eeuo pipefail` + ERR trap as vz-ai-stack.sh,
# a signal-stopped child must NOT print the spurious '✗ ERR' line and the outer rc = 0.
e2e="$(
  set +e
  ( set -Eeuo pipefail
    trap 'echo "SPURIOUS-ERR"' ERR
    eval "$FUNC_SRC"
    run_foreground_server bash "$TMP/sigterm.sh"
  ) 2>&1
  echo "OUTER=$?"
)"
if ! grep -q SPURIOUS-ERR <<<"$e2e" && grep -q 'OUTER=0' <<<"$e2e"; then
  PASS=$((PASS+1)); echo "  ok   no spurious ERR trap on signal-stop (outer rc=0)"
else
  FAIL=$((FAIL+1)); echo "  FAIL spurious ERR / non-zero outer on signal-stop:"; echo "$e2e" | sed 's/^/      /'
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
