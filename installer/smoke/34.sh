#!/usr/bin/env bash
# smoke/34.sh — Phase 34 (OASIS) E2E gate. Runs the seeded CAMEL multi-agent sim
# (oasis/sims/smoke_sim.py) via bin/oasis and PASSES only when every agent replied
# through LiteLLM on the scoped key.
#
# The sim self-bounds with signal.alarm (macOS has no `timeout`) and uses distinct
# exit codes: 0=all replied, 3=an agent failed (placeholder/401 key, or empty model
# output), 4=camel import drift, 5=CAMEL ModelFactory API drift. agents-replied is the
# routing proof (a placeholder/401 key yields no replies), which is a stronger, direct
# signal than a spend delta (the default local-gemma4 bills $0).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 34 — OASIS (CAMEL multi-agent swarm -> LiteLLM)"

VENV="$AI_STACK/oasis/.venv"
[[ -x "$VENV/bin/python" ]] || { err "oasis venv missing — run: vz-ai-stack.sh install 34"; exit 1; }
"$VENV/bin/python" -c "import oasis" >/dev/null 2>&1 && ok "import oasis OK" \
  || { err "import oasis failed in the venv"; exit 1; }
[[ -x "$AI_STACK/bin/oasis" ]] || { err "bin/oasis wrapper missing — run: vz-ai-stack.sh install 34"; exit 1; }
SIM="$AI_STACK/oasis/sims/smoke_sim.py"
[[ -f "$SIM" ]] || { err "seeded sim missing ($SIM) — re-run: vz-ai-stack.sh install 34"; exit 1; }

KEY="$(get_env OASIS_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "OASIS_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(litellm_scoped_curl "$KEY" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "OASIS_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

log "Running the seeded CAMEL multi-agent sim via bin/oasis (real swarm step; bounded by the sim's 180s alarm)…"
out="$("$AI_STACK/bin/oasis" "$SIM" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'

case "$rc" in
  0) : ;;  # every agent replied — fall through to the sentinel assertion
  4) err "CAMEL import drift (sim exit 4) — camel-oasis API changed; re-verify oasis/sims/smoke_sim.py against the installed version"; exit 1 ;;
  5) err "CAMEL ModelFactory API drift (sim exit 5) — the OpenAI-compatible enum/signature changed; fix oasis/sims/smoke_sim.py"; exit 1 ;;
  *) err "the CAMEL sim did not pass (exit $rc) — an agent failed to reply through LiteLLM (placeholder/401 key, or empty model output?)"; exit 1 ;;
esac

# Belt-and-suspenders: parse the success sentinel and confirm replies == agents.
_line="$(printf '%s' "$out" | grep -oE 'OASIS_SMOKE_OK agents=[0-9]+ replies=[0-9]+' | tail -1)"
_ag="${_line##*agents=}"; _ag="${_ag%% *}"
_rp="${_line##*replies=}"
[[ -n "$_ag" && "$_rp" == "$_ag" ]] \
  || { err "sim exited 0 but the sentinel parse is inconsistent (agents=${_ag:-?} replies=${_rp:-?})"; exit 1; }
ok "all $_ag CAMEL agents replied through LiteLLM (real swarm step) — traced in Phoenix (http://phoenix:6006)"

ok "Smoke 34 PASS — OASIS CAMEL swarm runs through LiteLLM on the scoped key"
