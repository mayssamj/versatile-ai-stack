#!/usr/bin/env bash
# smoke/install-log.sh — regression test for change 3 (2026-07-16 incident follow-up):
# the INSTALL-RUN LOGGING in vz-ai-stack.sh (install_log_start / install_log_drain /
# install_on_exit + the optfail-persistence block). OFFLINE/hermetic: no real installer,
# no stack, no network, no models, throwaway STATE_DIR — never the real installer/state/.
#
# WHY this exists: the trigger of that incident (a `note` naming the mis-wired branch)
# printed to a terminal and was LOST, so the root cause could never be more than a
# hypothesis. Change 3 tees the full run to installer/state/install-<UTC>.log while the
# operator still sees everything live. Its author found TWO non-obvious facts by testing;
# both are one careless refactor away from returning, so both are PINNED here:
#   A. a naive process-substitution tee with NO drain loses the ENTIRE log (bash does not
#      wait for a procsub — teardown kills tee mid-flush). install_log_drain restores fds
#      8/9 (tee's EOF) + waits.  -> assertion 2.
#   B. a BARE `wait TEE_PID` HANGS FOREVER when a phase left a daemon holding the inherited
#      pipe. Hence the watchdog-bounded wait.  -> assertion 6.
#
# The functions under test are EXTRACTED from vz-ai-stack.sh at run time (sed by function
# block) rather than hand-copied, so this test tracks the SHIPPED code. Point VZ_SRC at a
# mutated copy to prove an assertion fails when the fix is broken (see MUTATION notes).
#
# STDIN/TTY (assertion 5) is tested through a real pty via the `script -q /dev/null` trick —
# without a pty you cannot honestly assert `-t 0` survives the redirect.
#
# Reachable from the CLI:  vz-ai-stack.sh test install-log   (falls through to this file).
#   bash installer/smoke/install-log.sh
set -Eeuo pipefail
export AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
VZ_SRC="${VZ_SRC:-$AI_STACK/vz-ai-stack.sh}"

hdr "Smoke install-log — install-run logging (tee/drain/on_exit + optfail persist) (hermetic)"
fail() { err "Smoke install-log FAIL — $*"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-log-smoke-XXXXXX")"
DAEMON_PIDFILE="$TMP/daemon.pid"
cleanup() {
  # Kill the assertion-6 pipe-holding daemon if it outlived the fake installer.
  [[ -f "$DAEMON_PIDFILE" ]] && kill "$(cat "$DAEMON_PIDFILE" 2>/dev/null)" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------
# Extract the three shipped functions (by top-level function block) into $TMP/logfns.sh.
# Closing braces are at column 0, so `/^name() {$/,/^}$/` is an exact block match.
# ---------------------------------------------------------------------------------------
LOGFNS="$TMP/logfns.sh"
{
  sed -n '/^install_log_start() {$/,/^}$/p' "$VZ_SRC"
  sed -n '/^install_log_drain() {$/,/^}$/p' "$VZ_SRC"
  sed -n '/^install_on_exit() {$/,/^}$/p'   "$VZ_SRC"
} > "$LOGFNS"

# Extract the optfail-persistence block (inline in cmd_install) into a callable function so
# assertion 8 also tracks shipped code. `local` is legal only in a function, so we wrap it.
OPTBLOCK="$TMP/optblock.sh"
{
  printf '%s\n' '_optblock() {'
  sed -n '/local optstate="\$STATE_DIR\/install-optionals-last.txt"/,/} > "\$optstate"/p' "$VZ_SRC"
  printf '%s\n' '}'
} > "$OPTBLOCK"

# 0. Anti-vacuity: the extraction actually captured the real mechanism. If a refactor renamed
#    a function or moved a brace, sed would yield an empty/partial block and EVERY later
#    assertion would pass by doing nothing — pin the mechanism so that can't happen silently.
grep -q 'exec 8>&1 9>&2'          "$LOGFNS" || fail "0: extracted install_log_start missing the fd-save (exec 8>&1 9>&2) — extraction is vacuous"
grep -q 'tee -a "\$INSTALL_LOG"'  "$LOGFNS" || fail "0: extracted install_log_start missing the 'tee -a \$INSTALL_LOG' redirect — extraction is vacuous"
grep -q 'exec 1>&8 2>&9 8>&- 9>&-' "$LOGFNS" || fail "0: extracted install_log_drain missing the fd-restore (tee's EOF) — extraction is vacuous"
grep -q 'kill -TERM "\$pid"'      "$LOGFNS" || fail "0: extracted install_log_drain missing the watchdog kill — extraction is vacuous"
grep -q 'return "\$_rc"'          "$LOGFNS" || fail "0: extracted install_on_exit missing the rc-preserving return — extraction is vacuous"
grep -q 'printf .failed:'         "$OPTBLOCK" || fail "0: extracted optfail block missing the 'failed:' line — extraction is vacuous"
ok "0: extracted the shipped tee/drain/on_exit + optfail mechanism from $(basename "$VZ_SRC") (non-vacuous)"

# ---------------------------------------------------------------------------------------
# Fake installer: sources common.sh + the extracted functions, runs install_log_start with
# a throwaway STATE_DIR, prints to BOTH stdout and stderr, then exits. Modes:
#   basic  — trap set by install_log_start (drain). exits $BODY_RC.
#   onexit — supersede with install_on_exit (the real post-lock trap). exits $BODY_RC.
#   daemon — leave a background child holding the inherited pipe, then exit 0 (assertion B).
# It writes NOTHING outside its per-case STATE_DIR (passed in via env).
# ---------------------------------------------------------------------------------------
FAKE="$TMP/fake-install.sh"
cat > "$FAKE" <<FAKEEOF
#!/usr/bin/env bash
set -Eeuo pipefail
_SD="\${STATE_DIR:?}"            # capture per-case throwaway dir BEFORE common.sh clobbers it
export AI_STACK="$AI_STACK"
source "$AI_STACK/installer/lib/common.sh"
source "$LOGFNS"
STATE_DIR="\$_SD"                # common.sh set STATE_DIR to the real tree; put ours back
mkdir -p "\$STATE_DIR"
lock_release() { :; }            # stub: install_on_exit calls it; no real lock here
MODE="\${MODE:-basic}"
BODY_RC="\${BODY_RC:-0}"

install_log_start "fakephase arg2"

# After the redirect is live, stdin must still be a TTY (phase-00 prompts / confirm()).
if [[ -t 0 ]]; then echo "TTY0=YES"; else echo "TTY0=NO"; fi

echo "OUT-stdout-line-alpha"
echo "ERR-stderr-line-beta" >&2

if [[ "\$MODE" == onexit ]]; then
  trap 'install_on_exit' EXIT   # exactly what cmd_install does after lock_acquire
fi

if [[ "\$MODE" == daemon ]]; then
  # A phase leaves a daemon that INHERITED fd1 (the pipe to tee). A bare 'wait TEE_PID'
  # would hang forever; the watchdog-bounded drain must still return.
  sleep 30 & echo \$! > "$DAEMON_PIDFILE"
fi

echo "TAIL-MARKER-last-line-before-exit"   # assertion 2: this must survive into the log
exit "\$BODY_RC"
FAKEEOF
chmod +x "$FAKE"

# resolve_log <state_dir> — the log file the fake installer just wrote, via the symlink.
resolve_log() {
  local sd="$1" base
  base="$(readlink "$sd/install-latest.log" 2>/dev/null || true)"
  [[ -n "$base" ]] && printf '%s\n' "$sd/$base"
}

# ---------------------------------------------------------------------------------------
# Case A — basic run, NON-pty, capture the real exit status and the log content.
# ---------------------------------------------------------------------------------------
SD1="$TMP/state1"
set +e
MODE=basic BODY_RC=0 STATE_DIR="$SD1" /opt/homebrew/bin/bash "$FAKE" >"$TMP/term1.out" 2>&1
rcA=$?
set -e
LOG1="$(resolve_log "$SD1")"

# 1. The log is CREATED, NON-EMPTY, and carries BOTH a stdout and a stderr line.
[[ -n "$LOG1" && -s "$LOG1" ]] || fail "1: install log was not created or is empty (STATE_DIR=$SD1)"
grep -q 'OUT-stdout-line-alpha' "$LOG1" || fail "1: log is missing the stdout line"
grep -q 'ERR-stderr-line-beta'  "$LOG1" || fail "1: log is missing the stderr line (2>&1 into tee not wired)"
ok "1: log created + non-empty + carries both stdout and stderr ($(basename "$LOG1"))"

# 2. THE TAIL IS NOT LOST (assertion A). The drain's job is not just "tee eventually flushes"
#    — a clean process exit closes the pipe and real tee flushes on its own. The load-bearing
#    guarantee is that INSTALL DOES NOT RETURN until tee has finished writing (restore fds 8/9
#    => tee's EOF, THEN `wait`). Pin it deterministically with a SLOW-flush `tee` shim that
#    holds its write behind a 1s sleep: with the drain's wait, install blocks until the tail
#    is on disk; without it, install returns while the shim is still asleep and the tail is
#    absent at that instant — exactly the "log came back empty" teardown race.
#    MUTATION: neuter install_log_drain (early return, no wait) -> this goes RED.
SLOWBIN="$TMP/slowbin"; mkdir -p "$SLOWBIN"
cat > "$SLOWBIN/tee" <<'TEEEOF'
#!/opt/homebrew/bin/bash
# slow-flush tee shim: append-mode file is the arg after -a. Slurp ALL stdin, sleep, THEN
# write file + passthrough — so nothing is on disk until 1s after the writer closed the pipe.
f=""; while (( $# )); do case "$1" in -a) f="$2"; shift 2;; *) f="$1"; shift;; esac; done
data="$(cat)"; sleep 1; printf '%s' "$data" >> "$f"; printf '%s' "$data"
TEEEOF
chmod +x "$SLOWBIN/tee"
SDT="$TMP/state-tail"
set +e
PATH="$SLOWBIN:$PATH" MODE=basic BODY_RC=0 STATE_DIR="$SDT" /opt/homebrew/bin/bash "$FAKE" >/dev/null 2>&1
set -e
# Checked the INSTANT install returned — with the fix, the wait already flushed the shim.
LOGT="$(resolve_log "$SDT")"
grep -q 'TAIL-MARKER-last-line-before-exit' "$LOGT" \
  || fail "2: the tail is NOT on disk the instant install returned — the drain did not wait for tee (assertion A regression)"
ok "2: install does not return until tee has flushed the tail (drain waits — assertion A)"

# 4. EXIT STATUS is install's, never tee's (assertion: procsub redirect leaves \$? alone; a
#    pipe form would hand back tee's 0).  MUTATION: make the drain exit 0 -> this goes RED.
SD2="$TMP/state2"
set +e
MODE=basic BODY_RC=7 STATE_DIR="$SD2" /opt/homebrew/bin/bash "$FAKE" >/dev/null 2>&1
rc7=$?
set -e
[[ "$rc7" == "7" ]] || fail "4: install body exited 7 but the process returned $rc7 — exit status was masked by tee/drain"
ok "4: exit status is the body's (7), not tee's (0) — under the drain EXIT trap"

# 4b. Same guarantee through the REAL post-lock trap (install_on_exit preserves \$rc).
SD2b="$TMP/state2b"
set +e
MODE=onexit BODY_RC=7 STATE_DIR="$SD2b" /opt/homebrew/bin/bash "$FAKE" >/dev/null 2>&1
rc7b=$?
set -e
[[ "$rc7b" == "7" ]] || fail "4b: install_on_exit did not preserve the exit status (got $rc7b, expected 7)"
ok "4b: install_on_exit preserves the body's exit status (7) too"

# ---------------------------------------------------------------------------------------
# Case B — pty run (script -q /dev/null): the operator's real-time terminal view + TTY.
# ---------------------------------------------------------------------------------------
SD3="$TMP/state3"
set +e
MODE=basic BODY_RC=0 STATE_DIR="$SD3" \
  script -q /dev/null /opt/homebrew/bin/bash "$FAKE" >"$TMP/term3.raw" 2>&1
set -e
# Strip CR + the ^D/EOT script emits, so substring checks are honest.
tr -d '\r\004' < "$TMP/term3.raw" > "$TMP/term3.out"
LOG3="$(resolve_log "$SD3")"

# 3. The operator STILL SEES everything live: tee passes stdout+stderr through to the
#    terminal (captured by the pty typescript), not only to the file.
grep -q 'OUT-stdout-line-alpha'            "$TMP/term3.out" || fail "3: stdout line never reached the terminal (tee passthrough broken)"
grep -q 'ERR-stderr-line-beta'             "$TMP/term3.out" || fail "3: stderr line never reached the terminal"
grep -q 'TAIL-MARKER-last-line-before-exit' "$TMP/term3.out" || fail "3: the tail never reached the terminal"
ok "3: operator sees stdout+stderr live on the terminal (tee passthrough intact)"

# 5. STDIN/TTY preserved: install is INTERACTIVE. After 'exec > >(tee) 2>&1' redirects fd1/fd2,
#    fd0 must remain a TTY so phase-00 key bootstrap + confirm() still read the operator.
grep -q 'TTY0=YES' "$TMP/term3.out" || fail "5: stdin stopped being a TTY after the redirect — interactive prompts would break"
grep -q 'TTY0=NO'  "$TMP/term3.out" && fail "5: fd0 reported NON-TTY after the redirect"
ok "5: stdin stays a TTY through the redirect (interactive prompts survive; '-t 0' true)"

# 7. Log perms are 0600 (transcript could carry a future echoed secret — defense in depth).
mode="$(stat -f '%Lp' "$LOG3" 2>/dev/null || true)"
[[ "$mode" == "600" ]] || fail "7: install log perms are $mode, expected 600"
ok "7: install log is created 0600"

# ---------------------------------------------------------------------------------------
# 6. THE DAEMON-HOLDS-THE-PIPE CASE (assertion B): a bare 'wait TEE_PID' would hang forever.
#    The watchdog-bounded drain must return. Bound the WHOLE case with a hard kill so a
#    regression FAILS instead of hanging this suite.  MUTATION: make the wait unbounded ->
#    this goes RED (killed by the watchdog below, elapsed ~= HARD_KILL).
# ---------------------------------------------------------------------------------------
SD4="$TMP/state4"
HARD_KILL=15                     # drain's own watchdog is 5s; give generous headroom
MODE=daemon BODY_RC=0 STATE_DIR="$SD4" /opt/homebrew/bin/bash "$FAKE" >/dev/null 2>&1 &
child=$!
( sleep "$HARD_KILL"; kill -9 "$child" 2>/dev/null ) & wd=$!
start=$SECONDS
set +e
wait "$child"; rc6=$?
set -e
elapsed=$(( SECONDS - start ))
kill "$wd" 2>/dev/null || true; wait "$wd" 2>/dev/null || true
[[ -f "$DAEMON_PIDFILE" ]] && kill "$(cat "$DAEMON_PIDFILE" 2>/dev/null)" 2>/dev/null || true
# rc 137 (SIGKILL) or elapsed at the hard limit == the drain hung and the watchdog fired.
if [[ "$rc6" == "137" ]] || (( elapsed >= HARD_KILL - 2 )); then
  fail "6: the drain HUNG with a daemon holding the pipe (rc=$rc6, elapsed=${elapsed}s) — the wait is not watchdog-bounded (assertion B regression)"
fi
[[ "$rc6" == "0" ]] || fail "6: daemon case returned $rc6 (expected 0 — install body succeeded)"
ok "6: no hang when a daemon holds the pipe — bounded drain returned in ${elapsed}s (< ${HARD_KILL}s)"

# ---------------------------------------------------------------------------------------
# 8. optfail persistence: attempted/failed are recorded, and it is safe under 'set -u' with
#    EMPTY arrays (all-optionals-passed is the common case). Runs the SHIPPED block.
# ---------------------------------------------------------------------------------------
SD5="$TMP/state5"; mkdir -p "$SD5"
set +e
/opt/homebrew/bin/bash -u -c '
  set -Eeuo pipefail
  source "'"$AI_STACK"'/installer/lib/common.sh"
  source "'"$OPTBLOCK"'"
  STATE_DIR="'"$SD5"'"
  INSTALL_LOG="'"$SD5"'/install-x.log"
  # empty arrays — the ${arr[*]:-} guards must keep set -u happy
  local_test() { local -a optphases=() optfail=(); _optblock; }
  local_test
' > "$TMP/opt-empty.out" 2>&1
rc8a=$?
set -e
[[ "$rc8a" == "0" ]] || fail "8: optfail block crashed under 'set -u' with empty arrays: $(cat "$TMP/opt-empty.out")"
OPTF="$SD5/install-optionals-last.txt"
[[ -s "$OPTF" ]] || fail "8: optfail state file not written for the empty-array case"
grep -q '^attempted: *$' "$OPTF" || fail "8: empty 'attempted:' line malformed: $(grep attempted "$OPTF")"
grep -q '^failed: *$'    "$OPTF" || fail "8: empty 'failed:' line malformed"
ok "8a: optfail block is set -u-safe with empty arrays (attempted/failed lines present, blank)"

# Populated arrays — attempted + failed must be recorded verbatim.
SD6="$TMP/state6"; mkdir -p "$SD6"
/opt/homebrew/bin/bash -u -c '
  set -Eeuo pipefail
  source "'"$AI_STACK"'/installer/lib/common.sh"
  source "'"$OPTBLOCK"'"
  STATE_DIR="'"$SD6"'"
  INSTALL_LOG="'"$SD6"'/install-y.log"
  local_test() { local -a optphases=(25 27 32) optfail=(27 32); _optblock; }
  local_test
' >/dev/null 2>&1
OPTF2="$SD6/install-optionals-last.txt"
grep -q '^attempted: 25 27 32$' "$OPTF2" || fail "8: attempted phases not recorded verbatim: $(grep attempted "$OPTF2")"
grep -q '^failed:    27 32$'     "$OPTF2" || fail "8: failed phases not recorded verbatim: $(grep failed "$OPTF2")"
ok "8b: optfail block records attempted + failed phases verbatim"

ok "Smoke install-log PASS — log created/perms/tail/exit-status/TTY/no-hang + optfail persistence all pinned"
