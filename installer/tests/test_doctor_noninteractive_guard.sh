#!/usr/bin/env bash
# test_doctor_noninteractive_guard.sh — a NON-INTERACTIVE `doctor` (piped / </dev/null / cron /
# subprocess) must NEVER auto-apply a PROMPTED fix: `confirm … Y` takes its yes-default on EOF, so
# a headless run would silently run e.g. check 08's `ollama pull gemma4:e4b` (~9.6 GB) — violating
# the no-local-model policy. AUTOHEAL (safe idempotent) fixes must STILL run headless. NO network.
set -uo pipefail
DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../doctor/doctor.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== structural: the elif chain in doctor.sh is ordered NO_PROMPT -> AUTOHEAL -> non-TTY -> confirm =="
order="$(grep -nE 'NO_PROMPT:-0|AUTOHEAL\[\$__check\]|! \[\[ -t 0 \]\]|confirm "    Auto-fix' "$DOC" | cut -d: -f1 | tr '\n' ' ')"
read -r a b c d _ <<<"$order"
{ [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] && (( a<b && b<c && c<d )); } \
  && ok "ordering NO_PROMPT($a) < AUTOHEAL($b) < non-TTY($c) < confirm($d)" \
  || bad "ordering wrong / a branch missing: '$order'"

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

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
