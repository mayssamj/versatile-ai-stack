#!/usr/bin/env bash
# test_doctor_noninteractive_guard.sh — a NON-INTERACTIVE `doctor` (piped / </dev/null / cron /
# subprocess) must NEVER auto-apply a PROMPTED fix: `confirm … Y` takes its yes-default on EOF, so
# a headless run would silently run e.g. check 08's `ollama pull nemotron-3-nano:4b` — violating
# the no-local-model policy. AUTOHEAL (safe idempotent) fixes must STILL run headless, and an
# UNMARKED (advice-only, print-only-by-assertion) fix body must run in EVERY mode so the guidance
# reaches the operator. Prompted paths require the FIX_CAPABLE marker. NO network.
set -uo pipefail
DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../doctor/doctor.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== structural: the dispatch chain is ordered advice-guard -> NO_PROMPT -> AUTOHEAL -> non-TTY -> confirm =="
# Look each branch up INDIVIDUALLY: a single combined `grep -n` stream always comes back in file
# order, so asserting "the collected line numbers increase" is a tautology (it can never fail) —
# and its labels silently drifted when the FIX_CAPABLE guard line (which also mentions
# AUTOHEAL[$__check]) was inserted above NO_PROMPT.
lineof(){ grep -nE "$1" "$DOC" | head -1 | cut -d: -f1; }
lg="$(lineof 'if \[\[ "\$\{FIX_CAPABLE\[\$__check\]')"      # advice-only guard (unmarked check)
ln_="$(lineof 'elif \[\[ "\$\{NO_PROMPT:-0\}')"             # NO_PROMPT skip
la="$(lineof 'elif \[\[ "\$\{AUTOHEAL\[\$__check\]')"       # AUTOHEAL dispatch (not the guard)
lt="$(lineof 'elif ! \[\[ -t 0 \]\]')"                      # non-interactive skip
lc="$(lineof 'elif confirm "    Auto-fix')"                 # interactive confirm
if [[ -z "$lg" || -z "$ln_" || -z "$la" || -z "$lt" || -z "$lc" ]]; then
  bad "one of the 5 branch patterns not found in doctor.sh (got: guard=$lg noprompt=$ln_ autoheal=$la tty=$lt confirm=$lc)"
elif (( lg<ln_ && ln_<la && la<lt && lt<lc )); then
  ok "ordering advice-guard($lg) < NO_PROMPT($ln_) < AUTOHEAL($la) < non-TTY($lt) < confirm($lc)"
else
  bad "ordering wrong: guard=$lg noprompt=$ln_ autoheal=$la tty=$lt confirm=$lc"
fi

echo "== behavioral: the decision matrix (mirrors the doctor.sh block exactly) =="
decide() {  # <FIX_CAPABLE> <AUTOHEAL> <NO_PROMPT> <tty:true|false> -> branch taken
  local FC="$1" AH="$2" NO_PROMPT="$3" tty="$4"
  if [[ "$FC" != "1" && "$AH" != "1" ]]; then echo advice-run   # unmarked: body runs (print-only by author assertion)
  elif [[ "$NO_PROMPT" == "1" ]]; then echo noprompt-skip
  elif [[ "$AH" == "1" ]]; then echo autoheal-apply
  elif ! $tty; then echo noninteractive-skip
  else echo interactive-confirm; fi
}
[[ "$(decide 1 0 0 false)" == noninteractive-skip ]] && ok "non-interactive + prompted (FIX_CAPABLE) fix -> SKIP (no ollama pull)" || bad "non-interactive NOT skipped (the landmine)"
[[ "$(decide 0 1 0 false)" == autoheal-apply      ]] && ok "non-interactive + AUTOHEAL -> still applies (headless-safe self-heal preserved)" || bad "AUTOHEAL wrongly blocked"
[[ "$(decide 1 0 1 false)" == noprompt-skip       ]] && ok "NO_PROMPT=1 -> skip" || bad "NO_PROMPT not honored"
[[ "$(decide 1 0 0 true)"  == interactive-confirm ]] && ok "interactive TTY -> confirm prompt (unchanged)" || bad "TTY path broken"
[[ "$(decide 0 1 1 false)" == noprompt-skip       ]] && ok "NO_PROMPT=1 + AUTOHEAL -> NO_PROMPT wins (report-only run stays side-effect-free)" || bad "NO_PROMPT must win over AUTOHEAL"
[[ "$(decide 0 0 0 false)" == advice-run          ]] && ok "unmarked check -> advice body runs headless (guidance reaches the operator)" || bad "advice-only body blocked"
[[ "$(decide 0 0 1 false)" == advice-run          ]] && ok "unmarked check + NO_PROMPT=1 -> advice body STILL runs (print-only by contract)" || bad "advice-only body blocked under NO_PROMPT"

echo "== integration: drive the REAL fix-dispatch block extracted from doctor.sh (fake check, no copy) =="
# Extract the actual `if declare -F "${__check}_fix" … fi` block from doctor.sh and run it with a
# fake check + stubs, so this tests the SHIPPED code path (not a hand-transcribed mirror).
# The stub environment below is PART OF THE TESTED INTERFACE: every array/var the shipped block
# references must be declared here, or (set -u + an undeclared assoc array) crashes the subshell
# and the skip-expecting cases pass VACUOUSLY. That exact drift happened when FIX_CAPABLE was
# added to doctor.sh — hence the empty-stderr assertion on every drive.
BLOCK="$(awk '/^    if declare -F "/{f=1} f{print} f&&/^    fi$/{exit}' "$DOC")"
# The fix-dispatch block delegates to the _doctor_apply_and_verify helper (2026-07-05:
# run the fix, then re-diagnose). Extract that helper too so the block is self-contained.
eval "$(awk '/^_doctor_apply_and_verify\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DOC")"
if [[ -z "$BLOCK" ]]; then bad "could not extract the fix-dispatch block from doctor.sh"; else
  SENT="$(mktemp -u)"; DERR="$(mktemp)"; declare -A AUTOHEAL FIX_CAPABLE; __check=fake; fixed=0
  fake_fix(){ : > "$SENT"; }       # the "fix" — records that it actually RAN
  fake_diagnose(){ return 0; }     # the re-diagnose verification (helper re-runs it)
  confirm(){ return 0; }           # would say yes if reached; the non-TTY guard must prevent that
  # Run the extracted block in a SUBSHELL that LOCALLY stubs the doctor helpers (note/ok/err), so
  # they don't clobber this harness's own ok()/bad() reporters (they collide by name). Capture the
  # subshell's stderr: a healthy drive writes NOTHING there, so any content means the block
  # crashed (e.g. `unbound variable`) and the SENT-based assertion would be vacuous.
  drive(){ rm -f "$SENT"; ( note(){ :;}; ok(){ :;}; err(){ :;}; eval "$BLOCK" ) 2>"$DERR" >/dev/null; }
  quiet(){ [[ ! -s "$DERR" ]] || { echo "      drive stderr (block crashed?):"; sed 's/^/      /' "$DERR"; return 1; }; }
  FIX_CAPABLE=([fake]=1); AUTOHEAL=();         NO_PROMPT=0; drive </dev/null
  quiet && [[ ! -e "$SENT" ]] && ok "REAL block: non-interactive prompted fix -> SKIPPED (landmine closed)" || bad "REAL block: prompted fix RAN headless (or drive crashed) — LANDMINE OPEN"
  FIX_CAPABLE=();         AUTOHEAL=([fake]=1); NO_PROMPT=0; drive </dev/null
  quiet && [[ -e "$SENT" ]]   && ok "REAL block: AUTOHEAL still runs headless (self-heal preserved)"        || bad "REAL block: AUTOHEAL wrongly skipped"
  FIX_CAPABLE=([fake]=1); AUTOHEAL=();         NO_PROMPT=1; drive </dev/null
  quiet && [[ ! -e "$SENT" ]] && ok "REAL block: NO_PROMPT=1 -> skipped"                                    || bad "REAL block: NO_PROMPT ran a fix"
  FIX_CAPABLE=();         AUTOHEAL=();         NO_PROMPT=0; drive </dev/null
  quiet && [[ -e "$SENT" ]]   && ok "REAL block: unmarked (advice-only) body runs headless (guidance always shown)" || bad "REAL block: advice-only body did not run"
  rm -f "$SENT" "$DERR"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
