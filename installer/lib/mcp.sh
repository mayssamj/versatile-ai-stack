#!/usr/bin/env bash
# installer/lib/mcp.sh — MCP-server wiring for the Hermes fleet.
#
# Home for cross-phase MCP wiring helpers. Currently: wiring the OpenShell
# hermes-fleet-v1 sandbox to the local self-hosted Sourcegraph MCP server so
# every Hermes profile can search code. Sourced by BOTH:
#   - installer/phases/27_sourcegraph.sh  (wire an EXISTING fleet right after
#     deploying + bootstrapping Sourcegraph)
#   - installer/phases/04f_hermes_fleet.sh (wire on a FRESH fleet install)
# so the wiring is order-independent (install SG first OR the fleet first).
#
# Why a dedicated lib (not lib/openshell.sh or lib/fleet.sh): fleet.sh ends with
# `main "$@"` — sourcing it RUNS the fleet CLI (side effect); openshell.sh is
# sandbox-orchestration plumbing. MCP wiring is its own concern and will recur
# (future MCP servers), so it gets its own side-effect-free lib. (§24 council
# 2026-06-20: 3-of-4 reviewers; the dissent's only real objection — fleet.sh's
# `main` tail — does not apply to a brand-new file with no dispatch tail.)
#
# DESIGN NOTES (all EMPIRICALLY VERIFIED live 2026-06-20 against the running
# hermes-fleet-v1 sandbox + Sourcegraph 6.12.5040 — see CHANGELOG):
#   - Native streamable-HTTP works: `hermes-agent[mcp]==0.16.0` pulls mcp==1.26.0
#     which has mcp.client.streamable_http; Hermes 0.16's HTTP path returns all
#     12 SG tools. NO stdio bridge (mcp-remote) needed.
#   - Sourcegraph REQUIRES the `Authorization: token <TOK>` scheme (Bearer -> 401),
#     so the stanza header is `token ${VAR}`, NOT `hermes mcp add --auth header`
#     (which hard-codes `Bearer `).
#   - Hermes MCP config is PER-PROFILE (~/.hermes/profiles/<name>/{config.yaml,.env};
#     default profile = ~/.hermes; NOT inherited) -> we fan out per profile.
#   - `hermes config set` UPSERTS the nested map (idempotent — re-runs yield ONE
#     stanza) and stores the LITERAL `${MCP_SOURCEGRAPH_API_KEY}`, which Hermes
#     interpolates from that profile's .env at connect time. Token never in argv
#     or the log (STDIN-seeded into .env, mirroring the 04f api_key pattern).
#   - The mcp SDK adds the required `Accept: application/json, text/event-stream`
#     itself at runtime, so the stanza only needs url + Authorization +
#     connect_timeout. (`hermes mcp test` is BUGGY vs SG — bad Accept -> 400 — so
#     we NEVER use it as a verifier; the real keyword_search E2E is in smoke/27.sh.)
#   - connect_timeout=5 fails fast when SG is down (Hermes hard-codes read=300s).
#   - RELAY CONTENTION: rapid back-to-back `openshell sandbox exec` calls fail
#     transiently (verified: 50 rapid execs -> all-but-first profile failed; the
#     same calls succeed when spaced). So ALL per-profile wiring runs inside ONE
#     uploaded in-sandbox script via a SINGLE exec — ~3 relay opens, not ~50.
#
# Pin rationale (==0.16.0): matches the fleet's running Hermes (minimal-diff); the
# only side effect is a starlette 1.3.1->1.0.1 downgrade that affects ONLY the
# unused `hermes mcp serve` path.

[[ -n "${_AI_STACK_MCP_SH:-}" ]] && return 0
_AI_STACK_MCP_SH=1

SG_TOKEN_FILE="$HOME/.sourcegraph-local/sg-token"
SG_MCP_PIN="hermes-agent[mcp]==0.16.0"   # pulls mcp==1.26.0 (streamable_http)

# _sg_token_present — token exists AND is non-empty (`-s`, not just `-f`, so a
# zero-byte token from a failed bootstrap doesn't pass and 401 at connect time).
_sg_token_present() { [[ -s "$SG_TOKEN_FILE" ]]; }

# _sg_mcp_ensure_extra <osh> <sandbox>
# Idempotently ensure the sandbox's Hermes has mcp with the streamable-HTTP client.
# Conditioned on the IMPORT (not `command -v hermes`) so a bare-hermes sandbox is
# retrofitted. Returns non-zero if the import still fails after install.
_sg_mcp_ensure_extra() {
  local osh="$1" sb="$2"
  if "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- \
       python3 -c 'import mcp.client.streamable_http' >/dev/null 2>&1; then
    return 0
  fi
  log "  installing $SG_MCP_PIN inside sandbox (adds mcp==1.26.0; starlette 1.3.1->1.0.1, only affects unused 'hermes mcp serve')…"
  "$osh" sandbox exec -n "$sb" --no-tty --timeout 180 </dev/null -- \
    python3 -m pip install --quiet "$SG_MCP_PIN" 2>&1 | tail -5 | sed $'s/\x1b\\[[0-9;]*m//g'
  if "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- \
       python3 -c 'import mcp.client.streamable_http' >/dev/null 2>&1; then
    ok "  mcp.client.streamable_http import OK"
    return 0
  fi
  err "  '$SG_MCP_PIN' installed but 'import mcp.client.streamable_http' still fails."
  return 1
}

# _sg_roster <osh> <sandbox> — print the in-sandbox fleet profile names (one per
# line; ANSI-stripped first column of `hermes profile list`, hermes_* only).
_sg_roster() {
  "$1" sandbox exec -n "$2" --no-tty --timeout 40 </dev/null -- hermes profile list 2>/dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g' | awk 'NR>1 {print $1}' | grep -E '^hermes_' || true
}

# configure_hermes_mcp_sourcegraph <osh> <sandbox>
# Wire the default profile + every fleet profile to the local Sourcegraph MCP.
# GATED on the host token: absent -> skip+warn, return 0 (never fails the caller —
# SG is opt-in; the fleet stays green without it). All per-profile work runs in
# ONE uploaded in-sandbox script via a SINGLE exec (avoids relay contention).
# Returns: 0 wired/skipped; 1 the mcp SDK could not be made importable.
configure_hermes_mcp_sourcegraph() {
  local osh="$1" sb="$2"
  if ! _sg_token_present; then
    note "Sourcegraph MCP: token absent ($SG_TOKEN_FILE) — skipping fleet wiring."
    note "  Install + wire it with:  vz-ai-stack.sh install sourcegraph"
    return 0
  fi
  log "Wiring Hermes fleet -> Sourcegraph MCP (http://host.docker.internal:7080/.api/mcp)…"
  if ! _sg_mcp_ensure_extra "$osh" "$sb"; then
    warn "Sourcegraph MCP: could not enable the mcp SDK in the sandbox — wiring skipped (re-run after fixing PyPI egress)."
    return 1
  fi

  # Stage the per-profile wiring script on the host (gitignored derived dir),
  # then upload + run it ONCE. The script does .env seed (token via STDIN) + the
  # four `hermes config set` calls for the default profile + each roster profile,
  # all inside ONE sandbox process -> only ~1 relay open for all wiring. The
  # literal ${MCP_SOURCEGRAPH_API_KEY} is single-quoted so the in-sandbox sh does
  # NOT expand it (Hermes interpolates it from .env at connect time).
  local stage="${AI_STACK:-$HOME/ai-stack}/openshell/fleet-bootstrap"
  mkdir -p "$stage"
  cat > "$stage/sg-mcp-wire.sh" <<'WIRE'
#!/bin/sh
# Wire the default profile + each profile in "$@" to the Sourcegraph MCP server.
# Token arrives on STDIN (never argv). Run inside the sandbox.
read -r T
[ -n "$T" ] || { echo "sg-mcp-wire: empty token on STDIN" >&2; exit 1; }
URL='http://host.docker.internal:7080/.api/mcp'
_wire() {  # $1=HERMES_HOME dir   $2=profile-flag ("" or "--profile <name>")
  home="$1"; pflag="$2"
  mkdir -p "$home"; touch "$home/.env"
  grep -v '^MCP_SOURCEGRAPH_API_KEY=' "$home/.env" > "$home/.env.new" 2>/dev/null || true
  printf 'MCP_SOURCEGRAPH_API_KEY=%s\n' "$T" >> "$home/.env.new"
  mv "$home/.env.new" "$home/.env"; chmod 600 "$home/.env"
  hermes $pflag config set mcp_servers.sourcegraph.url "$URL" >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.sourcegraph.headers.Authorization 'token ${MCP_SOURCEGRAPH_API_KEY}' >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.sourcegraph.connect_timeout 5 >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.sourcegraph.enabled true >/dev/null 2>&1 || return 1
}
n=0; okc=0
n=$((n+1)); if _wire "$HOME/.hermes" ""; then okc=$((okc+1)); echo "ok default"; else echo "FAIL default"; fi
for p in "$@"; do
  n=$((n+1))
  if _wire "$HOME/.hermes/profiles/$p" "--profile $p"; then okc=$((okc+1)); echo "ok $p"; else echo "FAIL $p"; fi
done
echo "WIRED $okc/$n"
[ "$okc" -ge 1 ]
WIRE
  chmod 600 "$stage/sg-mcp-wire.sh"  # consistency (no secret in it — token arrives on STDIN)

  "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- /bin/sh -c 'mkdir -p /sandbox/fleet-boot' >/dev/null 2>&1 || true
  if ! "$osh" sandbox upload --no-git-ignore "$sb" "$stage/sg-mcp-wire.sh" /sandbox/fleet-boot/ >/dev/null 2>&1; then
    warn "Sourcegraph MCP: could not upload the wiring script to the sandbox — skipped."
    return 0
  fi

  # Roster as args; token via STDIN; ONE exec wires everything.
  local roster; roster="$(_sg_roster "$osh" "$sb" | tr '\n' ' ')"
  local out
  out="$(cat "$SG_TOKEN_FILE" | "$osh" sandbox exec -n "$sb" --no-tty --timeout 90 -- \
    /bin/sh /sandbox/fleet-boot/sg-mcp-wire.sh $roster 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  local summary; summary="$(grep -oE 'WIRED [0-9]+/[0-9]+' <<<"$out" | tail -1)"
  if [[ -n "$summary" ]]; then
    # Surface any per-profile failures for diagnosis (non-fatal).
    grep -E '^FAIL ' <<<"$out" | sed 's/^/  ⚠ /' >&2 || true
    if grep -q '^FAIL ' <<<"$out"; then
      warn "Sourcegraph MCP: $summary profiles (some failed — re-run 'vz-ai-stack.sh install 04f')"
    else
      ok "Sourcegraph MCP: $summary profiles wired"
    fi
  else
    warn "Sourcegraph MCP: wiring produced no summary (relay issue?). Output: $(tail -1 <<<"$out")"
  fi
  return 0
}
