#!/usr/bin/env bash
# Phase 00 — host preparation.
# Installs brew packages, creates the directory tree, writes a starter .env,
# verifies tooling, locks .env permissions, probes host.docker.internal.
#
# Idempotent: re-running on a fully-prepared host is a no-op + ✓ message.
set -Eeuo pipefail

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=00
precheck() {
  # What "done" looks like for phase 00:
  # - brew + all required formulae installed (bash 5+, yq, jq, node, pnpm, uv, git, tesseract, openssl, orbstack)
  # - directory tree exists
  # - .env exists, mode 0600, all required keys present (may be empty)
  # - host.docker.internal resolves from inside a container
  local missing=()
  for tool in bash yq jq node pnpm uv git tesseract openssl; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || return 1

  (( BASH_VERSINFO[0] >= 5 )) || return 1

  for d in bin litellm data data/phoenix data/falkor data/qdrant data/honcho data/openwebui \
           traces ingestor/inbox ingestor/processed guardrails openshell/policies tools \
           hermes-workspace ingestor autofyn deer-flow halo \
           installer/state; do
    [[ -d "$AI_STACK/$d" ]] || return 1
  done

  [[ -f "$AI_STACK/.env" ]] || return 1
  local perm; perm="$(stat -f '%Sp' "$AI_STACK/.env")"
  [[ "$perm" == "-rw-------" ]] || return 1

  load_env_strict >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (host prep)"
  exit 0
fi

hdr "Phase 00 — host preparation"

# --- brew + formulae ---
if ! command -v brew >/dev/null; then
  err "Homebrew is required. Install from https://brew.sh and re-run."
  exit 1
fi
log "Resolving brew formulae..."
# Per-formula install with graceful handling of pre-existing symlinks
# (e.g. a globally-installed npm pnpm that conflicts with brew pnpm).
# We use `brew list <name>` which exits 0 if installed, non-zero otherwise.
FORMULAE=(bash yq jq node@22 pnpm uv git tesseract openssl@3)
for f in "${FORMULAE[@]}"; do
  short="${f%@*}"
  if brew list "$short" >/dev/null 2>&1 || brew list "$f" >/dev/null 2>&1; then
    continue
  fi
  log "Installing: $f"
  if ! brew install "$f" 2>&1 | tail -5; then
    # Symlink conflicts are non-fatal — brew install usually exits non-zero
    # but the binary is in the cellar and reachable via `brew --prefix $f`/bin.
    warn "brew install $f exited non-zero (likely a symlink conflict). Continuing."
  fi
done
# Best-effort relink for node@22 (keg-only); ignore failures.
brew link --overwrite node@22 >/dev/null 2>&1 || true

# OrbStack is a cask, separate code path.
if ! brew list --cask 2>/dev/null | grep -qx orbstack; then
  log "Installing OrbStack (cask)..."
  brew install --cask orbstack
fi

if ! docker info >/dev/null 2>&1; then
  warn "Docker daemon not reachable. Launching OrbStack..."
  open -a OrbStack || true
  i=0
  until docker info >/dev/null 2>&1; do
    sleep 1
    (( ++i > 60 )) && { err "OrbStack didn't come up in 60s"; exit 1; }
  done
fi
ok "Docker daemon ready"

# --- Ollama host + origins (required for cross-container access) -----------
# Ollama defaults to binding 127.0.0.1 with an origin allowlist limited to
# localhost — so LiteLLM containers calling http://ollama:11434/api/chat
# via --add-host=ollama:host-gateway get 403 Forbidden. Set OLLAMA_HOST=0.0.0.0
# and OLLAMA_ORIGINS=* on the brew service so any in-stack container can
# reach it. Persist via the plist + launchctl setenv so daemons spawned
# later in this session also see the env.
OLLAMA_PLIST="$HOME/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
if command -v ollama >/dev/null && [[ -f "$OLLAMA_PLIST" ]]; then
  needs_restart=0
  for key in OLLAMA_HOST OLLAMA_ORIGINS; do
    if ! plutil -extract "EnvironmentVariables.$key" raw "$OLLAMA_PLIST" >/dev/null 2>&1; then
      needs_restart=1
    fi
  done
  if (( needs_restart )); then
    log "Patching $OLLAMA_PLIST with OLLAMA_HOST=0.0.0.0 + OLLAMA_ORIGINS=*..."
    # Use PlistBuddy (built-in on macOS); merge into existing EnvironmentVariables dict.
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OLLAMA_HOST string 0.0.0.0" "$OLLAMA_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OLLAMA_HOST 0.0.0.0" "$OLLAMA_PLIST"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:OLLAMA_ORIGINS string *" "$OLLAMA_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:OLLAMA_ORIGINS *" "$OLLAMA_PLIST"
    launchctl setenv OLLAMA_HOST "0.0.0.0"
    launchctl setenv OLLAMA_ORIGINS "*"
    brew services restart ollama 2>&1 | tail -2 || warn "brew services restart ollama failed"
    ok "patched + restarted ollama (OLLAMA_HOST=0.0.0.0, OLLAMA_ORIGINS=*)"
  fi
fi

# --- directory tree ---
log "Ensuring directory tree..."
mkdir -p "$AI_STACK"/{bin,litellm,data/phoenix,data/falkor,data/qdrant,data/honcho,data/openwebui,traces,ingestor/inbox,ingestor/processed,guardrails,openshell/policies,tools,hermes-workspace,ingestor,autofyn,deer-flow,halo,installer/state,CHANGELOG.d}

# --- .env starter ---
ensure_env_file
chmod 600 "$AI_STACK/.env"

declare -A DEFAULTS=(
  [ANTHROPIC_API_KEY]=""
  [OPENAI_API_KEY]=""
  [OPENROUTER_API_KEY]=""
  [GOOGLE_API_KEY]=""
  [PHOENIX_COLLECTOR_HTTP_ENDPOINT]="http://phoenix:6006/v1/traces"
  [PHOENIX_PROJECT_NAME]="ai-stack"
  [PHOENIX_API_KEY]=""
  [PHOENIX_SECRET]=""
  [BLAXEL_API_KEY]=""
  [BLAXEL_WORKSPACE]=""
  [GITHUB_TOKEN]=""
  [HONCHO_API_KEY]=""
  [HONCHO_BASE_URL]="http://honcho:8000"
  [LITELLM_BASE_URL]="http://litellm:4000"
  [QDRANT_URL]="http://qdrant:6333"
  [PHOENIX_BASE_URL]="http://phoenix:6006"
  [LITELLM_MASTER_KEY]=""
)
for key in "${!DEFAULTS[@]}"; do
  current="$(get_env "$key" "")"
  if [[ -z "$current" ]]; then
    if [[ -n "${DEFAULTS[$key]}" ]]; then
      set_env "$key" "${DEFAULTS[$key]}"
    fi
    continue
  fi
  # Safety Reviewer 1 F1/F2: migrate stale pre-refactor values that point
  # at host.docker.internal. The post-refactor design uses Docker DNS names
  # (e.g., http://phoenix:6006/v1/traces) and breaks if a stale value is
  # left in place from an older install. If the current value mentions
  # host.docker.internal but the new default doesn't, migrate.
  if [[ -n "${DEFAULTS[$key]}" \
        && "$current" == *host.docker.internal* \
        && "${DEFAULTS[$key]}" != *host.docker.internal* ]]; then
    warn "$key contains stale 'host.docker.internal' — migrating to '${DEFAULTS[$key]}'"
    set_env "$key" "${DEFAULTS[$key]}"
    queue_restart litellm   # affected consumers need to re-read
  fi
done
unset current

# Auto-generate LITELLM_MASTER_KEY once (so re-runs don't churn it).
if [[ -z "$(get_env LITELLM_MASTER_KEY "")" ]]; then
  set_env LITELLM_MASTER_KEY "sk-local-$(openssl rand -hex 16)"
  warn "Generated LITELLM_MASTER_KEY"
fi

# Auto-generate PHOENIX_SECRET if empty.
if [[ -z "$(get_env PHOENIX_SECRET "")" ]]; then
  set_env PHOENIX_SECRET "$(openssl rand -hex 32)"
  warn "Generated PHOENIX_SECRET (JWT signing key — NOT login password)"
fi

# --- host.docker.internal probe ---
log "Probing host.docker.internal from inside a container..."
if probe_host_docker_internal; then
  ok "host.docker.internal resolves"
else
  err "host.docker.internal probe FAILED — fix before continuing."
  exit 1
fi

# --- env strict validation ---
load_env_strict || { err ".env has malformed lines"; exit 1; }

stamp_mark "$PHASE"
record "phase 00 complete: brew formulae installed, dir tree present, .env initialized"
ok "Phase 00 — host preparation — complete"
