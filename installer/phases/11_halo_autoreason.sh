#!/usr/bin/env bash
# Phase 11 — HALO + autoreason (CLI / clone-only, off-band tooling).
#
# HALO (github.com/context-labs/halo) is an "LLM agent runtime over OTel trace
# data" — it reads a JSONL trace file, reasons over it with an agent loop to
# find failure patterns, and proposes fixes. It fits this stack natively: it
# consumes traces (we already write traces/litellm.jsonl) and speaks the OpenAI
# wire protocol, so it routes through LiteLLM like ACE/Pi.
#
# IMPORTANT (2026-05-31): the real package is `halo-engine` (exposes a `halo`
# CLI). The old phase installed `halo-cli`, a coincidentally-named Swagger
# codegen squatter with a self-contradictory click pin (click==7.1.2 vs its
# swagger-py-codegen→click<7) → uv "No solution found". `halo-engine` has no
# such conflict and IS the tool we want. CHANGELOG 2026-05-31.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"   # get_env/set_env for HALO_LITELLM_KEY

PHASE=11
HALO_WRAPPER="$AI_STACK/bin/halo"
HALO_MODEL_DEFAULT="claude-opus-sub-xhigh"   # platform default (Claude sub). Override to on-device with -m local-gemma4.

precheck() {
  # HALO is CLI-only; consider installed if either pip install succeeded or
  # the binary is on PATH. autoreason is clone-only — directory presence is
  # enough.
  [[ -d "$AI_STACK/halo" ]] || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (halo + autoreason)"
  exit 0
fi

hdr "Phase 11 — HALO + autoreason"

mkdir -p "$AI_STACK/halo"

# --- HALO via halo-engine (best-effort; optional experimental tooling) ------
# Install is fail-soft: a network/deno hiccup must not break `install all`,
# since HALO is off-band tooling. When it DOES install, wire it through LiteLLM
# (mint a virtual key + bin/halo wrapper) so it stays all-local, like ACE.
HALO_OK=0
if command -v uv >/dev/null 2>&1; then
  if command -v halo >/dev/null 2>&1 || uv tool list 2>/dev/null | grep -q '^halo-engine'; then
    ok "halo-engine already installed (exposes 'halo')"; HALO_OK=1
  else
    log "Installing halo-engine via uv tool (the real HALO; replaces the broken halo-cli squatter)..."
    if uv tool install halo-engine 2>&1 | tail -5; then
      ok "halo-engine installed (exposes 'halo')"; HALO_OK=1
    else
      warn "halo-engine install failed (network/deno?). HALO is optional — continuing."
    fi
  fi
else
  warn "uv not on PATH — skipping HALO (run Phase 14 first to get uv)."
fi

if (( HALO_OK )); then
  LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
  if [[ -z "$LITELLM_MASTER_KEY" ]]; then
    warn "LITELLM_MASTER_KEY missing — skipping HALO LiteLLM wiring (re-run 'install 11' after Phase 01)."
  else
    # Mint a HALO virtual key scoped to local models (mirrors ACE / Pi).
    HALO_KEY_CURRENT="$(get_env HALO_LITELLM_KEY '')"
    if [[ -z "$HALO_KEY_CURRENT" ]] \
       || ! litellm_scoped_curl "$HALO_KEY_CURRENT" -sf --max-time 5 http://litellm:4000/v1/models >/dev/null 2>&1; then
      log "Minting LiteLLM virtual key for HALO (models=[claude-opus-sub-xhigh, local-gemma4, local-qwen3])..."
      HALO_KEY_NEW="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
        -X POST http://litellm:4000/key/generate \
        -d '{"models":["claude-opus-sub-xhigh","local-gemma4","local-qwen3"],"key_alias":"halo-trace-engine","metadata":{"owner":"halo","purpose":"phase11"}}' \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
      if [[ -n "$HALO_KEY_NEW" ]]; then
        set_env HALO_LITELLM_KEY "$HALO_KEY_NEW"
        ok "HALO_LITELLM_KEY minted + saved to .env (mode 0600)"
      else
        warn "Failed to mint HALO_LITELLM_KEY — bin/halo will need OPENAI_API_KEY set manually."
      fi
    else
      ok "HALO_LITELLM_KEY already present + valid"
    fi

    # bin/halo wrapper: route through LiteLLM by default. HALO's own default model
    # is gpt-5.4-mini (cloud) — we inject the platform default (claude-opus-sub-xhigh)
    # via the virtual key (also scoped for the local-gemma4 override) unless the user
    # gives one. base_url + key come from OPENAI_BASE_URL / OPENAI_API_KEY env.
    cat > "$HALO_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/halo — HALO trace-analysis engine (halo-engine), routed through LiteLLM.
# Reads a JSONL trace (e.g. ~/ai-stack/traces/litellm.jsonl) and reasons over it.
#   bin/halo ~/ai-stack/traces/litellm.jsonl -p "Find the most common failure"
#   bin/halo <trace> -p "..." -m local-heavy      # override the model
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
source "\$AI_STACK/installer/lib/env.sh" 2>/dev/null || true
# Resolve the REAL halo-engine executable by absolute path. We must NOT use
# 'command -v halo' here: this wrapper is ALSO named 'halo' and \$AI_STACK/bin is
# on PATH, so command -v would find THIS wrapper → infinite self-exec.
HALO_BIN=""
for cand in "\$HOME/.local/bin/halo" "\${XDG_BIN_HOME:-\$HOME/.local/bin}/halo"; do
  [[ -x "\$cand" ]] && { HALO_BIN="\$cand"; break; }
done
[[ -n "\$HALO_BIN" ]] || { echo "halo-engine not installed — run 'bash vz-ai-stack.sh install 11'" >&2; exit 1; }
export OPENAI_BASE_URL="http://litellm:4000/v1"
export OPENAI_API_KEY="\$(get_env HALO_LITELLM_KEY '' 2>/dev/null)"
# HALO is built on the openai-agents SDK, which by default exports run traces to
# OpenAI's hosted trace ingester (keyless calls → noise, and a no-cloud
# violation). Disable it; HALO's own analysis output is unaffected.
export OPENAI_AGENTS_DISABLE_TRACING=1
# Inject a local default model unless the user passed -m/--model or just wants help.
inject_model=1
for a in "\$@"; do
  case "\$a" in -m|--model|-h|--help) inject_model=0 ;; esac
done
if (( inject_model )); then
  exec "\$HALO_BIN" --model "\${HALO_MODEL:-${HALO_MODEL_DEFAULT}}" "\$@"
else
  exec "\$HALO_BIN" "\$@"
fi
WRAPEOF
    chmod +x "$HALO_WRAPPER"
    ok "wrote $HALO_WRAPPER (routes via LiteLLM; default model ${HALO_MODEL_DEFAULT})"

    # Smoke test: wrapper runs (match ACE — --help only; a real trace analysis
    # is an on-demand experiment, not part of install).
    if "$HALO_WRAPPER" --help >/dev/null 2>&1; then
      ok "bin/halo --help: smoke-test passed"
    else
      warn "bin/halo --help returned non-zero — inspect $HALO_WRAPPER"
    fi
  fi
fi

# autoreason: clone-only research artifact. Original install guide pointed
# at openai/autoreason (404); the real repo is NousResearch/autoreason —
# matches the Hermes/Nous attribution of the rest of the stack.
if [[ ! -d "$AI_STACK/halo/autoreason/.git" ]]; then
  log "Cloning autoreason from NousResearch (was misattributed to openai in old guide)..."
  rm -rf "$AI_STACK/halo/autoreason.partial"
  if git clone https://github.com/NousResearch/autoreason "$AI_STACK/halo/autoreason.partial" 2>&1 | tail -3; then
    mv "$AI_STACK/halo/autoreason.partial" "$AI_STACK/halo/autoreason"
    ok "autoreason cloned"
  else
    rm -rf "$AI_STACK/halo/autoreason.partial"
    warn "autoreason clone failed (upstream may have moved again)."
  fi
fi

stamp_mark "$PHASE"
record "phase 11 complete: HALO + autoreason (best-effort)"
ok "Phase 11 — HALO + autoreason — complete"
