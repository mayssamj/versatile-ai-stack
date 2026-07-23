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
# Pin rationale (>=0.16.0, a FLOOR not ==): 0.16.0 is the first version with the
# streamable-HTTP mcp client. An EXACT `==0.16.0` would DOWNGRADE a fleet upgraded to a
# newer hermes (e.g. 0.18.0) back to 0.16.0 on every 04f re-run — a silent revert that
# over-claims "upgraded" (§24 council caught this). The floor adds the [mcp] extra for
# whatever hermes is already installed without moving the base version up or down.

[[ -n "${_AI_STACK_MCP_SH:-}" ]] && return 0
_AI_STACK_MCP_SH=1

SG_TOKEN_FILE="$HOME/.sourcegraph-local/sg-token"
SG_MCP_PIN="hermes-agent[mcp]>=0.16.0"   # FLOOR (not ==): never downgrade the installed hermes; just add the [mcp] extra (streamable_http)

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
    note "  Install + wire it with:  mayssam-ai-stack.sh install sourcegraph"
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
      warn "Sourcegraph MCP: $summary profiles (some failed — re-run 'mayssam-ai-stack.sh install 04f')"
    else
      ok "Sourcegraph MCP: $summary profiles wired"
    fi
  else
    warn "Sourcegraph MCP: wiring produced no summary (relay issue?). Output: $(tail -1 <<<"$out")"
  fi
  return 0
}

# ── Understand-Anything MCP (Phase 30) ──────────────────────────────────────────────
# Wire the Hermes fleet to the host's understand-mcp HTTP server so fleet agents can
# query the committed knowledge graph (graph_search / read_node_source / …). Same
# mechanism as Sourcegraph: a host-loopback HTTP MCP reached at host.docker.internal,
# wired per-profile in ONE uploaded in-sandbox script. GATED on the token being set in
# .env — absent -> skip+warn, return 0 (fleet stays green; understand is opt-in).
UNDERSTAND_MCP_PORT_DEFAULT=7081

# configure_hermes_mcp_understand <osh> <sandbox> [port]
configure_hermes_mcp_understand() {
  local osh="$1" sb="$2" port="${3:-$UNDERSTAND_MCP_PORT_DEFAULT}"
  local token; token="$(get_env UNDERSTAND_MCP_TOKEN '')"
  if [[ -z "$token" ]]; then
    note "Understand MCP: UNDERSTAND_MCP_TOKEN absent from .env — skipping fleet wiring."
    note "  Install + wire it with:  mayssam-ai-stack.sh install understand"
    return 0
  fi
  local url="http://host.docker.internal:${port}/mcp"
  log "Wiring Hermes fleet -> Understand MCP ($url)…"
  if ! _sg_mcp_ensure_extra "$osh" "$sb"; then
    warn "Understand MCP: could not enable the mcp SDK in the sandbox — wiring skipped (re-run after fixing PyPI egress)."
    return 1
  fi

  # Stage the per-profile wiring script. URL is arg 1 (port-templated on the host);
  # the literal ${MCP_UNDERSTAND_TOKEN} is single-quoted so the in-sandbox sh does NOT
  # expand it (Hermes interpolates from .env at connect time). Token via STDIN only.
  local stage="${AI_STACK:-$HOME/ai-stack}/openshell/fleet-bootstrap"
  mkdir -p "$stage"
  cat > "$stage/understand-mcp-wire.sh" <<'WIRE'
#!/bin/sh
# Wire default + each profile in "$@" (after URL) to the Understand MCP server.
# Usage: understand-mcp-wire.sh <URL> [profile ...]   (token on STDIN)
URL="$1"; shift
read -r T
[ -n "$T" ] || { echo "understand-mcp-wire: empty token on STDIN" >&2; exit 1; }
[ -n "$URL" ] || { echo "understand-mcp-wire: empty URL" >&2; exit 1; }
_wire() {  # $1=HERMES_HOME dir   $2=profile-flag ("" or "--profile <name>")
  home="$1"; pflag="$2"
  mkdir -p "$home"; touch "$home/.env"
  grep -v '^MCP_UNDERSTAND_TOKEN=' "$home/.env" > "$home/.env.new" 2>/dev/null || true
  printf 'MCP_UNDERSTAND_TOKEN=%s\n' "$T" >> "$home/.env.new"
  mv "$home/.env.new" "$home/.env"; chmod 600 "$home/.env"
  hermes $pflag config set mcp_servers.understand.url "$URL" >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.understand.headers.Authorization 'token ${MCP_UNDERSTAND_TOKEN}' >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.understand.connect_timeout 5 >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.understand.enabled true >/dev/null 2>&1 || return 1
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
  chmod 600 "$stage/understand-mcp-wire.sh"

  "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- /bin/sh -c 'mkdir -p /sandbox/fleet-boot' >/dev/null 2>&1 || true
  if ! "$osh" sandbox upload --no-git-ignore "$sb" "$stage/understand-mcp-wire.sh" /sandbox/fleet-boot/ >/dev/null 2>&1; then
    warn "Understand MCP: could not upload the wiring script to the sandbox — skipped."
    return 0
  fi

  local roster; roster="$(_sg_roster "$osh" "$sb" | tr '\n' ' ')"
  local out
  out="$(printf '%s\n' "$token" | "$osh" sandbox exec -n "$sb" --no-tty --timeout 90 -- \
    /bin/sh /sandbox/fleet-boot/understand-mcp-wire.sh "$url" $roster 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  local summary; summary="$(grep -oE 'WIRED [0-9]+/[0-9]+' <<<"$out" | tail -1)"
  if [[ -n "$summary" ]]; then
    grep -E '^FAIL ' <<<"$out" | sed 's/^/  ⚠ /' >&2 || true
    if grep -q '^FAIL ' <<<"$out"; then
      warn "Understand MCP: $summary profiles (some failed — re-run 'mayssam-ai-stack.sh install 04f')"
    else
      ok "Understand MCP: $summary profiles wired"
    fi
  else
    warn "Understand MCP: wiring produced no summary (relay issue?). Output: $(tail -1 <<<"$out")"
  fi
  return 0
}

# ── doc-RAG MCP (Phase 39 / fleet memory) ───────────────────────────────────────────
# Wire the Hermes fleet to the host's docs-mcp HTTP server (semantic search over the
# ai-stack-docs Qdrant collection). Same host-loopback rail as Sourcegraph/Understand,
# but docs-mcp is UNAUTHENTICATED (ingestor/mcp_server.py has no auth) — so this wires
# url + connect_timeout + enabled only, NO .env seed and NO Authorization header. Egress
# to :8765 already ships in hermes-fleet-v1.yaml. Kept OPT-IN by the CALLER (Phase 39 wires
# it on `install fleet_memory`; 04f re-wires it only when stamp_check 39 is set) — this fn
# itself always attempts when invoked. Returns 0 wired/skipped; 1 the mcp SDK could not be
# made importable. Note: doc-RAG returns nothing until the ai-stack-docs collection is
# populated (`cd ingestor && python ingest.py`).
DOCS_MCP_PORT_DEFAULT=8765

# configure_hermes_mcp_docs <osh> <sandbox> [port]
configure_hermes_mcp_docs() {
  local osh="$1" sb="$2" port="${3:-$DOCS_MCP_PORT_DEFAULT}"
  local url="http://host.docker.internal:${port}/mcp"
  log "Wiring Hermes fleet -> doc-RAG MCP ($url)…"
  if ! _sg_mcp_ensure_extra "$osh" "$sb"; then
    warn "doc-RAG MCP: could not enable the mcp SDK in the sandbox — wiring skipped (re-run after fixing PyPI egress)."
    return 1
  fi

  # Stage the per-profile wiring script. URL is arg 1 (port-templated on the host).
  # No token: docs-mcp is unauthenticated, so no .env seed and no Authorization header.
  local stage="${AI_STACK:-$HOME/ai-stack}/openshell/fleet-bootstrap"
  mkdir -p "$stage"
  cat > "$stage/docs-mcp-wire.sh" <<'WIRE'
#!/bin/sh
# Wire default + each profile in "$@" (after URL) to the doc-RAG MCP server.
# Usage: docs-mcp-wire.sh <URL> [profile ...]   (no token — docs-mcp is unauthenticated)
URL="$1"; shift
[ -n "$URL" ] || { echo "docs-mcp-wire: empty URL" >&2; exit 1; }
_wire() {  # $1=HERMES_HOME dir   $2=profile-flag ("" or "--profile <name>")
  home="$1"; pflag="$2"
  mkdir -p "$home"
  hermes $pflag config set mcp_servers.docs.url "$URL" >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.docs.connect_timeout 5 >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.docs.enabled true >/dev/null 2>&1 || return 1
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
  chmod 600 "$stage/docs-mcp-wire.sh"

  "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- /bin/sh -c 'mkdir -p /sandbox/fleet-boot' >/dev/null 2>&1 || true
  if ! "$osh" sandbox upload --no-git-ignore "$sb" "$stage/docs-mcp-wire.sh" /sandbox/fleet-boot/ >/dev/null 2>&1; then
    warn "doc-RAG MCP: could not upload the wiring script to the sandbox — skipped."
    return 0
  fi

  local roster; roster="$(_sg_roster "$osh" "$sb" | tr '\n' ' ')"
  local out
  # </dev/null: docs-mcp-wire.sh reads no stdin (no token), so close it to avoid the
  # stdin-contention bug (installer/lib/fleet.sh:22, doctor.sh stdin note). understand/SG
  # instead FEED a token on stdin; this one must explicitly detach it.
  out="$("$osh" sandbox exec -n "$sb" --no-tty --timeout 90 </dev/null -- \
    /bin/sh /sandbox/fleet-boot/docs-mcp-wire.sh "$url" $roster 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  local summary; summary="$(grep -oE 'WIRED [0-9]+/[0-9]+' <<<"$out" | tail -1)"
  if [[ -n "$summary" ]]; then
    grep -E '^FAIL ' <<<"$out" | sed 's/^/  ⚠ /' >&2 || true
    if grep -q '^FAIL ' <<<"$out"; then
      warn "doc-RAG MCP: $summary profiles (some failed — re-run 'mayssam-ai-stack.sh install fleet_memory')"
    else
      ok "doc-RAG MCP: $summary profiles wired"
    fi
  else
    warn "doc-RAG MCP: wiring produced no summary (relay issue?). Output: $(tail -1 <<<"$out")"
  fi
  return 0
}

# ── Honcho memory MCP (Phase 40 / fleet memory) ─────────────────────────────────────
# Wire the Hermes fleet to the host-side honcho-mcp SHIM (host.docker.internal:7082) so
# fleet agents get Honcho memory (honcho_remember/recall/ask/search) as MCP tools. The
# shim is the ONLY sandbox path to Honcho — the raw auth-off :8000 egress is retired
# (Phase 40 / 04_openshell.sh). TOKENED like understand: gated on HONCHO_MCP_TOKEN in .env
# (absent -> skip+warn, return 0). Full-shared workspace: each profile passes its own peer.
HONCHO_MCP_PORT_DEFAULT=7082

# configure_hermes_mcp_honcho <osh> <sandbox> [port]
configure_hermes_mcp_honcho() {
  local osh="$1" sb="$2" port="${3:-$HONCHO_MCP_PORT_DEFAULT}"
  local token; token="$(get_env HONCHO_MCP_TOKEN '')"
  if [[ -z "$token" ]]; then
    note "Honcho MCP: HONCHO_MCP_TOKEN absent from .env — skipping fleet wiring."
    note "  Install + wire it with:  mayssam-ai-stack.sh install honcho_mcp"
    return 0
  fi
  local url="http://host.docker.internal:${port}/mcp"
  log "Wiring Hermes fleet -> Honcho MCP ($url)…"
  if ! _sg_mcp_ensure_extra "$osh" "$sb"; then
    warn "Honcho MCP: could not enable the mcp SDK in the sandbox — wiring skipped (re-run after fixing PyPI egress)."
    return 1
  fi

  # Stage the per-profile wiring script. URL is arg 1; token via STDIN (never argv). The
  # literal ${MCP_HONCHO_TOKEN} is single-quoted so the in-sandbox sh does NOT expand it
  # (Hermes interpolates it from that profile's .env at connect time).
  local stage="${AI_STACK:-$HOME/ai-stack}/openshell/fleet-bootstrap"
  mkdir -p "$stage"
  cat > "$stage/honcho-mcp-wire.sh" <<'WIRE'
#!/bin/sh
# Wire default + each profile in "$@" (after URL) to the Honcho MCP server.
# Usage: honcho-mcp-wire.sh <URL> [profile ...]   (token on STDIN)
URL="$1"; shift
read -r T
[ -n "$T" ] || { echo "honcho-mcp-wire: empty token on STDIN" >&2; exit 1; }
[ -n "$URL" ] || { echo "honcho-mcp-wire: empty URL" >&2; exit 1; }
_wire() {  # $1=HERMES_HOME dir   $2=profile-flag ("" or "--profile <name>")
  home="$1"; pflag="$2"
  mkdir -p "$home"; touch "$home/.env"
  grep -v '^MCP_HONCHO_TOKEN=' "$home/.env" > "$home/.env.new" 2>/dev/null || true
  printf 'MCP_HONCHO_TOKEN=%s\n' "$T" >> "$home/.env.new"
  mv "$home/.env.new" "$home/.env"; chmod 600 "$home/.env"
  hermes $pflag config set mcp_servers.honcho.url "$URL" >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.honcho.headers.Authorization 'Bearer ${MCP_HONCHO_TOKEN}' >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.honcho.connect_timeout 5 >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.honcho.enabled true >/dev/null 2>&1 || return 1
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
  chmod 600 "$stage/honcho-mcp-wire.sh"

  "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- /bin/sh -c 'mkdir -p /sandbox/fleet-boot' >/dev/null 2>&1 || true
  if ! "$osh" sandbox upload --no-git-ignore "$sb" "$stage/honcho-mcp-wire.sh" /sandbox/fleet-boot/ >/dev/null 2>&1; then
    warn "Honcho MCP: could not upload the wiring script to the sandbox — skipped."
    return 0
  fi

  local roster; roster="$(_sg_roster "$osh" "$sb" | tr '\n' ' ')"
  local out
  out="$(printf '%s\n' "$token" | "$osh" sandbox exec -n "$sb" --no-tty --timeout 90 -- \
    /bin/sh /sandbox/fleet-boot/honcho-mcp-wire.sh "$url" $roster 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  local summary; summary="$(grep -oE 'WIRED [0-9]+/[0-9]+' <<<"$out" | tail -1)"
  if [[ -n "$summary" ]]; then
    grep -E '^FAIL ' <<<"$out" | sed 's/^/  ⚠ /' >&2 || true
    if grep -q '^FAIL ' <<<"$out"; then
      warn "Honcho MCP: $summary profiles (some failed — re-run 'mayssam-ai-stack.sh install honcho_mcp')"
    else
      ok "Honcho MCP: $summary profiles wired"
    fi
  else
    warn "Honcho MCP: wiring produced no summary (relay issue?). Output: $(tail -1 <<<"$out")"
  fi
  return 0
}

# ── FalkorDB graph-memory MCP (Phase 41 / fleet memory) ─────────────────────────────
# Wire the Hermes fleet to the host-side falkordb-mcp SHIM (host.docker.internal:7083) so
# fleet agents get graph memory (remember_fact/recall_related/graph_query) as MCP tools. The
# shim is the ONLY sandbox path to FalkorDB — raw falkordb:6379 stays denied to sandboxes.
# TOKENED like honcho/understand: gated on FALKORDB_MCP_TOKEN in .env (absent -> skip+warn, 0).
FALKORDB_MCP_PORT_DEFAULT=7083

# configure_hermes_mcp_falkordb <osh> <sandbox> [port]
configure_hermes_mcp_falkordb() {
  local osh="$1" sb="$2" port="${3:-$FALKORDB_MCP_PORT_DEFAULT}"
  local token; token="$(get_env FALKORDB_MCP_TOKEN '')"
  if [[ -z "$token" ]]; then
    note "FalkorDB MCP: FALKORDB_MCP_TOKEN absent from .env — skipping fleet wiring."
    note "  Install + wire it with:  mayssam-ai-stack.sh install falkordb_mcp"
    return 0
  fi
  local url="http://host.docker.internal:${port}/mcp"
  log "Wiring Hermes fleet -> FalkorDB MCP ($url)…"
  if ! _sg_mcp_ensure_extra "$osh" "$sb"; then
    warn "FalkorDB MCP: could not enable the mcp SDK in the sandbox — wiring skipped (re-run after fixing PyPI egress)."
    return 1
  fi

  local stage="${AI_STACK:-$HOME/ai-stack}/openshell/fleet-bootstrap"
  mkdir -p "$stage"
  cat > "$stage/falkordb-mcp-wire.sh" <<'WIRE'
#!/bin/sh
# Wire default + each profile in "$@" (after URL) to the FalkorDB MCP server.
# Usage: falkordb-mcp-wire.sh <URL> [profile ...]   (token on STDIN)
URL="$1"; shift
read -r T
[ -n "$T" ] || { echo "falkordb-mcp-wire: empty token on STDIN" >&2; exit 1; }
[ -n "$URL" ] || { echo "falkordb-mcp-wire: empty URL" >&2; exit 1; }
_wire() {  # $1=HERMES_HOME dir   $2=profile-flag ("" or "--profile <name>")
  home="$1"; pflag="$2"
  mkdir -p "$home"; touch "$home/.env"
  grep -v '^MCP_FALKORDB_TOKEN=' "$home/.env" > "$home/.env.new" 2>/dev/null || true
  printf 'MCP_FALKORDB_TOKEN=%s\n' "$T" >> "$home/.env.new"
  mv "$home/.env.new" "$home/.env"; chmod 600 "$home/.env"
  hermes $pflag config set mcp_servers.falkordb.url "$URL" >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.falkordb.headers.Authorization 'Bearer ${MCP_FALKORDB_TOKEN}' >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.falkordb.connect_timeout 5 >/dev/null 2>&1 || return 1
  hermes $pflag config set mcp_servers.falkordb.enabled true >/dev/null 2>&1 || return 1
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
  chmod 600 "$stage/falkordb-mcp-wire.sh"

  "$osh" sandbox exec -n "$sb" --no-tty --timeout 30 </dev/null -- /bin/sh -c 'mkdir -p /sandbox/fleet-boot' >/dev/null 2>&1 || true
  if ! "$osh" sandbox upload --no-git-ignore "$sb" "$stage/falkordb-mcp-wire.sh" /sandbox/fleet-boot/ >/dev/null 2>&1; then
    warn "FalkorDB MCP: could not upload the wiring script to the sandbox — skipped."
    return 0
  fi

  local roster; roster="$(_sg_roster "$osh" "$sb" | tr '\n' ' ')"
  local out
  out="$(printf '%s\n' "$token" | "$osh" sandbox exec -n "$sb" --no-tty --timeout 90 -- \
    /bin/sh /sandbox/fleet-boot/falkordb-mcp-wire.sh "$url" $roster 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  local summary; summary="$(grep -oE 'WIRED [0-9]+/[0-9]+' <<<"$out" | tail -1)"
  if [[ -n "$summary" ]]; then
    grep -E '^FAIL ' <<<"$out" | sed 's/^/  ⚠ /' >&2 || true
    if grep -q '^FAIL ' <<<"$out"; then
      warn "FalkorDB MCP: $summary profiles (some failed — re-run 'mayssam-ai-stack.sh install falkordb_mcp')"
    else
      ok "FalkorDB MCP: $summary profiles wired"
    fi
  else
    warn "FalkorDB MCP: wiring produced no summary (relay issue?). Output: $(tail -1 <<<"$out")"
  fi
  return 0
}
