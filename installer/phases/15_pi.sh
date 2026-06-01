#!/usr/bin/env bash
# Phase 15 — Pi (Earendil coding agent), isolated in the pi-v1 OpenShell
# sandbox.
#
# Pi (`@earendil-works/pi-coding-agent`) is an extensible terminal coding
# agent. We run it inside its own OpenShell sandbox so the rest of the
# stack (Hermes fleet, AutoFyn, Paperclip, etc.) cannot see what Pi sees,
# and Pi can only reach a tight allowlist:
#   - inference.local        (LiteLLM via gateway L7 rewrite — no key exposure)
#   - host.docker.internal:8000  (Honcho memory; Pi uses peer `pi`)
#   - host.docker.internal:8765  (docs-mcp; read-only by virtue of the
#                                  MCP tool surface)
#   - npm/pypi/github            (extension installs + reference repo clones)
#
# Pi's tarball is pre-staged at $AI_STACK/pi/earendil-works-pi-coding-agent-*.tgz
# because OpenShell's egress proxy mishandles scoped npm URLs
# (@earendil-works%2fpi-coding-agent). We `openshell sandbox upload` the
# tarball, then `npm install ./<file>.tgz` from inside.
#
# Architecture choice was OpenShell-first (vs Docker isolation) per
# Mayssam's call after the 2026-05-29 2-reviewer forum. See
# CHANGELOG.md 2026-05-29 entries.
#
# Standalone install: `bash install.sh install 15`
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/openshell.sh"  # hang-resilient sandbox create

PHASE=15
SANDBOX=pi-v1
POLICY="$AI_STACK/openshell/policies/${SANDBOX}.yaml"
PI_DIR="$AI_STACK/pi"
PI_EXT_SRC="$PI_DIR/inference-local.ts"
HONCHO_BASE="${HONCHO_BASE_URL:-http://honcho:8000}"
HONCHO_WORKSPACE="${HONCHO_WORKSPACE_ID:-default}"
PI_PEER_ID="pi"

resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null; then command -v openshell
  else echo ""
  fi
}

precheck() {
  local osh; osh="$(resolve_openshell)"
  [[ -n "$osh" ]] || return 1
  [[ -f "$POLICY" ]] || return 1
  [[ -f "$PI_EXT_SRC" ]] || return 1
  # Sandbox must exist and be Ready.
  "$osh" sandbox list 2>/dev/null \
    | awk -v s="$SANDBOX" 'NR>1 && $1==s && $NF=="Ready" {ok=1} END{exit !ok}' \
    || return 1
  # Pi CLI must be installed inside the sandbox.
  "$osh" sandbox exec -n "$SANDBOX" --no-tty -- \
    /bin/sh -c 'test -x /sandbox/node_modules/.bin/pi' 2>/dev/null || return 1
  # Inference route must be wired at the gateway.
  "$osh" inference get 2>/dev/null | grep -q "Model: local-heavy" || return 1
  # Extension file in place inside the sandbox.
  "$osh" sandbox exec -n "$SANDBOX" --no-tty -- \
    /bin/sh -c 'test -f /sandbox/.pi/extensions/inference-local.ts' 2>/dev/null \
    || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (pi installed in $SANDBOX + inference.local wired)"
  exit 0
fi

hdr "Phase 15 — Pi (coding agent) in $SANDBOX sandbox"

OSH="$(resolve_openshell)"
[[ -n "$OSH" ]] || { err "openshell CLI not found — run 'bash install.sh install 04' first."; exit 1; }
[[ -f "$POLICY" ]] || { err "missing policy file: $POLICY"; exit 1; }
[[ -f "$PI_EXT_SRC" ]] || { err "missing Pi extension source: $PI_EXT_SRC"; exit 1; }

# --- LiteLLM virtual key for Pi -------------------------------------------
# Pi calls http://host.docker.internal:4000/v1 directly with PI_LITELLM_KEY.
# Server-side, LiteLLM enforces the model allowlist (rejects cloud models
# with HTTP 403 + "key not allowed to access model").
# OpenShell's inference.local L7 rewrite was the original target but the
# shipped `openai` provider type ignores --config endpoint and forwards
# to api.openai.com — virtual-key direct dial is the working pattern.
# env.sh provides get_env (reads .env file on each call) and load_env_strict
# (validates format). There is no `load_env` that bulk-exports — bin/start-*.sh
# scripts use the same per-key get_env pattern. CHANGELOG 2026-05-29 logs the
# fix for the typo masked by `|| true`.
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
if [[ -z "$LITELLM_MASTER_KEY" ]]; then
  err "LITELLM_MASTER_KEY missing from .env — Phase 01 must run first."
  exit 1
fi

# Scoped key minted against the fixed SUPERSET (legacy IDs UNION the 3 canonical
# model<->agent slugs) so `install.sh model assign/sync` can point Pi at
# local-qwen3-coder (its declared default) without ever re-minting. The canonical
# IDs are registered in config.yaml by Phase 01 BEFORE this mint
# (superset-before-mint). LiteLLM enforces the allowlist server-side (cloud => 403).
PI_SUPERSET_JSON='["local","local-gemma4","local-heavy","local-lfm2","local-qwen3-coder","local-qwen3.6"]'
PI_KEY_CURRENT="$(get_env PI_LITELLM_KEY '')"
if [[ -z "$PI_KEY_CURRENT" ]] \
   || ! curl -sf --max-time 5 -H "Authorization: Bearer $PI_KEY_CURRENT" http://litellm:4000/v1/models >/dev/null 2>&1; then
  log "Minting LiteLLM virtual key for Pi (models=superset[local,local-gemma4,local-heavy,local-lfm2,local-qwen3-coder,local-qwen3.6])..."
  PI_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate \
    -d "{\"models\":${PI_SUPERSET_JSON},\"key_alias\":\"pi-coding-agent\",\"metadata\":{\"owner\":\"pi\",\"purpose\":\"phase15\"}}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  if [[ -z "$PI_KEY_NEW" ]]; then
    err "Failed to mint PI_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"
    err "Verify: curl -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" http://litellm:4000/key/info"
    exit 1
  fi
  set_env PI_LITELLM_KEY "$PI_KEY_NEW"
  ok "PI_LITELLM_KEY minted (superset allowlist) + saved to .env (mode 0600)"
else
  ok "PI_LITELLM_KEY already present + valid"
fi

# --- Pi default model: local-qwen3-coder, AVAILABILITY-GATED ---------------
# Pi's declared default is local-qwen3-coder (an LM Studio MLX model). On a
# fresh install LM Studio is down, so we gate the value down to `local` (gemma4)
# — never write an MLX slug Pi/LiteLLM can't serve. Promote it later by starting
# LM Studio + `install.sh model sync` (which re-renders PI_DEFAULT_MODEL).
PI_KEY_PROBE="$(get_env PI_LITELLM_KEY '')"
# Gated-fallback target = models.yml .default (local-gemma4), matching doctor 40 +
# `model sync` so a fresh install (LM Studio down) shows no false DRIFT. Literal
# `local` only when models.yml is absent.
PI_DEFAULT="local"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _pd="$(yq -r '.default' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_pd" && "$_pd" != "null" ]] && PI_DEFAULT="$_pd"
fi
if curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null \
   && grep -qF 'model_name: local-qwen3-coder' "$AI_STACK/litellm/config.yaml" 2>/dev/null \
   && curl -s --max-time 5 http://litellm:4000/v1/models -H "Authorization: Bearer $PI_KEY_PROBE" 2>/dev/null | grep -q '"local-qwen3-coder"'; then
  PI_DEFAULT="local-qwen3-coder"
fi
set_env PI_DEFAULT_MODEL "$PI_DEFAULT"
ok "PI_DEFAULT_MODEL=$PI_DEFAULT (availability-gated; bin/pi injects --model \${PI_DEFAULT_MODEL:-local} when -m absent)"

# --- Sandbox: hang-resilient create-with-policy (shared lib) --------------
# openshell_sandbox_ensure (installer/lib/openshell.sh) creates pi-v1 WITH its
# tight policy from birth (`--policy <file> -- /bin/true`, so Pi never has a
# window of the broad base allowlist) and watchdog-polls Phase=Ready, freeing
# the create CLI that otherwise hangs indefinitely even AFTER the sandbox is up
# (HANDOFF §2.2). On Error/stuck it deletes + retries, then escalates to a
# gateway restart. Replaces the previous unbounded `sandbox create` + a manual
# 5-min Ready poll.
if ! openshell_sandbox_ensure "$OSH" "$SANDBOX" base -- --policy "$POLICY" -- /bin/true; then
  err "sandbox '$SANDBOX' could not reach Ready (see installer/state/openshell-create-${SANDBOX}.log)"
  exit 1
fi
ok "sandbox $SANDBOX: Ready"

# --- Install Pi via pre-built node_modules tar ----------------------------
# OpenShell's egress proxy mishandles scoped npm URLs
# (@earendil-works/..., @silvia-odwyer/..., etc.) — they return 000 even
# though the policy allowlist permits registry.npmjs.org. To work around,
# we pre-build node_modules on the Mac (where npm resolves scoped packages
# normally), tar it, and extract inside the sandbox.
#
# ⚠️ TAR UPGRADE TRIGGER: this phase only rebuilds the tar when it is
# MISSING. Bumping the Pi version in pi/package.json alone will NOT
# regenerate the tar — you must:
#   rm -f $AI_STACK/pi/pi-bootstrap.tar.gz pi/package-lock.json
#   bash install.sh install 15
# We don't auto-rebuild on package.json change because npm install + tar
# is ~30s and most re-runs are unrelated config changes.
PI_BOOTSTRAP_TAR="$PI_DIR/pi-bootstrap.tar.gz"
if [[ ! -f "$PI_BOOTSTRAP_TAR" ]] || [[ ! -f "$PI_DIR/package.json" ]]; then
  log "Building Pi node_modules tree on host (Mac npm has scoped-package access)..."
  ( cd "$PI_DIR" && {
      [[ -f package.json ]] || cat > package.json <<JSON
{
  "name": "pi-bootstrap",
  "version": "1.0.0",
  "private": true,
  "dependencies": { "@earendil-works/pi-coding-agent": "0.77.0" }
}
JSON
      rm -rf node_modules package-lock.json
      npm install --no-fund --no-audit
      tar czf pi-bootstrap.tar.gz node_modules package.json package-lock.json
    }
  ) 2>&1 | tail -5 || { err "host-side Pi node_modules build failed"; exit 1; }
fi
ok "pi-bootstrap.tar.gz ready ($(du -h "$PI_BOOTSTRAP_TAR" | awk '{print $1}'))"

# Skip upload + install if Pi is already in place.
if ! "$OSH" sandbox exec -n "$SANDBOX" --no-tty -- \
     /bin/sh -c 'test -x /sandbox/node_modules/.bin/pi' 2>/dev/null; then
  # ⚠️ `openshell sandbox upload` SILENTLY DROPS large binaries: the ~24MB tar
  # lands NOWHERE despite "✓ Upload complete" (it exceeds the gateway's gRPC
  # message cap, ~4MB). Small files upload fine. This was the long-standing
  # "tar: Child returned status 2 / tar extract failed" bug. FIX: split into
  # sub-cap chunks, upload each, reassemble + SHA-VERIFY inside (a dropped chunk
  # fails loudly instead of producing a corrupt tar), then extract.
  log "Uploading pi-bootstrap.tar.gz in 3MB chunks → $SANDBOX:/sandbox/ (upload caps at ~4MB)..."
  HOST_SHA="$(shasum -a 256 "$PI_BOOTSTRAP_TAR" | awk '{print $1}')"
  CHUNK_DIR="$(mktemp -d)"
  split -b 3000000 "$PI_BOOTSTRAP_TAR" "$CHUNK_DIR/pibt.part."
  "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
    /bin/sh -c 'rm -f /sandbox/pibt.part.* /sandbox/pi-bootstrap.tar.gz 2>/dev/null; true' >/dev/null 2>&1 || true
  for part in "$CHUNK_DIR"/pibt.part.*; do
    "$OSH" sandbox upload "$SANDBOX" "$part" /sandbox/ >/dev/null 2>&1 \
      || { err "chunk upload failed ($(basename "$part"))"; rm -rf "$CHUNK_DIR"; exit 1; }
  done
  rm -rf "$CHUNK_DIR"
  # Reassemble (sorted) + SHA-verify against the host BEFORE trusting it.
  SBX_SHA="$("$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 90 -- \
    bash -c 'cat $(ls -1 /sandbox/pibt.part.* | sort) > /sandbox/pi-bootstrap.tar.gz && rm -f /sandbox/pibt.part.* && sha256sum /sandbox/pi-bootstrap.tar.gz | awk "{print \$1}"' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  if [[ "$SBX_SHA" != "$HOST_SHA" ]]; then
    err "reassembled tar SHA mismatch (host=$HOST_SHA sandbox=${SBX_SHA:-none}) — chunk upload corrupted"; exit 1
  fi
  ok "tar reassembled + SHA-verified in sandbox"
  "$OSH" sandbox exec -n "$SANDBOX" --workdir /sandbox --no-tty --timeout 120 -- \
    tar xzf pi-bootstrap.tar.gz 2>&1 | tail -3 \
    || { err "tar extract failed inside sandbox"; exit 1; }
  "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
    /bin/sh -c 'test -x /sandbox/node_modules/.bin/pi' \
    || { err "pi binary missing after extract"; exit 1; }
  ok "Pi installed at /sandbox/node_modules/.bin/pi"
else
  ok "Pi already installed in $SANDBOX"
fi

# --- Drop the Pi extension that routes to inference.local -----------------
log "Installing Pi extension (inference-local.ts)..."
"$OSH" sandbox exec -n "$SANDBOX" --no-tty -- \
  /bin/sh -c 'mkdir -p /sandbox/.pi/extensions' 2>&1 | tail -3 || true
"$OSH" sandbox upload "$SANDBOX" "$PI_EXT_SRC" /sandbox/.pi/extensions/ 2>&1 | tail -3 \
  || { err "extension upload failed"; exit 1; }
ok "extension at /sandbox/.pi/extensions/inference-local.ts"

# --- Honcho peer for Pi (best-effort; non-fatal) --------------------------
# Pi writes to its own peer namespace so its memory is namespace-isolated
# from the Hermes fleet's peers. NOTE: Honcho v3 has no API-key-scoped
# peer-access enforcement — a compromised/injected Pi could still query
# other peer IDs. The isolation here is by namespace convention, not by
# hard authorization. See openshell/policies/pi-v1.yaml comments.
source "$AI_STACK/installer/lib/honcho.sh" 2>/dev/null || true
if type honcho_peer_ensure >/dev/null 2>&1; then
  log "Ensuring Honcho peer '$PI_PEER_ID' exists in workspace '$(honcho_workspace_id)'..."
  if honcho_peer_ensure "$PI_PEER_ID"; then
    ok "Honcho peer '$PI_PEER_ID' present (created or already existed)"
  else
    warn "Honcho peer ensure returned non-zero (non-fatal; Pi can create on first call)"
  fi
fi

# --- Smoke test: Pi → LiteLLM via virtual key -----------------------------
PI_KEY_FOR_PROBE="$(get_env PI_LITELLM_KEY '')"
log "Smoke-test: curl http://host.docker.internal:4000/v1/models with PI_LITELLM_KEY from inside sandbox..."
PROBE_OUT="$("$OSH" sandbox exec -n "$SANDBOX" --no-tty -- \
   curl -s --max-time 5 -H "Authorization: Bearer $PI_KEY_FOR_PROBE" -o /dev/null \
   -w '%{http_code}' http://host.docker.internal:4000/v1/models 2>/dev/null || echo 000)"
case "$PROBE_OUT" in
  200) ok "LiteLLM reachable via virtual key (HTTP 200, models allowlisted)" ;;
  000) warn "LiteLLM unreachable from sandbox — check policy ($POLICY) + LiteLLM dual-bind" ;;
  *)   warn "LiteLLM probe returned HTTP $PROBE_OUT (expected 200)" ;;
esac

# Pi version comes from the pinned dependency in pi/package.json (the install
# uses pi-bootstrap.tar.gz, not a versioned .tgz — the old $PI_TGZ_BASE var was
# never set and tripped `set -u` on this line). CHANGELOG 2026-05-30.
PI_VERSION="$(sed -nE 's/.*"@earendil-works\/pi-coding-agent":[[:space:]]*"([0-9.]+)".*/\1/p' "$PI_DIR/package.json" 2>/dev/null | head -1)"
stamp_mark "$PHASE"
record "phase 15 complete: pi v${PI_VERSION:-unknown} in $SANDBOX, inference.local→litellm/local-heavy, honcho peer=$PI_PEER_ID"
ok "Phase 15 — Pi — complete"
note "Run:    bin/pi    (launches Pi TUI inside $SANDBOX)"
note "Kill:   bin/pi-kill"
note "Shell:  openshell sandbox connect $SANDBOX   (full sandbox shell)"
note "Models: \`pi --model local | local-heavy | local-lfm2\` (local-only; no cloud)"
