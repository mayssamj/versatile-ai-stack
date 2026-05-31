#!/usr/bin/env bash
# Phase 16 — Lumen (Ory's local code semantic search MCP server).
#
# Lumen is a single Go binary that runs as a stdio MCP server. It is NOT a
# daemon. Each MCP client (AutoFyn, Open WebUI, Claude Code, Codex, etc.)
# spawns its own `lumen stdio` subprocess. There is no HTTP/SSE transport
# in v0.0.41 — confirmed in source (`cmd/stdio.go` only uses
# `mcp.StdioTransport{}`; `cmd/` has no http/sse file).
#
# Why this shape (vs daemonized like docs-mcp):
#   - The plan's original "publish on lumen:8766, share with all clients"
#     would have required an mcp-proxy stdio→SSE bridge — an extra moving
#     piece, no upstream auth, and double-encoded JSON-RPC. Not worth it
#     for personal-Mac scale. See CHANGELOG 2026-05-29 Phase 16 entry.
#   - Per-client subprocess matches how the Ory README wires Codex.
#   - Pi (the OpenShell sandbox) cannot use Lumen directly today because
#     the sandbox has no path to a stdio process on the host. Deferred.
#
# What this phase does (idempotent):
#   1. Pre-pulls the embedding model via Ollama:
#      `ordis/jina-embeddings-v2-base-code` (~150MB; Lumen's default).
#   2. Downloads the pinned v0.0.41 darwin-arm64 binary to
#      $AI_STACK/vendor/lumen/, verifies SHA256 against the checksum from
#      the same release tag (best-effort — upstream doesn't sign releases).
#   3. Strips the macOS quarantine xattr so the binary runs without
#      Gatekeeper prompt.
#   4. chmod 0700 ~/.local/share/lumen (where Lumen stores its index by
#      default, keyed by repo path + embedding model + binary version).
#   5. Smoke-tests via `lumen doctor`.
#   6. Auto-indexes the ai-stack repo itself as a sensible default — so
#      the first MCP query from any client returns useful results without
#      requiring the user to choose a repo first.
#
# Standalone install: `bash install.sh install 16`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=16
LUMEN_VERSION="0.0.41"
LUMEN_PLATFORM="darwin-arm64"
LUMEN_ASSET="lumen-${LUMEN_VERSION}-${LUMEN_PLATFORM}"
LUMEN_URL="https://github.com/ory/lumen/releases/download/v${LUMEN_VERSION}/${LUMEN_ASSET}"
LUMEN_SHA256="367aa8b50b1cc605801a03a814a6f953342fa1a0116074f132d32ef61c441b13"
LUMEN_DIR="$AI_STACK/vendor/lumen"
LUMEN_BIN="$LUMEN_DIR/$LUMEN_ASSET"
LUMEN_EMBED_MODEL="ordis/jina-embeddings-v2-base-code"
LUMEN_INDEX_ROOT="$HOME/.local/share/lumen"

precheck() {
  # Binary present + matches the pinned SHA256.
  [[ -x "$LUMEN_BIN" ]] || return 1
  local actual
  actual="$(shasum -a 256 "$LUMEN_BIN" 2>/dev/null | awk '{print $1}')"
  [[ "$actual" == "$LUMEN_SHA256" ]] || return 1
  # Lumen has no `doctor` subcommand in v0.0.41 — `version` proves the binary
  # runs and is the right version.
  local v
  v="$("$LUMEN_BIN" version 2>/dev/null | head -1 | tr -d '[:space:]')"
  [[ "$v" == "$LUMEN_VERSION" ]] || return 1
  # Embedding model pulled in Ollama.
  if ! ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qE "^${LUMEN_EMBED_MODEL}(:|$)"; then
    return 1
  fi
  # bin/lumen wrapper present + executable.
  [[ -x "$AI_STACK/bin/lumen" ]] || return 1
  # Default ai-stack index built (index dir exists under ~/.local/share/lumen).
  # Lumen names index dirs by a hash of {project_path, embed_model, binary_version}
  # so we just check that the index root is non-empty.
  [[ -d "$LUMEN_INDEX_ROOT" ]] && (( $(find "$LUMEN_INDEX_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l) > 0 )) || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (lumen v$LUMEN_VERSION + ${LUMEN_EMBED_MODEL})"
  exit 0
fi

hdr "Phase 16 — Lumen (code semantic search MCP)"

# --- 1. Embedding model via Ollama ---
if ! command -v ollama >/dev/null; then
  err "ollama not on PATH — run Phase 01 first."
  exit 1
fi
if ! ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qE "^${LUMEN_EMBED_MODEL}(:|$)"; then
  log "Pulling embedding model ${LUMEN_EMBED_MODEL} via Ollama (~150MB)..."
  if ! ollama pull "$LUMEN_EMBED_MODEL"; then
    err "ollama pull ${LUMEN_EMBED_MODEL} failed"
    exit 1
  fi
fi
ok "embedding model present: ${LUMEN_EMBED_MODEL}"

# --- 2. Download + verify binary ---
mkdir -p "$LUMEN_DIR"
if [[ ! -f "$LUMEN_BIN" ]]; then
  log "Downloading ${LUMEN_ASSET} (~32MB)..."
  if ! curl -sLf -o "$LUMEN_BIN" "$LUMEN_URL"; then
    err "Failed to download $LUMEN_URL"
    rm -f "$LUMEN_BIN"
    exit 1
  fi
fi
actual_sha="$(shasum -a 256 "$LUMEN_BIN" | awk '{print $1}')"
if [[ "$actual_sha" != "$LUMEN_SHA256" ]]; then
  err "SHA256 mismatch on $LUMEN_BIN"
  err "  expected: $LUMEN_SHA256"
  err "  actual:   $actual_sha"
  err "Removing tampered binary."
  rm -f "$LUMEN_BIN"
  exit 1
fi
ok "binary verified: $LUMEN_ASSET (sha256 matches release checksum)"

# --- 3. Strip macOS quarantine + make executable ---
chmod 0755 "$LUMEN_BIN"
xattr -d com.apple.quarantine "$LUMEN_BIN" 2>/dev/null || true

# --- 4. Pre-create + chmod the index root ---
mkdir -p "$LUMEN_INDEX_ROOT"
chmod 0700 "$LUMEN_INDEX_ROOT"
ok "index root: $LUMEN_INDEX_ROOT (mode 0700)"

# --- 5. Smoke test ---
log "Smoke test: lumen version..."
LUMEN_REPORTED_VERSION="$("$LUMEN_BIN" version 2>&1 | head -1 | tr -d '[:space:]')"
if [[ "$LUMEN_REPORTED_VERSION" == "$LUMEN_VERSION" ]]; then
  ok "lumen reports version $LUMEN_REPORTED_VERSION"
else
  err "lumen version output didn't match expected v$LUMEN_VERSION: '$LUMEN_REPORTED_VERSION'"
  exit 1
fi

# --- 6. bin/lumen wrapper ---
# Single wrapper script so the user (and MCP clients) don't have to know the
# vendored binary path. Lumen v0.0.41 reads $LUMEN_EMBED_MODEL as the default
# for --model; the backend defaults to ollama at http://localhost:11434 (no
# CLI flag to override the URL today — confirmed in --help).
#
# Subcommands (lumen --help):
#   lumen index <path>           index a project (path IS the key — no name)
#   lumen search <query>         search the index for the cwd or --path target
#   lumen purge [<path>...]      delete indexes (no args = wipe everything)
#   lumen stdio                  start the MCP server on stdin/stdout
#   lumen hook <pre-tool-use|session-start>   Claude Code / Cursor hook integration
#   lumen version
WRAPPER="$AI_STACK/bin/lumen"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# bin/lumen — thin wrapper around the vendored Lumen binary.
#
# Subcommands:
#   lumen index <path>      index a project for semantic search
#   lumen search <query>    one-shot CLI search (use --path <dir> for a non-cwd index)
#   lumen stdio             run as an MCP stdio server (what MCP clients should call)
#   lumen purge [<path>]    delete indexes (no path = wipe ALL)
#   lumen version
#
# Registering Lumen as an MCP server (per-client):
#   AutoFyn:  Settings → Tools → Add MCP server →
#               command: $AI_STACK/bin/lumen
#               args:    [stdio]
#   Open WebUI: Tools → Add → MCP stdio → same command + args
#   Claude Code: in your settings.json's mcpServers:
#               "lumen": { "command": "$AI_STACK/bin/lumen", "args": ["stdio"] }
#
# Env knobs (set in your shell before invoking):
#   LUMEN_EMBED_MODEL   override the embedding model (default $LUMEN_EMBED_MODEL)
export LUMEN_EMBED_MODEL="\${LUMEN_EMBED_MODEL:-$LUMEN_EMBED_MODEL}"
exec "$LUMEN_BIN" "\$@"
EOF
chmod 0755 "$WRAPPER"
ok "wrote $WRAPPER"

# --- 7. Default index: the ai-stack repo itself ---
# Index the stack's own source so agents asking "where is the OpenShell
# policy applied?" get useful answers on day one.
# Lumen names indexes by hash of (project_path + embed_model + binary_version)
# and stores them under \$HOME/.local/share/lumen/. There's no `index list` —
# we check by looking for any subdir.
EXISTING_INDEXES="$(find "$LUMEN_INDEX_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
if (( EXISTING_INDEXES == 0 )); then
  log "Indexing ai-stack as the default index (may take 1-3 min on first run)..."
  if "$WRAPPER" index "$AI_STACK" 2>&1 | tail -5; then
    ok "indexed ai-stack"
  else
    warn "default index of ai-stack failed — retry manually: bin/lumen index $AI_STACK"
  fi
else
  ok "$EXISTING_INDEXES existing index dir(s) under $LUMEN_INDEX_ROOT — skipping default index"
fi

stamp_mark "$PHASE"
record "phase 16 complete: lumen v$LUMEN_VERSION + ${LUMEN_EMBED_MODEL} + default ai-stack index"
ok "Phase 16 — Lumen — complete"
note "List:   ls ~/.local/share/lumen/         (indexes are hash-named)"
note "Try:    bin/lumen search 'openshell policy' --path $AI_STACK"
note "MCP:    register 'bin/lumen stdio' as an MCP server in your client"
note "        (AutoFyn: Settings → Tools → MCP; Open WebUI: Tools → Add MCP)"
note "Add a work repo:  bin/lumen index ~/path/to/repo"
note "Purge all:        bin/lumen purge"
