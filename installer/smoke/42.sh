#!/usr/bin/env bash
# smoke/42.sh — Phase 42 (omp / oh-my-pi) E2E gate. PASSES only when the REAL user path
# works: `bin/omp -p` (one-shot, stack profile, scoped key) returns the sentinel through
# LiteLLM. This is the AC-3 proof — the wiring-only presence checks live in doctor 84.
#
# Model: the one-shot runs omp's default role = claude-opus-sub-xhigh (the operator's chosen
# default — a SUB route, so never-load-local holds; `local` is allow-listed but never a
# default). Bounded with a perl alarm (macOS has no coreutils `timeout`; alarm survives
# exec, so SIGALRM terminates a hung omp).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 42 — omp one-shot reply through LiteLLM (stack profile, scoped key)"

OMP_BIN="$AI_STACK/omp/omp-darwin-arm64"
[[ -x "$OMP_BIN" ]] || { err "omp binary missing — run: mayssam-ai-stack.sh install 42"; exit 1; }
"$OMP_BIN" --version >/dev/null 2>&1 && ok "omp --version OK ($("$OMP_BIN" --version 2>/dev/null | head -1))" \
  || { err "omp --version failed"; exit 1; }
[[ -x "$AI_STACK/bin/omp" ]] || { err "bin/omp wrapper missing — run: mayssam-ai-stack.sh install 42"; exit 1; }

PROF="$HOME/.omp/profiles/ai-stack/agent"
[[ -f "$PROF/models.yml" && -f "$PROF/config.yml" ]] \
  || { err "stack profile configs missing ($PROF) — run: mayssam-ai-stack.sh install 42"; exit 1; }
grep -q 'baseUrl: http://127.0.0.1:4000/v1' "$PROF/models.yml" && ok "profile points at LiteLLM :4000" \
  || { err "profile models.yml does not point at LiteLLM"; exit 1; }
grep -q 'approvalMode: write' "$PROF/config.yml" && ok "hardening present (approvalMode write, yolo off)" \
  || { err "profile hardening drifted (approvalMode) — run: mayssam-ai-stack.sh install 42"; exit 1; }

KEY="$(get_env OMP_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "OMP_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(litellm_scoped_curl "$KEY" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "OMP_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

log "Running the REAL path: bin/omp -p one-shot on the default role (claude-opus-sub-xhigh; ~10-90s; 240s alarm)…"
# Computed sentinel (OMP_SMOKE_42 is NOT in the prompt — an echoed prompt can't false-pass)
# + scratch cwd (approvalMode write auto-approves workspace writes; a stray write must not
# land in the repo).
_scratch="$(mktemp -d)"
out="$(cd "$_scratch" && perl -e 'alarm 240; exec @ARGV or die "exec: $!"' \
  "$AI_STACK/bin/omp" -p 'Compute 40+2 and reply with exactly OMP_SMOKE_ followed immediately by the result. No other text.' 2>&1)" && rc=0 || rc=$?
rm -rf "$_scratch"
printf '%s\n' "$out" | tail -5 | sed 's/^/    /'
if (( rc != 0 )); then
  err "bin/omp -p exited $rc (142 = SIGALRM wall-clock bound — a hung TUI or a stuck route). Check: is LiteLLM up? is Meridian up (claude-*-sub routes availability-gate)? Then: mayssam-ai-stack.sh install 42"
  exit 1
fi
printf '%s' "$out" | grep -q 'OMP_SMOKE_42' \
  || { err "omp replied but the computed sentinel (OMP_SMOKE_42) is missing — the reply did not come through as expected (see output above)"; exit 1; }
ok "omp one-shot returned the sentinel through LiteLLM on the scoped key — traced in Phoenix (http://phoenix:6006)"

ok "Smoke 42 PASS — omp answers end-to-end on the stack profile"
