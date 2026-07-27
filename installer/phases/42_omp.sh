#!/usr/bin/env bash
# Phase 42 — omp / oh-my-pi (OPT-IN; host terminal coding agent over the stack's LiteLLM).
#
# NOT in `install all` — a host coding agent is a deliberate opt-in
# (run: `mayssam-ai-stack.sh install omp`). What this phase does:
#   (a) Install the prebuilt binary — the `omp-darwin-arm64` GitHub-release asset
#       (can1357/oh-my-pi, LATEST release by default — operator directive 2026-07-27) into
#       $AI_STACK/omp/ (gitignored), sha256-verified FAIL-CLOSED against the release's
#       PUBLISHED digest before it is ever executed. No `curl | sh`, no `npm/bun -g`.
#   (b) LiteLLM wiring — mint a model-scoped virtual key (OMP_LITELLM_KEY, never the
#       master) + render the STACK-OWNED omp profile (~/.omp/profiles/ai-stack/agent/):
#       models.yml (single `litellm` provider, apiKey by ENV-NAME indirection — the literal
#       key never lands in the file) and config.yml (role pins + hardening, see SECURITY).
#   (c) bin/omp wrapper — exports OMP_PROFILE=ai-stack + the key from .env and execs the
#       verified binary. The operator's personal ~/.omp (if any) is NEVER touched: profiles
#       fully relocate omp state (docs/config-usage.md); rollback = rm -rf the profile dir.
#
# WHY omp: a hard fork of badlogic/pi-mono — the SAME upstream as the sandboxed phase-15
# `pi` — matured into a coding-first surface (sessions, subagents, LSP/DAP, extensions).
# It coexists cleanly with phase-15 pi: its own ~/.omp config universe, never reads ~/.pi.
# Phase-15 is untouched. Spec: doc/specs/2026-07-24-omp-integration.md (§24 council-amended;
# OpenWorker, the companion intake, was operator-DEFERRED — see the spec header).
#
# SECURITY (council-mandated, operator-approved):
#   - approvalMode `write` + an EXPLICIT `tools.approval.bash: prompt` policy — omp SHIPS
#     `yolo` (auto-approves EVERYTHING incl. exec; in yolo even omp's critical-destructive-
#     pattern guard does NOT force a prompt — upstream docs/approval-mode.md). KNOWN
#     BOUNDARY: a project-local <repo>/.omp/config.yml deep-merges OVER this profile and can
#     flip approvalMode back to yolo; the explicit bash policy still forces prompts in yolo
#     UNLESS the repo config overrides that key too. So: trusted repos only; doctor 84
#     carries the advisory.
#   - disabledProviders ollama/lm-studio/llama.cpp — omp auto-discovers direct :11434/:1234;
#     the single-hub rule says every model call goes through LiteLLM. Ollama IS available —
#     as the `local` route, via LiteLLM, explicitly selected (never a role default).
#   - startup.checkUpdate false + dev.autoqa false — no npm version phone-home, no
#     qa.omp.sh grievance push. The binary pin is bumped deliberately (see services.yml
#     upgrade block), never self-updated.
#   - Scoped-minimal key; registry-only reconcile ownership (scoped_key_registry — NOT
#     models.yml kinds; council: a kinds entry would double-own the allow-list).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"   # worktree_guard lives here (37_concordia precedent)

PHASE=42
NAME=omp
# Version policy (operator directive 2026-07-27): UNPINNED — resolve the NEWEST GitHub
# release at install/upgrade time ('mayssam-ai-stack.sh upgrade omp' moves to latest). Integrity
# stays FAIL-CLOSED: the download must match the release's PUBLISHED per-asset sha256
# digest (api.github.com), so we always install exactly what upstream shipped — the pin is
# dropped, the checksum never is. Escape hatch: OMP_VERSION=<x.y.z> + OMP_SHA256=<hex>
# pins again (BOTH required — an explicit version without its digest refuses).
OMP_REPO="can1357/oh-my-pi"
OMP_VERSION="$(get_env OMP_VERSION 'latest')"
OMP_SHA256="$(get_env OMP_SHA256 '')"
OMP_DIR="$AI_STACK/omp"
OMP_BIN="$OMP_DIR/omp-darwin-arm64"
OMP_PROFILE_NAME=ai-stack
OMP_AGENT_DIR="$HOME/.omp/profiles/$OMP_PROFILE_NAME/agent"
# Models the omp key may reach (curated — NOT master, NOT "all"). `local` is allow-listed
# for explicit selection (and the registry b0 invariant), but NO role defaults to it
# (operator directive 2026-07-24: default = claude-opus-sub-xhigh). Widen by editing this
# list + scoped_key_registry() + the registry test, then re-running 'install 42'.
OMP_KEY_MODELS='["claude-opus-sub-xhigh","claude-opus-sub-high","claude-sonnet-sub-high","local"]'
# In-phase completion gate runs the FAST sub route (never `local` — never-load-local rule;
# never the xhigh default — effort latency). Mirrors smoke/29+37 discipline.
OMP_GATE_MODEL="claude-sonnet-sub-high"

# _omp_installed_ver — the installed binary's bare version ('omp/17.1.2' → '17.1.2').
_omp_installed_ver() {
  "$OMP_BIN" --version 2>/dev/null | head -1 | sed -E 's/^[^0-9]*//; s/[[:space:]].*$//'
}

# _omp_resolve_target — sets OMP_TARGET_VER + OMP_TARGET_SHA (bare hex).
# latest → one bounded GitHub-API read (tag_name + the omp-darwin-arm64 asset's published
# digest); explicit OMP_VERSION → OMP_SHA256 required (the fail-closed pin escape hatch —
# hard-exits if absent, that's a config error not an availability blip).
# rc 1 = latest unresolved (API unreachable/rate-limited/parse) — caller decides hold vs abort.
OMP_TARGET_VER=""; OMP_TARGET_SHA=""
_omp_resolve_target() {
  if [[ "$OMP_VERSION" != "latest" ]]; then
    if [[ -z "$OMP_SHA256" ]]; then
      err "OMP_VERSION=$OMP_VERSION is set without OMP_SHA256 — an explicit version must pin its digest (fail-closed)"
      exit 1
    fi
    OMP_TARGET_VER="${OMP_VERSION#v}"; OMP_TARGET_SHA="$OMP_SHA256"; return 0
  fi
  local _out
  _out="$(curl -fsS --max-time 10 "https://api.github.com/repos/$OMP_REPO/releases/latest" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tag = (d.get("tag_name") or "").lstrip("v")
sha = ""
for a in d.get("assets") or []:
    if a.get("name") == "omp-darwin-arm64":
        sha = a.get("digest") or ""
        if sha.startswith("sha256:"):
            sha = sha[7:]
print(tag, sha)' 2>/dev/null)" || true
  OMP_TARGET_VER="${_out%% *}"; OMP_TARGET_SHA="${_out##* }"
  if [[ -z "$OMP_TARGET_VER" || -z "$OMP_TARGET_SHA" || "$OMP_TARGET_VER" == "$OMP_TARGET_SHA" ]]; then
    OMP_TARGET_VER=""; OMP_TARGET_SHA=""; return 1
  fi
  return 0
}

# Render the two profile configs to a temp dir; caller compares + installs (idempotent by
# CONTENT, not presence — a hardening/model edit above re-renders on the next install).
_omp_render_configs() { # $1 = destination dir for models.yml + config.yml
  local d="$1"
  cat > "$d/models.yml" <<'EOF'
# GENERATED by ai-stack Phase 42 — do not hand-edit (re-render: mayssam-ai-stack.sh install 42)
# Single provider = the stack's LiteLLM hub. apiKey is an ENV-VAR NAME (bin/omp exports it
# from .env at runtime) — the literal key is never written here. Discovery `litellm` probes
# the metadata routes and falls back to GET /models under a scoped key.
providers:
  litellm:
    name: ai-stack LiteLLM
    baseUrl: http://127.0.0.1:4000/v1
    apiKey: OMP_LITELLM_KEY
    api: openai-completions
    discovery:
      type: litellm
EOF
  cat > "$d/config.yml" <<'EOF'
# GENERATED by ai-stack Phase 42 — do not hand-edit (re-render: mayssam-ai-stack.sh install 42)
# Hardening posture (doctor check 84 asserts these): approvalMode `write` kills omp's
# shipped `yolo` default, and the explicit tools.approval.bash policy keeps bash PROMPTING
# even if a project-local config flips approvalMode to yolo (in yolo the critical-command
# guard alone does NOT prompt); disabledProviders kills implicit DIRECT-local discovery
# (Ollama is reachable as the `local` route via LiteLLM, explicitly selected); no phone-home.
modelRoles:
  default: litellm/claude-opus-sub-xhigh
  plan: litellm/claude-opus-sub-xhigh
  smol: litellm/claude-sonnet-sub-high
disabledProviders:
  - ollama
  - lm-studio
  - llama.cpp
tools:
  approvalMode: write
  approval:
    bash: prompt
startup:
  checkUpdate: false
dev:
  autoqa: false
EOF
}

_omp_configs_current() { # 0 iff both rendered configs byte-match the installed ones
  local tmp; tmp="$(mktemp -d)" || return 1
  _omp_render_configs "$tmp"
  local rc=0
  cmp -s "$tmp/models.yml" "$OMP_AGENT_DIR/models.yml" 2>/dev/null || rc=1
  cmp -s "$tmp/config.yml" "$OMP_AGENT_DIR/config.yml" 2>/dev/null || rc=1
  rm -rf "$tmp"
  return "$rc"
}

# --- precheck: working binary + wrapper + current configs + live scoped key → done -------
precheck() {
  # An explicit upgrade ALWAYS runs the body — latest-resolution + the visible
  # held/updated reporting live there (a precheck short-circuit would silently hold
  # updates forever, since the healthy-stack early-exit never reaches the resolver).
  [[ "${AI_STACK_UPGRADE:-0}" != "1" ]] || return 1
  [[ -x "$OMP_BIN" ]] || return 1
  "$OMP_BIN" --version >/dev/null 2>&1 || return 1
  [[ -x "$AI_STACK/bin/omp" ]] || return 1
  _omp_configs_current || return 1
  local key; key="$(get_env OMP_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  printf '%s' "$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" \
    | grep -q '"id"' || return 1
  # Allow-list drift gate: fail precheck so the phase re-runs + reconciles (control-plane
  # only; litellm_key_covers is wildcard-/unreachable-soft — a down gateway never re-runs).
  litellm_key_covers OMP_LITELLM_KEY "$OMP_KEY_MODELS" || return 1
  return 0
}
if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (omp $(_omp_installed_ver) installed, profile current, scoped key live)"
  exit 0
fi

worktree_guard "install omp"
hdr "Phase 42 — omp / oh-my-pi (opt-in host coding agent over LiteLLM)"

# --- Preconditions -----------------------------------------------------------------------
[[ "$(uname -s)/$(uname -m)" == "Darwin/arm64" ]] \
  || { err "phase 42 ships only the darwin-arm64 binary — this host is $(uname -s)/$(uname -m)"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
if ! curl -sf --max-time 3 http://litellm:4000/health/readiness >/dev/null 2>&1 \
   && ! curl -sf --max-time 3 http://127.0.0.1:4000/health/readiness >/dev/null 2>&1; then
  err "LiteLLM not reachable on :4000 — run 'mayssam-ai-stack.sh start litellm'."
  exit 1
fi

# --- 1. The binary (tracks the LATEST release; digest-verified FAIL-CLOSED) --------------
mkdir -p "$OMP_DIR"
_installed=""; [[ -x "$OMP_BIN" ]] && _installed="$(_omp_installed_ver)"
if _omp_resolve_target; then
  if [[ -n "$_installed" && "$_installed" == "$OMP_TARGET_VER" ]]; then
    ok "omp $_installed is current ($OMP_BIN)"
  else
    OMP_URL="https://github.com/$OMP_REPO/releases/download/v${OMP_TARGET_VER}/omp-darwin-arm64"
    if [[ -n "$_installed" ]]; then
      log "Upgrading omp $_installed → $OMP_TARGET_VER (~125MB, GitHub release; digest-verified)…"
    else
      log "Fetching omp-darwin-arm64 v$OMP_TARGET_VER (~125MB, GitHub release; digest-verified)…"
    fi
    _tmpbin="$(mktemp "$OMP_DIR/.omp-download.XXXXXX")"
    trap '[[ -n "${_tmpbin:-}" ]] && rm -f "$_tmpbin"' EXIT
    curl -fSL --max-time 600 -o "$_tmpbin" "$OMP_URL" \
      || { err "download failed ($OMP_URL)"; exit 1; }
    _got="$(shasum -a 256 "$_tmpbin" | awk '{print $1}')"
    [[ "$_got" == "$OMP_TARGET_SHA" ]] \
      || { err "sha256 MISMATCH for omp v$OMP_TARGET_VER — got $_got, upstream published $OMP_TARGET_SHA. Refusing to install an unverified binary."; exit 1; }
    chmod 755 "$_tmpbin"
    mv -f "$_tmpbin" "$OMP_BIN"; _tmpbin=""
    _v="$("$OMP_BIN" --version 2>/dev/null | head -1)" || true
    [[ -n "$_v" ]] || { err "installed omp does not run ('--version' produced nothing) — refusing to continue"; exit 1; }
    # Version-string echo is INFORMATIONAL under latest-tracking (the digest above is the
    # integrity gate): a cosmetic tag-vs---version format divergence must not wedge
    # upgrades un-stamped — warn, don't abort (council 2026-07-27).
    printf '%s' "$_v" | grep -qF "$OMP_TARGET_VER" \
      || warn "installed omp reports '$_v' while the release tag is v$OMP_TARGET_VER — cosmetic format divergence (digest already verified)"
    ok "omp binary installed + digest-verified: $_v ($OMP_BIN)"
  fi
else
  if [[ -n "$_installed" ]]; then
    warn "could not resolve the latest omp release (GitHub API unreachable/rate-limited) — keeping installed omp $_installed; re-run 'mayssam-ai-stack.sh upgrade omp' later"
  else
    err "cannot install omp: latest-release resolution failed and no binary is present (offline/pinned install: OMP_VERSION=<x.y.z> OMP_SHA256=<hex> mayssam-ai-stack.sh install 42)"
    exit 1
  fi
fi

# --- 2. Scoped LiteLLM virtual key (stale-aware mint + exact-set self-heal) --------------
OMP_KEY_CURRENT="$(get_env OMP_LITELLM_KEY '')"
# Guard the probe: litellm_scoped_curl FAIL-FASTS (return 1) on an empty key, and under
# set -e a failing $(…) assignment kills the phase silently — the first-install path always
# has an empty key here. (Phase 29's identical probe shares this latent bug; follow-up.)
_models_resp=""
if [[ -n "$OMP_KEY_CURRENT" ]]; then
  _models_resp="$(litellm_scoped_curl "$OMP_KEY_CURRENT" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
fi
if [[ -z "$OMP_KEY_CURRENT" ]] || ! printf '%s' "$_models_resp" | grep -q '"id"'; then
  log "Minting scoped LiteLLM virtual key for omp…"
  _gen_body="$(python3 -c 'import json,sys; print(json.dumps({"models":json.loads(sys.argv[1]),"key_alias":"omp","metadata":{"owner":"omp","purpose":"phase42"}}))' "$OMP_KEY_MODELS")"
  OMP_KEY_NEW="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
    -X POST http://127.0.0.1:4000/key/generate -d "$_gen_body" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$OMP_KEY_NEW" ]] || { err "Failed to mint OMP_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env OMP_LITELLM_KEY "$OMP_KEY_NEW"
  ok "OMP_LITELLM_KEY minted + saved to .env (0600)"
else
  ok "OMP_LITELLM_KEY already present + valid"
fi
# Self-heal the allow-list against catalog renames (model sync P3b converges this key EXACT
# via scoped_key_registry — the registry row MUST stay set-equal to OMP_KEY_MODELS above).
litellm_reconcile_key OMP_LITELLM_KEY "$OMP_KEY_MODELS"

# --- 3. Stack-owned profile configs (idempotent by content) ------------------------------
mkdir -p "$OMP_AGENT_DIR"
if _omp_configs_current; then
  ok "omp profile configs current ($OMP_AGENT_DIR)"
else
  log "Rendering omp profile configs (profile '$OMP_PROFILE_NAME')…"
  _tmpcfg="$(mktemp -d)"
  # By this point the download section's tmpfile trap is disarmed (_tmpbin=""), so
  # re-pointing the EXIT trap at the render dir is safe.
  trap '[[ -n "${_tmpcfg:-}" ]] && rm -rf "$_tmpcfg"' EXIT
  _omp_render_configs "$_tmpcfg"
  mv -f "$_tmpcfg/models.yml" "$OMP_AGENT_DIR/models.yml"
  mv -f "$_tmpcfg/config.yml" "$OMP_AGENT_DIR/config.yml"
  rm -rf "$_tmpcfg"; _tmpcfg=""
  ok "profile rendered: models.yml (litellm provider) + config.yml (roles + hardening)"
fi

# --- 4. bin/omp wrapper (regenerated every install — single source of truth is HERE) -----
cat > "$AI_STACK/bin/omp" <<'WRAP'
#!/usr/bin/env bash
# bin/omp — stack wrapper for oh-my-pi (Phase 42). Regenerate: mayssam-ai-stack.sh install 42.
# Runs the stack-managed omp binary under the STACK-OWNED profile (OMP_PROFILE=ai-stack) with the
# scoped LiteLLM key exported, so every model call routes through http://127.0.0.1:4000/v1.
# Your personal ~/.omp (if any) is untouched — profiles fully relocate omp state.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_omp_get_env() { grep -E "^$1=" "$AI_STACK/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
OMP_BIN="$AI_STACK/omp/omp-darwin-arm64"
[[ -x "$OMP_BIN" ]] || { echo "omp binary missing — run 'bash mayssam-ai-stack.sh install 42'" >&2; exit 1; }
_key="$(_omp_get_env OMP_LITELLM_KEY)"
[[ -n "$_key" ]] || { echo "OMP_LITELLM_KEY absent from .env — run 'bash mayssam-ai-stack.sh install 42'" >&2; exit 1; }
export OMP_LITELLM_KEY="$_key"
export OMP_PROFILE="${OMP_PROFILE:-ai-stack}"
exec "$OMP_BIN" "$@"
WRAP
chmod 755 "$AI_STACK/bin/omp"
ok "bin/omp wrapper written"

# --- 5. Gate (verify-then-stamp; leaf-safe, bounded) -------------------------------------
_gate_ok=1
"$OMP_BIN" --version >/dev/null 2>&1 || { err "gate: omp --version failed"; _gate_ok=0; }
[[ -f "$OMP_AGENT_DIR/models.yml" && -f "$OMP_AGENT_DIR/config.yml" ]] \
  || { err "gate: profile configs missing"; _gate_ok=0; }
_key="$(get_env OMP_LITELLM_KEY '')"
printf '%s' "$(litellm_scoped_curl "$_key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" \
  | grep -q '"id"' || { err "gate: scoped key lists no models"; _gate_ok=0; }
if [[ "${AI_STACK_UPGRADE:-0}" == "1" ]]; then
  note "gate: metered 1-token completion skipped under AI_STACK_UPGRADE=1 (wiring already asserted)"
elif (( _gate_ok )); then
  # Real 1-token completion through the scoped key — the actual omp→LiteLLM path's auth+
  # route, on the FAST SUB route (never `local`: never-load-local; council C5). Bounded.
  _resp="$(litellm_scoped_curl "$_key" -s --max-time 90 -H 'Content-Type: application/json' \
    -X POST http://127.0.0.1:4000/v1/chat/completions \
    -d "{\"model\":\"$OMP_GATE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" 2>/dev/null)"
  printf '%s' "$_resp" | grep -q '"choices"' \
    && ok "gate: 1-token completion on $OMP_GATE_MODEL via the scoped key" \
    || { err "gate: completion on $OMP_GATE_MODEL failed (resp: $(printf '%s' "$_resp" | head -c 160))"; _gate_ok=0; }
fi
(( _gate_ok )) || { err "Phase 42 gate failed — not stamping."; exit 1; }

stamp_mark "$PHASE"
record "phase 42 complete: omp $(_omp_installed_ver) (digest-verified, tracks latest) + scoped key + ai-stack profile rendered"
ok "Phase 42 — omp / oh-my-pi — complete"
note "Run:      bin/omp            (TUI in the current repo)   ·   bin/omp -p 'one-shot prompt'"
note "Models:   default=claude-opus-sub-xhigh · smol=claude-sonnet-sub-high · 'local' selectable, never a default"
note "Profile:  $OMP_AGENT_DIR   (stack-owned; your personal ~/.omp is untouched)"
note "Boundary: a repo's own .omp/config.yml can relax approvals past the stack hardening — run omp in TRUSTED repos only (doctor 84 carries this advisory)."
note "Version:  tracks the LATEST GitHub release — 'mayssam-ai-stack.sh upgrade omp' pulls the newest (digest-verified); pin anytime via OMP_VERSION=<x.y.z>+OMP_SHA256=<hex>"
note "Prove it: mayssam-ai-stack.sh test 42     ·   Manage: help omp | doctor omp"
note "Rollback: rm -rf $OMP_DIR ~/.omp/profiles/$OMP_PROFILE_NAME bin/omp installer/state/phase_42.done (the scoped key stays in .env — never rm .env keys)"
