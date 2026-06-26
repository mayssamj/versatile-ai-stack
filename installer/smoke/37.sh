#!/usr/bin/env bash
# smoke/37.sh — Phase 37 (Concordia) E2E gate. Runs the seeded GABM sim
# (concordia/sims/smoke_sim.py) via bin/concordia and PASSES only when the sim ran a real
# 1-step simulation AND drove >=1 LLM call through LiteLLM on the scoped key.
#
# The sim self-bounds with signal.alarm (macOS has no `timeout`) and uses distinct exit
# codes: 0=ok (>=1 LLM call), 3=routing/auth/timeout fail or 0 calls (placeholder/401 key,
# empty output, or a single local model serializing Concordia's CONCURRENT per-step calls),
# 4=concordia import drift, 5=Concordia sim-construction API drift, 6=sim runtime drift,
# 7=wall-clock alarm. llm_calls>0 is the routing proof (the GABM analog of OASIS replies).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 37 — Concordia (GABM sim: 2 entities + Game Master -> LiteLLM)"

VENV="$AI_STACK/concordia/.venv"
[[ -x "$VENV/bin/python" ]] || { err "concordia venv missing — run: vz-ai-stack.sh install 37"; exit 1; }
"$VENV/bin/python" -c "import concordia" >/dev/null 2>&1 && ok "import concordia OK" \
  || { err "import concordia failed in the venv"; exit 1; }
"$VENV/bin/python" -c "import sentence_transformers" >/dev/null 2>&1 && ok "import sentence_transformers OK" \
  || { err "import sentence_transformers failed (embedder missing)"; exit 1; }
[[ -x "$AI_STACK/bin/concordia" ]] || { err "bin/concordia wrapper missing — run: vz-ai-stack.sh install 37"; exit 1; }
SIM="$AI_STACK/concordia/sims/smoke_sim.py"
[[ -f "$SIM" ]] || { err "seeded sim missing ($SIM) — re-run: vz-ai-stack.sh install 37"; exit 1; }

KEY="$(get_env CONCORDIA_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "CONCORDIA_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(litellm_scoped_curl "$KEY" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "CONCORDIA_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

log "Running the seeded Concordia GABM sim via bin/concordia (real 1-step sim; ~2-4 min; bounded by the sim's alarm)…"
# The gate runs the FAST claude-sonnet-sub-high, not the opus-xhigh default: Concordia's
# ~26 concurrent calls/step would blow the timeout at opus xhigh-effort. This proves the
# GABM wiring; the user's actual default (opus-sub-xhigh) is validated for reachability by
# the install-time scoped-key curl. Override here mirrors the install gate (CC_SMOKE_MODEL).
out="$(CONCORDIA_MODEL=claude-sonnet-sub-high "$AI_STACK/bin/concordia" "$SIM" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$out" | grep -vE '^(Loading weights|Warning: You are sending)' | sed 's/^/    /'

case "$rc" in
  0) : ;;  # sim ran + >=1 LLM call — fall through to the sentinel assertion
  3) err "the Concordia sim made no LLM calls / hit a routing failure (sim exit 3) — placeholder/401 key, empty output, or a single LOCAL model serializing Concordia's concurrent per-step calls until timeout (the gate runs claude-sonnet-sub-high for speed)"; exit 1 ;;
  4) err "concordia import drift (sim exit 4) — gdm-concordia API changed; re-verify concordia/sims/smoke_sim.py against the installed version"; exit 1 ;;
  5) err "Concordia sim-construction API drift (sim exit 5) — the prefab/Config/Simulation signature changed; fix concordia/sims/smoke_sim.py"; exit 1 ;;
  6) err "Concordia sim runtime error (sim exit 6) — see the traceback above"; exit 1 ;;
  7) err "the Concordia sim exceeded its wall-clock alarm (sim exit 7) — the bound model is too slow (a local model serializing concurrent calls?)"; exit 1 ;;
  *) err "the Concordia sim did not pass (exit $rc)"; exit 1 ;;
esac

# Belt-and-suspenders: parse the success sentinel and confirm llm_calls > 0.
_line="$(printf '%s' "$out" | grep -oE 'CONCORDIA_SMOKE_OK entities=[0-9]+ steps=[0-9]+ llm_calls=[0-9]+' | tail -1)"
_calls="${_line##*llm_calls=}"
[[ -n "$_line" && -n "$_calls" && "$_calls" -gt 0 ]] 2>/dev/null \
  || { err "sim exited 0 but the sentinel parse is inconsistent (line='${_line:-?}' calls='${_calls:-?}')"; exit 1; }
ok "Concordia GABM sim ran a real step driving $_calls LLM calls through LiteLLM — traced in Phoenix (http://phoenix:6006)"

ok "Smoke 37 PASS — Concordia GABM sim runs through LiteLLM on the scoped key"
