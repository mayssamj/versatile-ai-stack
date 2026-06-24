#!/usr/bin/env bash
# Phase 28 — AionUi (OPT-IN; desktop + WebUI Cowork workspace over your stack).
#
# NOT in `install all` — a desktop GUI app + a 61MB WebUI server is a deliberate
# opt-in (run: `vz-ai-stack.sh install aionui`). What this phase installs:
#   (a) the AionUi desktop app           — `brew install --cask aionui`
#   (b) LiteLLM wiring                    — a scoped virtual key; you paste it +
#       http://127.0.0.1:4000/v1 into AionUi Settings → Models → Custom (UI-driven,
#       AionUi stores it in its own SQLite, so this is guided not auto-seeded)
#   (c) the WebUI server                  — the prebuilt, bun-compiled `aionui-web`
#       standalone binary (GitHub Releases, SHA256-verified) run as a loopback-only
#       launchd daemon on :25808 (bin/start-aionui.sh; mirrors Meridian)
#   (d) the Hermes bridge (Design X)      — host `hermes-agent[acp]` so `hermes` is
#       on PATH; AionUi's aioncore auto-detects it as a built-in agent. Pointing it
#       at LiteLLM is a guided step (see notes); deep fleet-soul-profile import is a
#       documented follow-up.
#
# Architecture: §24 council chose Design X (host-native hermes-acp) over proxying
# into the containerized fleet (which would inherit the OpenShell 1h-token/relay
# fragility in an interactive GUI). Spec: doc/specs/2026-06-20-aionui-integration.md.
#
# SECURITY: aionui-web binds 127.0.0.1 only (loopback ⇒ aioncore auth disabled,
# same posture as every localhost stack service). The minted LiteLLM key is
# model-scoped (never the master). Host hermes runs as YOU — do not point AionUi's
# Hermes at untrusted prompts with auto-approval.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PHASE=28
NAME=aionui
AW_DIR="$HOME/.local/share/aionui-web"
AW_BIN="$AW_DIR/aionui-web"
AW_PORT=25808
# Pin a version for reproducibility; override with AIONUI_WEB_VERSION (or "latest").
AW_VERSION="$(get_env AIONUI_WEB_VERSION '2.1.21')"
AW_REPO="iOfficeAI/AionUi"

# Models the AionUi LiteLLM key may reach (a curated chat set — NOT the master key,
# NOT "all"). Widen by editing this list + re-running 'install 28'.
AIONUI_KEY_MODELS='["claude-opus-sub-xhigh","claude-opus-sub-high","claude-sonnet-sub-high","local-gemma4","local-qwen3"]'

# --- precheck: cask + binary + healthy + key present → already done -----------
precheck() {
  brew list --cask aionui >/dev/null 2>&1 || return 1
  [[ -x "$AW_BIN" ]] || return 1
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$AW_PORT/" 2>/dev/null | grep -q '^200$' || return 1
  [[ -n "$(get_env AIONUI_LITELLM_KEY '')" ]] || return 1
  return 0
}
if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (AionUi installed, WebUI healthy on :$AW_PORT)"
  exit 0
fi

hdr "Phase 28 — AionUi (opt-in desktop + WebUI Cowork workspace)"

# --- Preconditions -----------------------------------------------------------
command -v brew >/dev/null 2>&1 || { err "Homebrew required. See doc/PREREQUISITES.md"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
if ! curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1 \
   && ! litellm_master_curl -sf --max-time 3 http://litellm:4000/v1/models >/dev/null 2>&1; then
  err "LiteLLM not reachable at http://litellm:4000 — run 'vz-ai-stack.sh start litellm'."
  exit 1
fi

# --- 1. AionUi desktop app (brew cask; idempotent) ---------------------------
if brew list --cask aionui >/dev/null 2>&1; then
  ok "AionUi desktop app already installed (brew --cask aionui)"
else
  log "Installing AionUi desktop app (brew install --cask aionui)…"
  brew install --cask aionui 2>&1 | tail -4 || { err "brew install --cask aionui failed"; exit 1; }
  ok "AionUi desktop app installed (/Applications/AionUi.app)"
fi

# --- 2. WebUI server: prebuilt aionui-web binary (download + SHA256 verify) ---
# A self-contained, bun-compiled standalone (bundles aioncore + static). Mirrors
# the upstream scripts/install-web.sh, inlined so the phase has no clone dependency.
_install_aionui_web() {
  local ver="$1" arch tarball url sum_url tmp
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x86_64 ;; *) err "unsupported arch $(uname -m)"; return 1 ;; esac
  if [[ "$ver" == "latest" ]]; then
    ver="$(curl -fsSL "https://api.github.com/repos/$AW_REPO/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')"
    [[ -n "$ver" ]] || { err "could not resolve latest aionui-web version (set AIONUI_WEB_VERSION)"; return 1; }
  fi
  tarball="aionui-web-${ver}-darwin-${arch}.tar.gz"
  url="https://github.com/$AW_REPO/releases/download/v${ver}/${tarball}"
  sum_url="${url}.sha256"
  tmp="$(mktemp -d)"; trap "rm -rf '$tmp'" RETURN
  log "Downloading $tarball …"
  curl -fSL --progress-bar -o "$tmp/$tarball" "$url" 2>&1 | tail -1 || { err "download failed: $url"; return 1; }
  # SHA256 verify (skip-with-warning only if the checksum asset is absent).
  if curl -fsSL -o "$tmp/sum" "$sum_url" 2>/dev/null; then
    local want got; want="$(awk '{print $1}' "$tmp/sum")"; got="$(shasum -a 256 "$tmp/$tarball" | awk '{print $1}')"
    [[ "$want" == "$got" ]] || { err "SHA256 mismatch for $tarball (want ${want:0:12}… got ${got:0:12}…)"; return 1; }
    ok "aionui-web $ver SHA256 verified"
  else
    err "no .sha256 checksum asset for $tarball — refusing to install an unverified binary (it runs as a persistent user daemon). Pin a known-good AIONUI_WEB_VERSION that ships a .sha256."
    return 1
  fi
  # Extract → ~/.local/share/aionui-web (backup any prior install).
  [[ -d "$AW_DIR" ]] && mv "$AW_DIR" "${AW_DIR}.bak-$(date +%s)"
  mkdir -p "$(dirname "$AW_DIR")" "$tmp/x"
  tar -xzf "$tmp/$tarball" -C "$tmp/x" || { err "extract failed"; return 1; }
  if [[ -d "$tmp/x/aionui-web" ]]; then mv "$tmp/x/aionui-web" "$AW_DIR"; else err "tarball missing aionui-web/ dir"; return 1; fi
  chmod +x "$AW_BIN" 2>/dev/null || true
  command -v xattr >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$AW_DIR" 2>/dev/null || true
  mkdir -p "$HOME/.local/bin"; ln -sf "$AW_BIN" "$HOME/.local/bin/aionui-web"
  [[ -x "$AW_BIN" ]] || { err "aionui-web not executable after install"; return 1; }
}
if [[ -x "$AW_BIN" ]] && "$AW_BIN" version 2>/dev/null | head -1 | grep -qF "$AW_VERSION"; then
  ok "aionui-web $AW_VERSION already installed"
else
  _install_aionui_web "$AW_VERSION" || { err "aionui-web install failed"; exit 1; }
  ok "aionui-web installed: $("$AW_BIN" version 2>/dev/null | head -1)"
fi

# --- 3. Mint scoped LiteLLM virtual key for AionUi ---------------------------
# Model-scoped (never master). A stale/revoked key returns 200 + empty data[], so
# require a real model "id" in the response (council SRE pattern from Phase 26).
AIONUI_KEY_CURRENT="$(get_env AIONUI_LITELLM_KEY '')"
_models_resp="$(litellm_scoped_curl "$AIONUI_KEY_CURRENT" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null)"
if [[ -z "$AIONUI_KEY_CURRENT" ]] || ! printf '%s' "$_models_resp" | grep -q '"id"'; then
  log "Minting scoped LiteLLM virtual key for AionUi…"
  _gen_body="$(python3 -c 'import json,sys; print(json.dumps({"models":json.loads(sys.argv[1]),"key_alias":"aionui","metadata":{"owner":"aionui","purpose":"phase28"}}))' "$AIONUI_KEY_MODELS")"
  AIONUI_KEY_NEW="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate -d "$_gen_body" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$AIONUI_KEY_NEW" ]] || { err "Failed to mint AIONUI_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env AIONUI_LITELLM_KEY "$AIONUI_KEY_NEW"
  ok "AIONUI_LITELLM_KEY minted + saved to .env (0600)"
else
  ok "AIONUI_LITELLM_KEY already present + valid"
fi
# Self-heal the key's allow-list against renamed models: the mint above only re-mints
# when the key is fully dead, so a model rename leaves a stale key SILENT-403ing the
# new alias (`model sync` never touches this key). See litellm_reconcile_key (common.sh).
litellm_reconcile_key AIONUI_LITELLM_KEY "$AIONUI_KEY_MODELS"

# --- 4. WebUI server as a loopback launchd daemon (Meridian pattern) ---------
bash "$AI_STACK/bin/start-aionui.sh" install || { err "start-aionui.sh install failed"; exit 1; }

# --- 5. Hermes bridge (Design X; gated/best-effort, non-fatal) ---------------
# Install host hermes-agent[acp] so `hermes` is on PATH — AionUi's aioncore
# auto-detects it as a built-in agent. Pointing it at LiteLLM + importing the fleet
# souls as profiles is a guided/follow-up step (see notes) — never block the phase.
if command -v uv >/dev/null 2>&1; then
  if [[ -x "$HOME/.local/bin/hermes-acp" ]]; then
    ok "host hermes-agent[acp] already installed (AionUi auto-detects 'hermes')"
  else
    log "Installing host hermes-agent[acp] (uv tool) for the AionUi Hermes bridge…"
    if uv tool install 'hermes-agent[acp]' >/dev/null 2>&1; then
      ok "hermes-agent[acp] installed → ~/.local/bin/{hermes,hermes-acp}; AionUi auto-detects 'hermes'"
    else
      warn "hermes-agent[acp] install failed — the Hermes bridge is optional; AionUi core works without it. Retry: uv tool install 'hermes-agent[acp]'"
    fi
  fi
else
  note "uv not on PATH — skipping the Hermes bridge (optional). Install uv (Phase 14) then re-run 'install 28' to enable it."
fi

# --- 6. Smoke test (leaf-safe: the desktop app + WebUI + key are the gate) ----
_smoke_ok=1
brew list --cask aionui >/dev/null 2>&1 || { err "smoke: AionUi cask missing"; _smoke_ok=0; }
[[ -x "$AW_BIN" ]] || { err "smoke: aionui-web binary missing"; _smoke_ok=0; }
# The launchd daemon needs a few seconds to bind; poll briefly.
_aw_up=0; for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$AW_PORT/" 2>/dev/null | grep -q '^200$' && { _aw_up=1; break; }; sleep 2
done
(( _aw_up )) || { err "smoke: aionui-web not serving 200 on :$AW_PORT — check installer/state/aionui-web.launchd.log"; _smoke_ok=0; }
(( _smoke_ok )) || { err "Phase 28 smoke failed — not stamping."; exit 1; }
ok "smoke: AionUi cask present + aionui-web healthy on http://127.0.0.1:$AW_PORT"

stamp_mark "$PHASE"
record "phase 28 complete: AionUi desktop + aionui-web daemon + scoped LiteLLM key + hermes bridge (best-effort)"
ok "Phase 28 — AionUi — complete"
note "WebUI:    open http://127.0.0.1:$AW_PORT   (loopback-only Cowork workspace)"
note "Desktop:  open -a AionUi                    (the native app; quit when done)"
note "Wire your stack models (one-time, in either UI): Settings → Models → Add Model → Custom"
note "   Base URL:  http://127.0.0.1:4000/v1"
note "   API Key:   \$(grep ^AIONUI_LITELLM_KEY= $AI_STACK/.env | cut -d= -f2-)"
note "   Models:    claude-opus-sub-xhigh, local-gemma4, local-qwen3, …"
note "Hermes bridge: AionUi auto-detects 'hermes' (host) — point it at LiteLLM with"
note "   'hermes model' (base URL http://127.0.0.1:4000/v1 + the key above), then pick it in AionUi."
note "Manage: vz-ai-stack.sh start aionui | stop aionui | help aionui | doctor aionui"
note "Uninstall: vz-ai-stack.sh stop aionui; bash $AI_STACK/bin/start-aionui.sh uninstall; brew uninstall --cask aionui; rm -rf ~/.local/share/aionui-web ~/.aionui-web"
