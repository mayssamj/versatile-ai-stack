#!/usr/bin/env bash
# Phase 29 — OpenWork (OPT-IN; headless OpenCode-powered Cowork workspace over your stack).
#
# NOT in `install all` — a headless agent workspace + its OpenCode sidecars is a
# deliberate opt-in (run: `vz-ai-stack.sh install openwork`). What this phase does:
#   (a) Install the headless orchestrator — `npm i -g openwork-orchestrator@<pin>`,
#       a prebuilt Bun-compiled standalone binary (npm integrity-checked). It
#       SELF-MANAGES OpenCode (downloads + caches the opencode/openwork-server/
#       opencode-router sidecars on first run) — so the stack adds NO `opencode`
#       host dependency. ("openwork ships as a compiled binary, Bun not required.")
#   (b) LiteLLM wiring — mint a model-scoped virtual key + pre-seed an
#       `opencode.json` (OpenAI-compatible provider → http://127.0.0.1:4000/v1).
#       The key NEVER lands literally in the file: opencode.json uses
#       `{env:OPENWORK_LITELLM_KEY}` and the daemon gets the value from .env.
#   (c) The managed daemon — `openwork serve` run as a loopback-only launchd
#       daemon on :8787 (bin/start-openwork.sh; mirrors Meridian/AionUi),
#       health-gated on /health 200.
#
# Architecture: §24 spec chose Design Y (headless orchestrator as a managed
# loopback daemon) over the desktop .dmg — Y is the stack-native shape AND lighter
# here (prebuilt binary, OpenCode self-managed, no cask). The desktop app is a
# documented alternate UI, not managed by this phase.
# Spec: doc/specs/2026-06-21-openwork-integration.md.
#
# SECURITY: serve binds 127.0.0.1 ONLY (never --remote-access). The minted LiteLLM
# key is model-scoped (never the master). Client/host tokens are generated with
# openssl, passed via env (never argv → not in `ps`), never printed. --approval
# manual (no host auto-approval). Host OpenCode runs as YOU — keep it loopback.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PHASE=29
NAME=openwork
OW_PORT=8787
# Pin a version for reproducibility; override with OPENWORK_VERSION (or "latest").
OW_VERSION="$(get_env OPENWORK_VERSION '0.17.1')"
# Per-stack workspace + opencode.json (separate from your personal ~/.config/opencode).
OW_WORKDIR="${OPENWORK_WORKDIR:-$HOME/.openwork-stack}"
OW_OPENCODE_JSON="$OW_WORKDIR/opencode.json"

# Models the OpenWork LiteLLM key may reach (a curated chat set — NOT the master
# key, NOT "all"). Widen by editing this list + re-running 'install 29'.
OPENWORK_KEY_MODELS='["claude-opus-4.8-sub-xhigh","claude-opus-4.8-sub-high","claude-sonnet-4.6-sub-high","local-gemma4","local-qwen3.6","local-qwen3-coder"]'

# Resolve the `openwork` binary (npm global bin is not always on a non-login PATH).
_ow_bin() {
  command -v openwork 2>/dev/null && return 0
  local p
  for p in "$HOME/.local/bin/openwork" "/opt/homebrew/bin/openwork" "/usr/local/bin/openwork"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  # npm global prefix bin (handles nvm / custom prefixes)
  if command -v npm >/dev/null 2>&1; then
    p="$(npm prefix -g 2>/dev/null)/bin/openwork"
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  fi
  return 1
}

# --- precheck: binary at pinned version + opencode.json + key + healthy → done --
precheck() {
  local bin; bin="$(_ow_bin)" || return 1
  "$bin" --version 2>/dev/null | head -1 | grep -qF "$OW_VERSION" || return 1
  [[ -f "$OW_OPENCODE_JSON" ]] || return 1
  [[ -n "$(get_env OPENWORK_LITELLM_KEY '')" ]] || return 1
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$OW_PORT/health" 2>/dev/null | grep -q '^200$' || return 1
  return 0
}
if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (OpenWork $OW_VERSION installed, daemon healthy on :$OW_PORT)"
  exit 0
fi

hdr "Phase 29 — OpenWork (opt-in headless OpenCode-powered Cowork workspace)"

# --- Preconditions -----------------------------------------------------------
command -v npm >/dev/null 2>&1 || { err "npm/node required (host dep) — see doc/PREREQUISITES.md or run 'vz-ai-stack.sh deps'."; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
if ! curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1 \
   && ! curl -sf --max-time 3 -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://litellm:4000/v1/models >/dev/null 2>&1; then
  err "LiteLLM not reachable at http://litellm:4000 — run 'vz-ai-stack.sh start litellm'."
  exit 1
fi

# --- 1. Headless orchestrator (npm global; prebuilt binary; idempotent) -------
# `npm i -g openwork-orchestrator@<ver>` pulls a thin platform-dispatcher whose
# optionalDependency is a per-platform Bun-compiled standalone (npm integrity-
# checked; sha512 + provenance). We fail CLOSED if the resolved binary doesn't run.
if _bin="$(_ow_bin)" && "$_bin" --version 2>/dev/null | head -1 | grep -qF "$OW_VERSION"; then
  ok "openwork-orchestrator $OW_VERSION already installed ($_bin)"
else
  log "Installing openwork-orchestrator@$OW_VERSION (npm global; prebuilt binary)…"
  if [[ "$OW_VERSION" == "latest" ]]; then
    npm install -g openwork-orchestrator@latest 2>&1 | tail -4 || { err "npm install openwork-orchestrator@latest failed"; exit 1; }
  else
    npm install -g "openwork-orchestrator@$OW_VERSION" 2>&1 | tail -4 || { err "npm install openwork-orchestrator@$OW_VERSION failed"; exit 1; }
  fi
  _bin="$(_ow_bin)" || { err "openwork not on PATH after npm install — check 'npm prefix -g'/bin and your PATH"; exit 1; }
  _v="$("$_bin" --version 2>/dev/null | head -1)" || true
  [[ -n "$_v" ]] || { err "openwork installed but '--version' did not run (binary not executable on this host) — refusing to continue"; exit 1; }
  ok "openwork-orchestrator installed: $_v ($_bin)"
fi

# --- 2. Mint scoped LiteLLM virtual key for OpenWork -------------------------
# Model-scoped (never master). A stale/revoked key returns 200 + empty data[], so
# require a real model "id" in the response (council SRE pattern from Phase 26/28).
OPENWORK_KEY_CURRENT="$(get_env OPENWORK_LITELLM_KEY '')"
_models_resp="$(curl -s --max-time 5 -H "Authorization: Bearer $OPENWORK_KEY_CURRENT" http://litellm:4000/v1/models 2>/dev/null)"
if [[ -z "$OPENWORK_KEY_CURRENT" ]] || ! printf '%s' "$_models_resp" | grep -q '"id"'; then
  log "Minting scoped LiteLLM virtual key for OpenWork…"
  _gen_body="$(python3 -c 'import json,sys; print(json.dumps({"models":json.loads(sys.argv[1]),"key_alias":"openwork","metadata":{"owner":"openwork","purpose":"phase29"}}))' "$OPENWORK_KEY_MODELS")"
  OPENWORK_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate -d "$_gen_body" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$OPENWORK_KEY_NEW" ]] || { err "Failed to mint OPENWORK_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env OPENWORK_LITELLM_KEY "$OPENWORK_KEY_NEW"
  ok "OPENWORK_LITELLM_KEY minted + saved to .env (0600)"
else
  ok "OPENWORK_LITELLM_KEY already present + valid"
fi

# --- 3. Generate loopback daemon tokens (env-passed, never argv/stdout) -------
# OpenWork issues client + host(approval) tokens. We pin our own so the daemon is
# stable across restarts. openssl rand → .env 0600; never printed.
if [[ -z "$(get_env OPENWORK_CLIENT_TOKEN '')" ]]; then
  set_env OPENWORK_CLIENT_TOKEN "$(openssl rand -hex 24)"
  ok "OPENWORK_CLIENT_TOKEN generated + saved to .env (0600)"
fi
if [[ -z "$(get_env OPENWORK_HOST_TOKEN '')" ]]; then
  set_env OPENWORK_HOST_TOKEN "$(openssl rand -hex 24)"
  ok "OPENWORK_HOST_TOKEN generated + saved to .env (0600)"
fi

# --- 4. Pre-seed opencode.json (LiteLLM provider; key via {env:}) ------------
# OpenWork drives OpenCode, which reads opencode.json. We seed a per-stack
# workspace config so the LiteLLM provider + models appear without manual UI steps.
# The apiKey is the indirection `{env:OPENWORK_LITELLM_KEY}` — the literal key is
# NEVER written to this file (the daemon injects the value from .env).
mkdir -p "$OW_WORKDIR"
if [[ -f "$OW_OPENCODE_JSON" ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OW_OPENCODE_JSON" 2>/dev/null \
   && grep -q 'OPENWORK_LITELLM_KEY' "$OW_OPENCODE_JSON" 2>/dev/null; then
  ok "opencode.json already seeded ($OW_OPENCODE_JSON)"
else
  log "Seeding $OW_OPENCODE_JSON with the LiteLLM provider…"
  # Build the models map from OPENWORK_KEY_MODELS so the file stays in sync with scope.
  python3 - "$OW_OPENCODE_JSON" "$OPENWORK_KEY_MODELS" <<'PY'
import json, sys
path, models_json = sys.argv[1], sys.argv[2]
ids = json.loads(models_json)
cfg = {
    "$schema": "https://opencode.ai/config.json",
    "provider": {
        "litellm": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "ai-stack LiteLLM",
            "options": {
                "baseURL": "http://127.0.0.1:4000/v1",
                "apiKey": "{env:OPENWORK_LITELLM_KEY}",
            },
            "models": {mid: {"name": mid} for mid in ids},
        }
    },
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OW_OPENCODE_JSON" \
    || { err "seeded opencode.json is not valid JSON — aborting"; exit 1; }
  chmod 600 "$OW_OPENCODE_JSON" 2>/dev/null || true
  ok "opencode.json seeded (LiteLLM provider; key via {env:OPENWORK_LITELLM_KEY})"
fi

# --- 5. The managed daemon (openwork serve as a loopback launchd job) ---------
bash "$AI_STACK/bin/start-openwork.sh" install || { err "start-openwork.sh install failed"; exit 1; }

# --- 6. Smoke (leaf-safe: binary + daemon health are the gate) ----------------
_smoke_ok=1
_bin="$(_ow_bin)" || { err "smoke: openwork binary missing"; _smoke_ok=0; }
[[ -n "${_bin:-}" ]] && "$_bin" --version >/dev/null 2>&1 || { err "smoke: openwork --version failed"; _smoke_ok=0; }
[[ -f "$OW_OPENCODE_JSON" ]] || { err "smoke: opencode.json missing"; _smoke_ok=0; }
# The launchd daemon needs time to download/spawn sidecars on first run; poll generously.
_ow_up=0; for _ in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$OW_PORT/health" 2>/dev/null | grep -q '^200$' && { _ow_up=1; break; }; sleep 3
done
(( _ow_up )) || { err "smoke: openwork daemon not serving /health 200 on :$OW_PORT — check installer/state/openwork.launchd.log (first run downloads OpenCode sidecars — give it a minute, then 'start openwork')"; _smoke_ok=0; }
(( _smoke_ok )) || { err "Phase 29 smoke failed — not stamping."; exit 1; }
ok "smoke: openwork installed + daemon healthy on http://127.0.0.1:$OW_PORT/health"

stamp_mark "$PHASE"
record "phase 29 complete: openwork-orchestrator daemon + scoped LiteLLM key + seeded opencode.json"
ok "Phase 29 — OpenWork — complete"
note "WebUI:    open http://127.0.0.1:$OW_PORT   (loopback-only OpenCode Cowork workspace)"
note "Models:   pre-seeded via $OW_OPENCODE_JSON → LiteLLM (claude-opus-4.8-sub-xhigh, local-gemma4, …)"
note "Workspace: $OW_WORKDIR   (per-stack; separate from your personal ~/.config/opencode)"
note "Heads-up (24GB): the orchestrator + its OpenCode sidecars stay resident — 'stop openwork' when done, especially alongside AionUi or heavy local models."
note "Desktop app (optional alternate UI): download from https://github.com/different-ai/openwork/releases — point its OpenCode at the same opencode.json."
note "Manage: vz-ai-stack.sh start openwork | stop openwork | help openwork | doctor openwork"
note "Uninstall: vz-ai-stack.sh stop openwork; bash $AI_STACK/bin/start-openwork.sh uninstall; npm uninstall -g openwork-orchestrator; rm -rf $OW_WORKDIR"
