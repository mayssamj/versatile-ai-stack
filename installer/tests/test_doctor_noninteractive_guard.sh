#!/usr/bin/env bash
# test_doctor_noninteractive_guard.sh — a NON-INTERACTIVE `doctor` (piped / </dev/null / cron /
# subprocess) must NEVER auto-apply a PROMPTED fix: `confirm … Y` takes its yes-default on EOF, so
# a headless run would silently run e.g. check 08's `ollama pull nemotron-3-nano:4b` — violating
# the no-local-model policy. AUTOHEAL (safe idempotent) fixes must STILL run headless. NO network.
set -uo pipefail
DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../doctor/doctor.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== structural: the elif chain in doctor.sh is ordered NO_PROMPT -> AUTOHEAL -> non-TTY -> confirm =="
order="$(grep -nE 'NO_PROMPT:-0|AUTOHEAL\[\$__check\]|! \[\[ -t 0 \]\]|confirm "    Auto-fix' "$DOC" | cut -d: -f1 | tr '\n' ' ')"
read -r a b c d _ <<<"$order"
if [[ -z "${a:-}" || -z "${b:-}" || -z "${c:-}" || -z "${d:-}" ]]; then
  bad "one of the 4 branch patterns not found in doctor.sh (grep -> '$order')"
elif (( a<b && b<c && c<d )); then
  ok "ordering NO_PROMPT($a) < AUTOHEAL($b) < non-TTY($c) < confirm($d)"
else
  bad "ordering wrong: '$order'"
fi

echo "== behavioral: the decision matrix (mirrors the doctor.sh block exactly) =="
decide() {  # <NO_PROMPT> <AUTOHEAL> <tty:true|false> -> branch taken
  local NO_PROMPT="$1" AH="$2" tty="$3"
  if [[ "$NO_PROMPT" == "1" ]]; then echo noprompt-skip
  elif [[ "$AH" == "1" ]]; then echo autoheal-apply
  elif ! $tty; then echo noninteractive-skip
  else echo interactive-confirm; fi
}
[[ "$(decide 0 0 false)" == noninteractive-skip ]] && ok "non-interactive + prompted fix -> SKIP (no ollama pull)" || bad "non-interactive NOT skipped (the landmine)"
[[ "$(decide 0 1 false)" == autoheal-apply     ]] && ok "non-interactive + AUTOHEAL -> still applies (headless-safe self-heal preserved)" || bad "AUTOHEAL wrongly blocked"
[[ "$(decide 1 0 false)" == noprompt-skip       ]] && ok "NO_PROMPT=1 -> skip" || bad "NO_PROMPT not honored"
[[ "$(decide 0 0 true)"  == interactive-confirm ]] && ok "interactive TTY -> confirm prompt (unchanged)" || bad "TTY path broken"
[[ "$(decide 1 1 false)" == noprompt-skip       ]] && ok "NO_PROMPT=1 + AUTOHEAL -> NO_PROMPT wins (report-only run stays side-effect-free)" || bad "NO_PROMPT must win over AUTOHEAL"

echo "== integration: drive the REAL fix-dispatch block extracted from doctor.sh (fake check, no copy) =="
# Extract the actual `if declare -F "${__check}_fix" … fi` block from doctor.sh and run it with a
# fake check + stubs, so this tests the SHIPPED code path (not a hand-transcribed mirror).
BLOCK="$(awk '/^    if declare -F "/{f=1} f{print} f&&/^    fi$/{exit}' "$DOC")"
if [[ -z "$BLOCK" ]]; then bad "could not extract the fix-dispatch block from doctor.sh"; else
  SENT="$(mktemp -u)"; declare -A AUTOHEAL; __check=fake; fixed=0
  fake_fix(){ : > "$SENT"; }     # the "fix" — records that it actually RAN
  confirm(){ return 0; }         # would say yes if reached; the non-TTY guard must prevent that
  # Run the extracted block in a SUBSHELL that LOCALLY stubs the doctor helpers (note/ok/err), so
  # they don't clobber this harness's own ok()/bad() reporters (they collide by name).
  drive(){ rm -f "$SENT"; ( note(){ :;}; ok(){ :;}; err(){ :;}; eval "$BLOCK" ); }
  AUTOHEAL=();        NO_PROMPT=0; drive </dev/null; [[ ! -e "$SENT" ]] && ok "REAL block: non-interactive prompted fix -> SKIPPED (landmine closed)" || bad "REAL block: prompted fix RAN headless — LANDMINE OPEN"
  AUTOHEAL=([fake]=1); NO_PROMPT=0; drive </dev/null; [[ -e "$SENT" ]]   && ok "REAL block: AUTOHEAL still runs headless (self-heal preserved)"        || bad "REAL block: AUTOHEAL wrongly skipped"
  AUTOHEAL=();        NO_PROMPT=1; drive </dev/null; [[ ! -e "$SENT" ]] && ok "REAL block: NO_PROMPT=1 -> skipped"                                    || bad "REAL block: NO_PROMPT ran a fix"
  rm -f "$SENT"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
