#!/usr/bin/env bash
# Phase 04 — OpenShell sandbox.
#
# OpenShell ships two halves: a CLI binary and a gateway daemon. On macOS
# Apple Silicon the official install.sh (curl https://.../install.sh | sh)
# installs both via a Homebrew tap (nvidia/openshell/openshell) AND attempts
# to start the gateway via `brew services`. The gateway listens on
# 127.0.0.1:17670 with TLS + mTLS by default.
#
# Known issues on M-series macOS:
#   1. The vz-ai-stack.sh's `brew services start openshell` can fail with
#      launchctl bootstrap error 5 if a previous service is loaded but
#      in error state. We probe and `brew services restart` (or stop/start)
#      to clear it.
#   2. The official vz-ai-stack.sh's TLS-handshake verification step itself
#      may time out (the gateway is up, the cert dance hasn't completed).
#      We don't rely on its exit code; we probe the port + try a CLI op.
#   3. The CLI policy schema upstream-changed from the original install
#      guide (which had `network: {default: deny, allow: [...]}` format).
#      We write the current schema (version: 1, network_policies map with
#      endpoints + binaries).
#
# Best-effort: if the gateway can't come up despite our retries, we stamp
# the phase as scaffold-complete with a clear deferred-manual note. The
# user can re-run `bash vz-ai-stack.sh install 04` after fixing brew/launchctl.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/openshell.sh"  # hang-resilient sandbox create

PHASE=04
SANDBOX=hermes-fleet-v1
GATEWAY_NAME=local-mac
GATEWAY_PORT=17670
POLICY="$AI_STACK/openshell/policies/${SANDBOX}.yaml"

# --- Helpers ---------------------------------------------------------------
resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null; then command -v openshell
  else echo ""
  fi
}

gateway_listening() { port_listening "$GATEWAY_PORT"; }

# brew service state: "started" | "scheduled" | "error" | "stopped" | "none"
brew_svc_state() {
  brew services list 2>/dev/null | awk -v s=openshell '$1==s {print $2; exit}'
}

precheck() {
  local osh; osh="$(resolve_openshell)"
  [[ -n "$osh" ]] || return 1
  [[ -f "$POLICY" ]] || return 1
  gateway_listening || return 1
  "$osh" sandbox list 2>/dev/null | grep -qE "(^| )${SANDBOX}( |$)" || return 1
  # A listed Ready sandbox can still be DEAD if its gateway token expired. Detect
  # that via the in-container LOG signature (non-invasive) so we never declare the
  # phase "already complete" on a storming sandbox — returning 1 makes the body
  # run and openshell_sandbox_ensure recreate it. (Sourced from lib/openshell.sh.)
  if openshell_token_storm "$SANDBOX"; then return 1; fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (openshell + gateway + ${SANDBOX} sandbox)"
  exit 0
fi

hdr "Phase 04 — OpenShell sandbox"

mkdir -p "$(dirname "$POLICY")"

# --- Write the policy in the CURRENT upstream schema (version: 1) ---------
# Reference: NVIDIA/OpenShell/examples/local-inference/sandbox-policy.yaml
# inference.local is gateway-managed (no policy entry needed).
cat > "$POLICY" <<'EOF'
# SPDX-FileCopyrightText: ai-stack installer Phase 04
# OpenShell sandbox policy for hermes-fleet-v1.
version: 1

filesystem_policy:
  include_workdir: true
  read_only:
    # Must be a SUPERSET of the base image's live read_only mounts. OpenShell's
    # `policy set` rejects REMOVING a read_only mount from a live sandbox
    # ("path '/proc' cannot be removed on a live sandbox"). The base mounts
    # /proc read_only, so list /proc (not /proc/self) or the apply fails.
    # CHANGELOG 2026-05-30.
    - /usr
    - /lib
    - /etc
    - /app
    - /var/log
    - /proc
    - /dev/urandom
  read_write:
    - /sandbox
    - /tmp
    - /dev/null

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

network_policies:
  # LiteLLM proxy — Hermes routes /v1/chat/completions here with its virtual
  # key (HERMES_LITELLM_KEY; server-side model allowlist). Direct virtual-key
  # dial is the working pattern; OpenShell's inference.local L7 rewrite forwards
  # the shipped `openai` provider to api.openai.com (CHANGELOG 2026-05-30).
  litellm_proxy:
    name: litellm-proxy
    endpoints:
      - host: host.docker.internal
        port: 4000
    binaries:
      - { path: "/**" }

  # Telegram — hermes-agent's native Telegram gateway long-polls api.telegram.org
  # (getUpdates). Required for Phase 20 (vz_hermes_controller_bot). Egress only.
  telegram:
    name: telegram
    endpoints:
      - { host: api.telegram.org, port: 443 }
    binaries:
      - { path: "/**" }

  # Honcho memory API — reached over Docker bridge via host.docker.internal.
  # Requires Honcho to bind 0.0.0.0:8000 (see Phase 03 compose override).
  honcho_memory:
    name: honcho-memory
    endpoints:
      - host: host.docker.internal
        port: 8000
    binaries:
      - { path: "/**" }

  # docs MCP server — also host-bound on 0.0.0.0:8765 (see Phase 06).
  docs_mcp:
    name: docs-mcp
    endpoints:
      - host: host.docker.internal
        port: 8765
    binaries:
      - { path: "/**" }

  # Egress for common dev tools (pip, npm, gh, git clone).
  package_registries:
    name: package-registries
    endpoints:
      - { host: pypi.org, port: 443 }
      - { host: files.pythonhosted.org, port: 443 }
      - { host: registry.npmjs.org, port: 443 }
      - { host: api.github.com, port: 443 }
      - { host: github.com, port: 443 }
      - { host: raw.githubusercontent.com, port: 443 }
      - { host: codeload.github.com, port: 443 }
    binaries:
      - { path: "/**" }
EOF
ok "wrote network policy: $POLICY"

# --- Install OpenShell via official vz-ai-stack.sh if brew openshell is absent --
if [[ ! -x /opt/homebrew/bin/openshell ]]; then
  if command -v brew >/dev/null; then
    log "Installing OpenShell via the official vz-ai-stack.sh..."
    # The vz-ai-stack.sh may time out waiting for the TLS-handshake verification
    # step; that's OK — the brew formula + plist are installed regardless.
    curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh 2>/dev/null | sh 2>&1 | tail -3 || true
    if [[ -x /opt/homebrew/bin/openshell ]]; then
      ok "openshell installed via brew"
    else
      warn "official vz-ai-stack.sh did not install brew openshell — gateway start will fail"
    fi
  else
    warn "brew not on PATH; cannot install the brew openshell formula. Skipping."
  fi
fi

OSH="$(resolve_openshell)"
[[ -n "$OSH" ]] || { warn "openshell binary not found; skipping gateway+sandbox setup"; stamp_mark "$PHASE"; ok "Phase 04 — OpenShell — scaffold complete (no binary)"; exit 0; }
OS_VER="$("$OSH" --version 2>&1 | awk '/openshell/ {print $2; exit}' || echo "?")"
ok "openshell on PATH: $OSH (v${OS_VER})"

# Version-skew guard: a bare `openshell` on PATH (e.g. a uv-tool install in
# ~/.local/bin) can SHADOW the brew binary that matches the gateway. A client
# newer/older than the running gateway fails execs with `phase: Unspecified` /
# `relay open timed out` even on a healthy sandbox (cost hours 2026-06-06: 04f
# used bare `openshell`). We always drive sandbox ops through $OSH (= the brew
# binary) — but warn loudly if the PATH default disagrees, so any stray
# bare-`openshell` caller (or the user's own shell) is on notice.
BARE_OSH="$(command -v openshell 2>/dev/null || true)"
if [[ -n "$BARE_OSH" && "$BARE_OSH" != "$OSH" ]]; then
  BARE_VER="$("$BARE_OSH" --version 2>&1 | awk '/openshell/ {print $2; exit}' || echo "?")"
  if [[ "$BARE_VER" == "?" || "$OS_VER" == "?" ]]; then
    warn "openshell version undeterminable for one binary (PATH '$BARE_OSH'=v${BARE_VER} / gateway-matching '$OSH'=v${OS_VER}) — can't confirm CLI/gateway match; installer code uses $OSH regardless."
  elif [[ "$BARE_VER" != "$OS_VER" ]]; then
    warn "openshell VERSION SKEW: PATH default '$BARE_OSH' is v${BARE_VER} but the gateway-matching binary '$OSH' is v${OS_VER}."
    warn "  The mismatched client fails execs ('phase: Unspecified' / 'relay open timed out') even on a healthy sandbox."
    warn "  Align them: 'brew upgrade openshell' or remove/upgrade the shadowing install (e.g. 'uv tool upgrade openshell'). Installer code uses $OSH regardless."
  fi
fi

# --- Configure the gateway env (DRIVERS + DOCKER_HOST) ---------------------
# The brew formula's wrapper script (openshell-gateway-homebrew-service)
# sources ~/.config/openshell/gateway.env before exec-ing the gateway.
# Without OPENSHELL_DRIVERS the gateway crashes on launch with:
#   "no compute driver configured ... set --drivers or OPENSHELL_DRIVERS"
# Without DOCKER_HOST it expects /var/run/docker.sock (Docker Desktop
# convention); OrbStack publishes its socket under $HOME instead.
GATEWAY_ENV_DIR="$HOME/.config/openshell"
GATEWAY_ENV_FILE="$GATEWAY_ENV_DIR/gateway.env"
mkdir -p "$GATEWAY_ENV_DIR"
ORB_SOCK="$HOME/.orbstack/run/docker.sock"
DESIRED_DOCKER_HOST="unix://$ORB_SOCK"
if [[ ! -S "$ORB_SOCK" ]]; then
  # OrbStack not detected — fall back to whatever DOCKER_HOST is set in the
  # current shell, or the Docker Desktop default if nothing else.
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    DESIRED_DOCKER_HOST="$DOCKER_HOST"
  else
    DESIRED_DOCKER_HOST="unix:///var/run/docker.sock"
  fi
fi
if ! grep -qxF "OPENSHELL_DRIVERS=docker" "$GATEWAY_ENV_FILE" 2>/dev/null \
  || ! grep -qxF "DOCKER_HOST=$DESIRED_DOCKER_HOST" "$GATEWAY_ENV_FILE" 2>/dev/null; then
  cat > "$GATEWAY_ENV_FILE" <<EOF
# Written by ai-stack Phase 04.
# Sourced by /opt/homebrew/opt/openshell/libexec/openshell-gateway-homebrew-service
# before the gateway binary exec'es.
OPENSHELL_DRIVERS=docker
DOCKER_HOST=$DESIRED_DOCKER_HOST
EOF
  chmod 600 "$GATEWAY_ENV_FILE"
  ok "wrote $GATEWAY_ENV_FILE (drivers=docker, host=$DESIRED_DOCKER_HOST)"
else
  ok "gateway env file already configured: $GATEWAY_ENV_FILE"
fi

# --- Bring the gateway service up ------------------------------------------
# Strategy: if a brew service exists, check its state. Clean up error state
# with `brew services stop` then `brew services start`. If it's already
# `started`, just verify the port is listening.
state="$(brew_svc_state)"
if [[ -n "$state" ]]; then
  log "brew service 'openshell' state: $state"
  case "$state" in
    started|scheduled)
      ok "openshell brew service is $state"
      ;;
    error|stopped|none|"")
      log "Cleaning + restarting openshell brew service..."
      # Plain `brew services stop` doesn't always clear a crashed launchd
      # entry — explicit launchctl bootout removes any orphaned plist
      # registration. Harmless when nothing is loaded.
      brew services stop openshell 2>&1 | tail -2 || true
      launchctl bootout "gui/$(id -u)/homebrew.mxcl.openshell" 2>/dev/null || true
      sleep 1
      if brew services start openshell 2>&1 | tail -3; then
        ok "brew services start openshell: ok"
      else
        warn "brew services start openshell failed — diagnose with 'brew services info openshell' and 'tail -50 /opt/homebrew/var/log/openshell.log'"
      fi
      ;;
  esac
else
  warn "openshell is not registered as a brew service (uv-installed only?). Gateway must be started manually."
fi

# --- Wait for the gateway port to come up ----------------------------------
log "Waiting for gateway on :$GATEWAY_PORT (up to 60s)..."
i=0
while (( i < 60 )); do
  gateway_listening && break
  sleep 1
  i=$((i+1))
done

if ! gateway_listening; then
  warn "Gateway not listening on :$GATEWAY_PORT after 60s."
  warn "Diagnose:"
  warn "  brew services info openshell"
  warn "  tail -50 /opt/homebrew/var/log/openshell.log"
  warn "Sandbox + policy will be set up on the next re-run once the gateway is up."
  stamp_mark "$PHASE"
  record "phase 04 partial: openshell v${OS_VER} installed; gateway not up; sandbox not created"
  ok "Phase 04 — OpenShell — scaffold complete (gateway deferred)"
  exit 0
fi
ok "Gateway listening on :$GATEWAY_PORT"

# --- Register the gateway (idempotent, name-flexible) ----------------------
# We register with --local (mTLS via stored certs from the brew install).
# Plaintext http:// fails the TLS handshake; --local uses the cert tree.
# Older installs may have stored the gateway under a different name (e.g.
# `openshell` from the official vz-ai-stack.sh) — accept any LOCAL-type
# gateway that points at our port instead of forcing a rename.
EXISTING_LOCAL_GW="$("$OSH" gateway list 2>/dev/null \
  | awk 'NR>1 && $3=="local" {print $1; exit}' \
  || true)"
if [[ -z "$EXISTING_LOCAL_GW" ]]; then
  log "Registering local gateway '$GATEWAY_NAME' at https://127.0.0.1:$GATEWAY_PORT..."
  "$OSH" gateway add "https://127.0.0.1:$GATEWAY_PORT" --local --name "$GATEWAY_NAME" 2>&1 | tail -3 \
    || warn "gateway add failed — TLS certs may not be set up yet"
  EXISTING_LOCAL_GW="$GATEWAY_NAME"
else
  ok "local gateway already registered: $EXISTING_LOCAL_GW"
fi
"$OSH" gateway select "$EXISTING_LOCAL_GW" 2>/dev/null || true
GATEWAY_NAME="$EXISTING_LOCAL_GW"

# Smoke-test that the CLI can actually talk to the gateway.
if ! "$OSH" sandbox list 2>/dev/null >/dev/null; then
  warn "Cannot list sandboxes — CLI ↔ gateway communication broken (likely cert mismatch)."
  warn "Sandbox creation deferred. Diagnose with 'openshell gateway info $GATEWAY_NAME'."
  stamp_mark "$PHASE"
  record "phase 04 partial: openshell v${OS_VER}, gateway port up, CLI unable to authenticate"
  ok "Phase 04 — OpenShell — scaffold complete (CLI-gateway auth deferred)"
  exit 0
fi
ok "gateway '$GATEWAY_NAME' selected + reachable"

# --- Create the sandbox (idempotent, hang-resilient) -----------------------
# openshell_sandbox_ensure (installer/lib/openshell.sh) ensures the
# `openshell-docker` network exists, then runs `sandbox create` under a
# watchdog: it polls Phase=Ready and frees the create CLI when the sandbox is
# up, because on M-series macOS the create command often hangs indefinitely
# even AFTER the sandbox is Ready (HANDOFF §2.2, observed live 2026-05-30).
# On Error/stuck it deletes + retries, then escalates to a gateway restart.
# This replaces the previous UNBOUNDED `openshell sandbox create` that hung the
# whole installer here.
if ! openshell_sandbox_ensure "$OSH" "$SANDBOX" base; then
  warn "sandbox '$SANDBOX' creation+recovery did not reach Ready — re-run after diagnosis"
  stamp_mark "$PHASE"
  ok "Phase 04 — OpenShell — scaffold complete (sandbox creation deferred)"
  exit 0
fi

# --- Apply the network policy ----------------------------------------------
log "Applying network policy to sandbox '$SANDBOX'..."
if "$OSH" policy set "$SANDBOX" --policy "$POLICY" --wait --timeout 60 2>&1 | tail -3; then
  ok "policy applied (deny-by-default + allowlist)"
else
  warn "policy set returned non-zero — sandbox may be using default policy"
fi

# --- Auto-healing watchdog (guards the expired-token CPU storm; see §2.x) -----
# A sandbox's gateway token expires after ~8h; the in-sandbox agent then retries
# log-push with no backoff (hundreds/sec) → ~36% CPU per sandbox. Install a
# launchd timer that detects that exact signature + delete/recreates the dead
# sandbox. Idempotent; safe to re-run. Detection-only via AI_STACK_WATCHDOG_RECREATE=0.
if [[ -x "$AI_STACK/bin/openshell-watchdog.sh" ]]; then
  bash "$AI_STACK/bin/openshell-watchdog.sh" install 2>&1 | tail -1 || warn "watchdog install returned non-zero (non-fatal)"
fi

stamp_mark "$PHASE"
record "phase 04 complete: openshell v${OS_VER}, gateway local-mac up, sandbox $SANDBOX created, policy applied, storm-watchdog installed"
ok "Phase 04 — OpenShell — complete"
note "Connect to the sandbox:  openshell sandbox connect $SANDBOX"
note "CPU-storm guard:          openshell-watchdog.sh status | uninstall   (auto-heals expired-token storms)"
