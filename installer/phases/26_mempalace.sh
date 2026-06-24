#!/usr/bin/env bash
# Phase 26 — MemPalace (local-first conversation memory).
#
# MemPalace (github.com/MemPalace/mempalace, MIT) stores conversation history
# VERBATIM (no lossy summarization) and retrieves it via local semantic search.
# Memory is organized spatially: people/projects = "wings", topics = "rooms",
# raw content = "drawers", plus a temporal entity-relationship knowledge graph
# (SQLite). It exposes a CLI, a Python library, an MCP server (29 tools), and
# Claude Code auto-save hooks.
#
# Why it earns its own phase (vs. the existing memory layers):
#   - Honcho (Phase 03) DERIVES/summarizes cross-agent facts (lossy by design,
#     server-backed). MemPalace stores conversations VERBATIM and is local-first.
#   - Qdrant (Phase 02) indexes DOCUMENTS; Lumen (Phase 16) indexes CODE.
#     MemPalace's sweet spot is CONVERSATION memory — specifically closing the
#     gap that today only `.remember/` + the curated auto-memory cover: there is
#     no automatic, verbatim, semantically-searchable recall over past Claude
#     Code sessions. MemPalace's Stop/PreCompact hooks provide exactly that.
#
# How this phase honors the stack constitution:
#   - NO CLOUD EMBEDDINGS: embeddings are local ONNX (embedding-gemma-300m),
#     run on-device via CoreML (Apple Neural Engine on the M4). Nothing leaves
#     the machine. We do NOT route embeddings through LiteLLM — that would add
#     a hop and lose ANE acceleration for zero compliance gain.
#   - LiteLLM-routed LLM: the OPTIONAL entity-refinement / `--extract general`
#     LLM calls go through LiteLLM (openai-compat provider) via a scoped virtual
#     key, so they appear in Phoenix project ai-stack for free.
#   - INSTALL is PyPI-only (avoid the known malware-squatting domain
#     mempalace.tech — see SECURITY note upstream). uv tool install pins to the
#     PyPI artifact.
#   - The Claude Code HOOK WIRING is NOT done here (it changes live harness
#     behavior). It is an explicit, reversible opt-in: `bin/mempalace-hooks`.
#
# What this phase does (idempotent):
#   1. `uv tool install --upgrade mempalace` (PyPI).
#   2. Mint a LiteLLM virtual key (MEMPALACE_LITELLM_KEY) scoped to local models
#      (mirrors Phase 15/17 pattern).
#   3. Resolve the bound LLM model (availability-gated; default claude-opus-sub-xhigh).
#   4. Write bin/mempalace wrapper: exports the LiteLLM + on-device-embedding env
#      (key read from .env at runtime — never embedded) then execs the tool.
#   5. Bootstrap the palace: `mempalace init <AI_STACK> --yes --no-llm` (offline,
#      heuristics-only, fast) if ~/.mempalace/config.json is absent.
#   6. Generate bin/mempalace-hook-{save,precompact} launchers (PATH + env fix)
#      used by the opt-in `bin/mempalace-hooks` wiring.
#   7. Smoke: `bin/mempalace --help` exits 0. (We do NOT auto-backfill the full
#      ~/.claude/projects history — that can be large/long; it is a printed
#      opt-in note so we never leave a long-running task behind.)
#
# Standalone install: `bash vz-ai-stack.sh install 26`  (alias: mempalace)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PHASE=26
MP_WRAPPER="$AI_STACK/bin/mempalace"
MP_HOOK_SAVE="$AI_STACK/bin/mempalace-hook-save"
MP_HOOK_PRECOMPACT="$AI_STACK/bin/mempalace-hook-precompact"
MP_VENDORED_HOOKS="$AI_STACK/mempalace/hooks"
MP_CONFIG_DIR="$HOME/.mempalace"
MP_CONFIG_FILE="$MP_CONFIG_DIR/config.json"
# On-device embeddings. Default = minilm (all-MiniLM-L6-v2, 384-dim, English,
# ~80MB ONNX) — small, fast, and verified working on this box. embeddinggemma
# (multilingual, ~300MB) is opt-in via MEMPALACE_EMBEDDING_MODEL=embeddinggemma
# but its EF can silently fall back to minilm if its model can't be fetched, so
# we don't default to it. First mine downloads the model once (retry if the
# download times out — it is resumable on re-run).
MP_EMBED_MODEL="${MEMPALACE_EMBEDDING_MODEL:-minilm}"
# DURABLE: when MEMPALACE_EMBEDDING_MODEL isn't set in the env, read the `served`
# token of the embedder assigned to `mempalace` in installer/models.yml (set via
# `vz-ai-stack.sh embedding assign mempalace <model>`) so a re-install honors a
# re-point. For the on-device embedders `served` IS the exact MemPalace token
# (minilm / embeddinggemma) — not the HF name — so it's handed through verbatim,
# the same idiom as docs/openwebui/lumen. The `${...:-minilm}` above stays the
# fallback; the `as $k` guard makes a missing assignments/embeddings section
# resolve to "" (a bare index-by-null returns ALL values), so a missing section
# never breaks the phase. An explicit env var still wins over models.yml.
if [[ -z "${MEMPALACE_EMBEDDING_MODEL:-}" ]] \
   && [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _me="$(yq -r '(.embedding_assignments.mempalace // "") as $k | .embeddings[$k].served // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_me" && "$_me" != "null" ]] && MP_EMBED_MODEL="$_me"
fi
MP_EMBED_DEVICE="${MEMPALACE_EMBEDDING_DEVICE:-coreml}"   # Apple Neural Engine on M4

# Resolve the RAW uv-installed mempalace tool — NEVER the bin/mempalace wrapper.
# ~/ai-stack/bin can precede ~/.local/bin on PATH, so `command -v mempalace` may return
# the WRAPPER ($MP_WRAPPER); running it for a simple --version self-execs the wrapper
# into an infinite loop (this hung Phase 26 / install all). Prefer the uv tool path;
# fall back to a PATH lookup that excludes the wrapper.
mp_bin() {
  local b="$HOME/.local/bin/mempalace"
  if [[ ! -x "$b" ]]; then
    b="$(command -v mempalace 2>/dev/null || true)"
    [[ -n "$b" && ! "$b" -ef "$MP_WRAPPER" ]] || b="$HOME/.local/bin/mempalace"
  fi
  printf '%s' "$b"
}

# Run a command with a hard timeout (macOS lacks coreutils `timeout`). rc 142 on deadline.
_bounded() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

precheck() {
  [[ -x "$(mp_bin)" ]] || command -v mempalace >/dev/null 2>&1 || return 1
  [[ -x "$MP_WRAPPER" ]] || return 1
  [[ -x "$MP_HOOK_SAVE" && -x "$MP_HOOK_PRECOMPACT" ]] || return 1
  [[ -f "$MP_CONFIG_FILE" ]] || return 1
  local key; key="$(get_env MEMPALACE_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  curl -sf --max-time 5 -H "Authorization: Bearer $key" \
    http://litellm:4000/v1/models >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 26 — MemPalace — already installed (use 'vz-ai-stack.sh install 26' to re-run)"
  exit 0
fi

hdr "Phase 26 — MemPalace (local-first conversation memory)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || {
  err "uv not on PATH. uv is installed by Phase 14 (Unsloth). Run:"
  err "  bash $AI_STACK/vz-ai-stack.sh install 14"
  exit 1
}
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }

LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }

if ! curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1 \
   && ! curl -sf --max-time 3 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        http://litellm:4000/v1/models >/dev/null 2>&1; then
  err "LiteLLM not reachable at http://litellm:4000 — run 'stack start litellm'."
  exit 1
fi

[[ -d "$MP_VENDORED_HOOKS" ]] || { err "vendored hooks missing at $MP_VENDORED_HOOKS — repo incomplete."; exit 1; }

# --- 1. Install MemPalace from PyPI (NOT mempalace.tech — malware squat) ---
log "Installing mempalace via uv tool (PyPI)..."
uv tool install --upgrade mempalace 2>&1 | tail -5 || { err "uv tool install mempalace failed"; exit 1; }
MP_BIN="$(mp_bin)"
[[ -x "$MP_BIN" ]] || command -v mempalace >/dev/null 2>&1 || { err "mempalace not on PATH after install (expected ~/.local/bin/mempalace)"; exit 1; }
MP_BIN="$(mp_bin)"
ok "mempalace installed: $("$MP_BIN" --version 2>/dev/null | head -1 || echo '(version unknown)')"

# --- 2. Mint LiteLLM virtual key (mirrors Phase 17) ---
MP_KEY_CURRENT="$(get_env MEMPALACE_LITELLM_KEY '')"
# Re-mint if the key is missing OR can't actually list models. A stale/revoked key
# still returns HTTP 200 with an empty {"data":[]} (e.g. after a LiteLLM key-store
# DB recreate), so we require a real model entry ("id") in the response — not just
# a 2xx — else the guard passes on a dead key and MemPalace can call nothing
# (council SRE C-1/C-2). NOTE: `model sync` does NOT widen this key (MemPalace is
# not in models.yml `kinds:`), so this phase is the only thing that re-mints it.
_mp_models="$(curl -s --max-time 5 -H "Authorization: Bearer $MP_KEY_CURRENT" http://litellm:4000/v1/models 2>/dev/null)"
if [[ -z "$MP_KEY_CURRENT" ]] || ! printf '%s' "$_mp_models" | grep -q '"id"'; then
  log "Minting LiteLLM virtual key for MemPalace (claude-opus-sub-xhigh + local-gemma4 fallback)..."
  MP_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate \
    -d '{"models":["claude-opus-sub-xhigh","local-gemma4"],"key_alias":"mempalace-memory","metadata":{"owner":"mempalace","purpose":"phase26"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$MP_KEY_NEW" ]] || { err "Failed to mint MEMPALACE_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env MEMPALACE_LITELLM_KEY "$MP_KEY_NEW"
  ok "MEMPALACE_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "MEMPALACE_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (availability-gated; default claude-opus-sub-xhigh) ---
# MemPalace's LLM is OPTIONAL (entity refinement / --extract general). Platform
# policy (2026-06-20): default to claude-opus-sub-xhigh (Claude subscription
# via Meridian; LiteLLM falls back to local-gemma4 if Meridian is down). If
# models.yml binds an lmstudio slug that isn't up, gate to `.primary` so a cold
# install never pins MemPalace to an unreachable model.
MP_MODEL="claude-opus-sub-xhigh"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _mm="$(yq -r '.assignments.mempalace // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  if [[ -n "$_mm" && "$_mm" != "null" ]]; then
    _mrt="$(yq -r ".models.\"$_mm\".runtime" "$AI_STACK/installer/models.yml" 2>/dev/null)"
    if [[ "$_mrt" == "lmstudio" ]] \
       && ! { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null \
              && grep -qF "model_name: ${_mm}" "$AI_STACK/litellm/config.yaml" 2>/dev/null; }; then
      MP_MODEL="$(yq -r '.primary' "$AI_STACK/installer/models.yml" 2>/dev/null)"
    else
      MP_MODEL="$_mm"
    fi
  fi
fi
ok "MemPalace LLM model (entity refinement) = $MP_MODEL (embeddings stay on-device: $MP_EMBED_MODEL/$MP_EMBED_DEVICE)"

# --- 3b. Reconcile the key's allow-list to the bound model (self-heal rename drift) ---
# Step 2's mint hardcodes the default pair AND its liveness guard only proves the key
# can list *some* model — so a stale key that still allows the local-gemma4 fallback
# passes the guard and is never re-minted. After a model RENAME (e.g. version-less
# alias cutover) the wrapper calls $MP_MODEL while the key still allows only the OLD
# alias -> a SILENT 403 that every health gate misses (`model sync` never touches this
# key). Idempotently widen the key to {$MP_MODEL, local-gemma4} via /key/update: same
# key string (no .env churn, no wrapper restart), and a no-op when already correct.
MP_KEY_NOW="$(get_env MEMPALACE_LITELLM_KEY '')"
if [[ -n "$MP_KEY_NOW" ]]; then
  # Inspect the key's LIVE allow-list. Emit "__wildcard__" when the key is
  # unrestricted (LiteLLM all-proxy/all-team sentinels) so a broad key is never
  # NARROWED; otherwise emit one allowed model per line. A down/garbled LiteLLM
  # yields an empty string (curl/parse errors swallowed) -> reconcile attempts a
  # widen and degrades to warn (never aborts the phase).
  _mp_allowed="$(curl -s --max-time 5 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    "http://litellm:4000/key/info?key=$MP_KEY_NOW" 2>/dev/null \
    | python3 -c 'import sys,json
try: m=((json.load(sys.stdin).get("info") or {}).get("models")) or []
except Exception: m=[]
print("__wildcard__" if any(x in ("all-proxy-models","all-team-models") for x in m) else "\n".join(m))' 2>/dev/null)"
  if printf '%s\n' "$_mp_allowed" | grep -qxF '__wildcard__'; then
    : # key is unrestricted — already covers $MP_MODEL, leave it alone
  elif ! printf '%s\n' "$_mp_allowed" | grep -qxF "$MP_MODEL"; then
    log "Reconciling MemPalace key allow-list -> {$MP_MODEL, local-gemma4} (model-rename drift)…"
    # Build the body with json.dumps (no shell-injection of $MP_MODEL/$key into
    # the JSON) and detect success via the response body's "error" field — a 200
    # with an error payload must NOT report success (mirrors lib/models.sh remint_key).
    _mp_body="$(MP_K="$MP_KEY_NOW" MP_M="$MP_MODEL" python3 -c 'import json,os
print(json.dumps({"key":os.environ["MP_K"],"models":[os.environ["MP_M"],"local-gemma4"]}))')"
    _mp_resp="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
      -H 'Content-Type: application/json' -X POST http://litellm:4000/key/update \
      -d "$_mp_body" 2>/dev/null)"
    if printf '%s' "$_mp_resp" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(1 if "error" in d else 0)' 2>/dev/null; then
      ok "MemPalace key allow-list set to {$MP_MODEL, local-gemma4}"
    else
      warn "Could not reconcile MemPalace key allow-list (LiteLLM /key/update failed) — $MP_MODEL calls may 403"
    fi
  fi
fi

# --- 4. bin/mempalace wrapper (injects LiteLLM + embedding env) ---
cat > "$MP_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/mempalace — stack wrapper around the uv-installed mempalace.
# Generated by installer/phases/26_mempalace.sh — re-run 'install 26' to refresh.
#
# Injects:
#   * On-device embeddings (no cloud, no LiteLLM hop): MEMPALACE_EMBEDDING_*.
#   * LiteLLM routing for the OPTIONAL entity-refinement LLM: the openai-compat
#     provider env (OPENAI_*) + closet_llm env (LLM_*). Key is read from .env at
#     RUNTIME (never baked into this file).
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
_mp_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
# Resolve the RAW uv tool, NEVER this wrapper: ~/ai-stack/bin may precede ~/.local/bin
# on PATH, so 'command -v mempalace' can return THIS script and exec'ing it would
# self-recurse into a hang. Prefer the uv path; exclude self.
MP_BIN="\$HOME/.local/bin/mempalace"
if [[ ! -x "\$MP_BIN" || "\$MP_BIN" -ef "\${BASH_SOURCE[0]}" ]]; then
  MP_BIN="\$(command -v mempalace 2>/dev/null || true)"
fi
[[ -n "\$MP_BIN" && -x "\$MP_BIN" && ! "\$MP_BIN" -ef "\${BASH_SOURCE[0]}" ]] || { echo "mempalace tool not found (only the wrapper is on PATH) — run 'bash vz-ai-stack.sh install 26'" >&2; exit 1; }

_key="\$(_mp_get_env MEMPALACE_LITELLM_KEY)"
export MEMPALACE_EMBEDDING_MODEL="\${MEMPALACE_EMBEDDING_MODEL:-$MP_EMBED_MODEL}"
export MEMPALACE_EMBEDDING_DEVICE="\${MEMPALACE_EMBEDDING_DEVICE:-$MP_EMBED_DEVICE}"
# LiteLLM-routed LLM (openai-compat + closet_llm env contracts):
export OPENAI_BASE_URL="\${OPENAI_BASE_URL:-http://litellm:4000/v1}"
export OPENAI_API_KEY="\${OPENAI_API_KEY:-\$_key}"
export LLM_ENDPOINT="\${LLM_ENDPOINT:-http://litellm:4000/v1}"
export LLM_KEY="\${LLM_KEY:-\$_key}"
export LLM_MODEL="\${LLM_MODEL:-$MP_MODEL}"
exec "\$MP_BIN" "\$@"
WRAPEOF
chmod +x "$MP_WRAPPER"
ok "wrote $MP_WRAPPER"

# --- 5. Bootstrap the palace (offline, heuristics-only) ---
# Init against a NEUTRAL seed dir, never the repo: `mempalace init <dir>` drops
# mempalace.yaml + entities.json into <dir> and edits its .gitignore, so pointing
# it at $AI_STACK would pollute the working tree. The real corpus is mined later
# (`mine ~/.claude/projects` / the hooks); init here just creates ~/.mempalace.
MP_SEED_DIR="$MP_CONFIG_DIR/stack-seed"
if [[ ! -f "$MP_CONFIG_FILE" ]]; then
  log "Bootstrapping palace (mempalace init, offline heuristics-only)..."
  mkdir -p "$MP_SEED_DIR"
  [[ -f "$MP_SEED_DIR/README.md" ]] || cat > "$MP_SEED_DIR/README.md" <<'SEEDEOF'
# MemPalace seed

Neutral directory used by `vz-ai-stack.sh install 26` to bootstrap the palace
config (~/.mempalace) without treating the ai-stack repo as a mined corpus.
The real memory comes from `bin/mempalace mine ~/.claude/projects --mode convos`
and the opt-in Stop/PreCompact hooks. Safe to leave empty.
SEEDEOF
  # --no-llm keeps init offline + non-interactive; </dev/null declines the
  # post-init "mine now?" prompt. Entity refinement at mine time uses the
  # LiteLLM env from the wrapper. The palace store lives at ~/.mempalace/palace.
  _bounded 90 "$MP_WRAPPER" init "$MP_SEED_DIR" --yes --no-llm </dev/null 2>&1 | tail -8 \
    || warn "mempalace init did not finish in 90s or reported issues (a first-run embedding-model fetch may be proxy-blocked) — palace may still be usable; re-run 'install 26' when network allows"
fi
if [[ -f "$MP_CONFIG_FILE" ]]; then
  chmod 0700 "$MP_CONFIG_DIR" 2>/dev/null || true
  chmod 0600 "$MP_CONFIG_FILE" 2>/dev/null || true
  ok "palace config present: $MP_CONFIG_FILE"
else
  warn "palace config not created at $MP_CONFIG_FILE — 'bin/mempalace init <dir> --yes' to bootstrap"
fi

# --- 6. Hook launchers (PATH + env fix for GUI/launchd-spawned Claude Code) ---
# The vendored upstream hooks call bare `mempalace mine`; GUI-launched Claude
# Code may not have ~/.local/bin on PATH. These launchers fix PATH + inject the
# same env as bin/mempalace, then exec the vendored script. Wired into Claude
# Code only via the opt-in `bin/mempalace-hooks` (never automatically).
for _pair in "save:$MP_HOOK_SAVE" "precompact:$MP_HOOK_PRECOMPACT"; do
  _action="${_pair%%:*}"; _path="${_pair##*:}"
  cat > "$_path" <<LAUNCHEOF
#!/usr/bin/env bash
# bin/mempalace-hook-$_action — env/PATH shim for the vendored upstream
# mempal_${_action}_hook.sh. Generated by Phase 26. Wired via bin/mempalace-hooks.
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
_mp_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
export PATH="\$HOME/.local/bin:\$PATH"
_key="\$(_mp_get_env MEMPALACE_LITELLM_KEY)"
export MEMPALACE_EMBEDDING_MODEL="\${MEMPALACE_EMBEDDING_MODEL:-$MP_EMBED_MODEL}"
export MEMPALACE_EMBEDDING_DEVICE="\${MEMPALACE_EMBEDDING_DEVICE:-$MP_EMBED_DEVICE}"
export OPENAI_BASE_URL="http://litellm:4000/v1"
export OPENAI_API_KEY="\$_key"
export LLM_ENDPOINT="http://litellm:4000/v1"
export LLM_KEY="\$_key"
export LLM_MODEL="$MP_MODEL"
exec "\$AI_STACK/mempalace/hooks/mempal_${_action}_hook.sh" "\$@"
LAUNCHEOF
  chmod +x "$_path"
  ok "wrote $_path"
done

# --- 7. Smoke test (leaf-safe: bounded; a slow first-run embedding init must NOT hang
# or hard-fail this opt-in leaf — the tool itself was verified at step 1). ---
if _bounded 30 "$MP_WRAPPER" --help >/dev/null 2>&1; then
  ok "bin/mempalace --help: smoke-test passed"
else
  warn "bin/mempalace --help did not pass within 30s — tool is installed (version OK above) but the wrapper's first run was slow (embedding-model fetch may be proxy-blocked). Verify later: bin/mempalace --help"
fi

# Structural gate before stamping: the leaf-safe smoke can warn-and-continue on a slow
# first-run model fetch, but a genuinely missing/non-executable wrapper must NOT stamp.
[[ -x "$MP_WRAPPER" ]] || { err "bin/mempalace wrapper missing or not executable — phase will not stamp."; exit 1; }
stamp_mark "$PHASE"
record "phase 26 complete: MemPalace installed + virtual key + wrapper + palace + hook launchers"
ok "Phase 26 — MemPalace — complete"
note "Search:   bin/mempalace search 'what did we decide about the watchdog'"
note "Wake-up:  bin/mempalace wake-up           # ~600-900 token session primer"
note "Status:   bin/mempalace status"
note "Backfill your Claude Code history (LARGE/SLOW — run when ready, foreground):"
note "          bin/mempalace mine ~/.claude/projects --mode convos --extract general"
note "Auto-save (OPT-IN — edits Claude Code settings, reversible):"
note "          bin/mempalace-hooks install        # prints the settings block"
note "          bin/mempalace-hooks install --apply  # applies it (backup first)"
