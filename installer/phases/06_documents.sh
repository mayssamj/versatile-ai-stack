#!/usr/bin/env bash
# Phase 06 — Documents (Docling + LlamaIndex + MCP).
#
# Sets up a Python venv at ~/ai-stack/ingestor with docling + llama-index +
# qdrant-client + mcp. Writes ingest.py (sweeps ingestor/inbox → embeddings into
# Qdrant) and mcp_server.py (exposes search_documents over MCP on :8765).
#
# Open WebUI's built-in RAG is the first-line option; this phase enables the
# MCP path for agents that need programmatic doc retrieval (Hermes researcher).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=06
INGESTOR="$AI_STACK/ingestor"

precheck() {
  [[ -d "$INGESTOR/.venv" ]] || return 1
  [[ -f "$INGESTOR/ingest.py" ]] || return 1
  [[ -f "$INGESTOR/mcp_server.py" ]] || return 1
  # docs_mcp must be serving on :8765 — read PID file, confirm alive + bound.
  local pid_file="$STATE_DIR/docs_mcp.pid"
  [[ -f "$pid_file" ]] || return 1
  local pid; pid="$(cat "$pid_file" 2>/dev/null || echo "")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  port_listening 8765 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (documents)"
  exit 0
fi

hdr "Phase 06 — Documents (Docling + LlamaIndex + MCP)"

# Ingestion drop dirs live UNDER the ingestor/ engine dir (ingestor/inbox,
# ingestor/processed) so all document-ingestion state is in one place and there
# is no top-level `docs/` to collide with the `doc/` documentation dir.
# CHANGELOG 2026-05-30.
mkdir -p "$INGESTOR" "$INGESTOR/inbox" "$INGESTOR/processed"

# --- Venv via uv (faster, more reliable than pip) ---
cd "$INGESTOR"
if [[ ! -d .venv ]]; then
  log "Creating venv via uv..."
  uv venv .venv 2>&1 | tail -3
fi

# --- Requirements ---
cat > requirements.txt <<'EOF'
docling>=2.0
llama-index>=0.10
llama-index-vector-stores-qdrant>=0.1
llama-index-embeddings-openai-like>=0.1
qdrant-client>=1.10
mcp>=1.0
openai>=1.30
EOF

log "Installing requirements (may take a couple of minutes)..."
uv pip install --python .venv/bin/python -r requirements.txt 2>&1 | tail -5 \
  || { err "pip install failed"; exit 1; }

# DURABLE embedder resolution. ingest.py + mcp_server.py are COUPLED — both
# target the same Qdrant `ai-stack-docs` collection, pinned to one vector dim. We
# resolve the embedder assigned to `docs` in installer/models.yml (set via
# `vz-ai-stack.sh embedding assign docs <model>`) so a re-install honors a
# re-point: EMBED_MODEL <- the LiteLLM `route` of that embedder, EMBED_DIM <- its
# `dim`. The hardcoded values below (embed-local / 768) are the FALLBACK — a
# missing models.yml / embeddings section / yq leaves them untouched, so the
# phase never breaks. The two .py files are written from a QUOTED heredoc (so the
# Python body's $/`/{} are NOT shell-expanded); we therefore bake the resolved
# values in with a portable temp+mv rewrite of the two literal lines AFTER each
# heredoc, NOT by interpolating into the heredoc. (`as $k` guards a missing
# section: a bare index-by-null returns ALL values.) WARNING: changing the dim of
# an EXISTING, populated collection is a one-way destructive re-ingest — the
# ingest.py below refuses it unless AI_STACK_FORCE_RECREATE=1.
DOCS_EMBED_MODEL="embed-local"
DOCS_EMBED_DIM=768
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _dem="$(yq -r '(.embedding_assignments.docs // "") as $k | .embeddings[$k].route // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  _ded="$(yq -r '(.embedding_assignments.docs // "") as $k | .embeddings[$k].dim   // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_dem" && "$_dem" != "null" ]] && DOCS_EMBED_MODEL="$_dem"
  [[ "$_ded" =~ ^[1-9][0-9]*$ ]] && DOCS_EMBED_DIM="$_ded"
fi
note "docs embedder: EMBED_MODEL=$DOCS_EMBED_MODEL EMBED_DIM=$DOCS_EMBED_DIM (from models.yml .embedding_assignments.docs; fallback embed-local/768)"

# _bake_embed_literals <pyfile> — portable (temp+mv, no BSD/GNU sed -i divergence)
# rewrite of the two pinned literals in a generated .py. Anchored to line start so
# it can't touch a comment or substring. EMBED_DIM only exists in ingest.py; the
# mcp_server.py call is a harmless no-op there.
_bake_embed_literals() {
  local f="$1" tmp
  tmp="$(mktemp "${f}.XXXXXX")" || { warn "embedder bake: mktemp failed for $f (leaving defaults)"; return 0; }
  sed -E \
    -e "s|^EMBED_MODEL = \"[^\"]*\"|EMBED_MODEL = \"${DOCS_EMBED_MODEL}\"|" \
    -e "s|^EMBED_DIM([[:space:]]*)= [0-9]+|EMBED_DIM\1= ${DOCS_EMBED_DIM}|" \
    "$f" > "$tmp" && mv -f "$tmp" "$f" || { warn "embedder bake: rewrite failed for $f (leaving defaults)"; rm -f "$tmp"; return 0; }
}

# --- ingest.py: ingestor/inbox → Qdrant ---
cat > ingest.py <<'PY'
"""Sweep ~/ai-stack/ingestor/inbox/, parse via Docling, embed via LiteLLM, store in Qdrant.

Connection URLs are sourced from env vars so the same module works either as
a host-side process (the current deployment — uses /etc/hosts aliases
http://litellm:4000 and http://qdrant:6333) or, in the future, as a container on the
ai-stack network (would use Docker DNS http://litellm:4000 / http://qdrant:6333).
"""
import os, sys, shutil, pathlib
from urllib.parse import urlparse
from qdrant_client import QdrantClient
from llama_index.core import Document, VectorStoreIndex, StorageContext
from llama_index.vector_stores.qdrant import QdrantVectorStore
from llama_index.embeddings.openai_like import OpenAILikeEmbedding

INBOX = pathlib.Path(os.path.expanduser("~/ai-stack/ingestor/inbox"))
DONE  = pathlib.Path(os.path.expanduser("~/ai-stack/ingestor/processed"))
DONE.mkdir(parents=True, exist_ok=True)
COLL = "ai-stack-docs"
# nomic-embed-text (Ollama, served via LiteLLM as `embed-local`) produces
# 768-dim vectors. OpenAI's text-embedding-3-small is 1536. Keep the
# collection in sync with the active embedder.
EMBED_MODEL = "embed-local"
EMBED_DIM   = 768

# Env-var-driven endpoints. Defaults assume the /etc/hosts alias scheme is in
# place (Phase 00·N) so host-side processes can dial bare aliases on :80.
LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://litellm:4000")
QDRANT_URL       = os.environ.get("QDRANT_URL", "http://qdrant:6333")

_q = urlparse(QDRANT_URL)
_qdrant_host = _q.hostname or "qdrant"
_qdrant_port = _q.port or (80 if _q.scheme == "http" else 6333)

client = QdrantClient(host=_qdrant_host, port=_qdrant_port)
embed = OpenAILikeEmbedding(
    # LiteLLM routes `embed-local` to ollama/nomic-embed-text — fully on-host.
    # OpenAILikeEmbedding doesn't validate against the OpenAI-canonical model
    # enum, so non-OpenAI model names work via the LiteLLM proxy.
    model_name=EMBED_MODEL,
    api_base=f"{LITELLM_BASE_URL.rstrip('/')}/v1",
    api_key=os.environ["LITELLM_MASTER_KEY"],
    embed_batch_size=10,
    # Cold-load of nomic-embed-text in Ollama can take 5-10s on first call.
    # Default httpx timeout for OpenAILikeEmbedding is 60s — bump to 180s so
    # a slow first call (model swap into VRAM, host under load) doesn't 504.
    timeout=180.0,
)
# Warm-up: trigger model load before the (potentially slow) Docling parse so
# the first real embed call doesn't pay the cold-load cost.
try:
    embed.get_text_embedding("warmup")
except Exception as _e:
    print(f"  warmup skipped: {_e}", file=sys.stderr)

# Lazy collection create with dim coherence: if the collection exists with a
# stale vector size (e.g. 1536 from a previous run using the cloud embedder),
# recreate it so ingest doesn't fail with a dim mismatch. CRITICALLY: refuse
# to silently destroy data — abort if the existing collection holds any
# points so the user has to opt in to the migration.
from qdrant_client.models import VectorParams, Distance
_existing = {c.name for c in client.get_collections().collections}
if COLL in _existing:
    _info = client.get_collection(COLL)
    _current_dim = _info.config.params.vectors.size
    if _current_dim != EMBED_DIM:
        _n_points = client.count(COLL).count
        if _n_points > 0 and os.environ.get("AI_STACK_FORCE_RECREATE") != "1":
            raise SystemExit(
                f"\nERROR: collection {COLL!r} exists with vector size {_current_dim} "
                f"(holds {_n_points} embedded chunks) but the configured embedder "
                f"produces size {EMBED_DIM}.\n"
                "This is a one-way migration that would DESTROY existing data.\n"
                "If you want to proceed (lose the old embeddings):\n"
                f"  AI_STACK_FORCE_RECREATE=1 python {sys.argv[0]}\n"
                "Or back up first via Qdrant snapshot API."
            )
        print(f"recreating {COLL}: existing dim={_current_dim} != desired dim={EMBED_DIM} (n_points={_n_points})")
        client.delete_collection(COLL)
        _existing.discard(COLL)
if COLL not in _existing:
    client.create_collection(
        collection_name=COLL,
        vectors_config=VectorParams(size=EMBED_DIM, distance=Distance.COSINE),
    )
    print(f"created collection {COLL} (dim={EMBED_DIM})")

vstore = QdrantVectorStore(client=client, collection_name=COLL)
sctx   = StorageContext.from_defaults(vector_store=vstore)

# Docling lazy import (slow)
from docling.document_converter import DocumentConverter
conv = DocumentConverter()

count = 0
for src in sorted(INBOX.rglob("*")):
    if not src.is_file() or src.name.startswith("."):
        continue
    try:
        result = conv.convert(str(src))
        text = result.document.export_to_markdown()
    except Exception as e:
        print(f"  skip (Docling fail): {src.name}: {e}", file=sys.stderr)
        continue
    docs = [Document(text=text, metadata={"source": str(src)})]
    VectorStoreIndex.from_documents(docs, storage_context=sctx, embed_model=embed)
    # Move to processed/ PRESERVING the inbox subtree, and NEVER clobber. Using the
    # basename (DONE / src.name) flattened subdirs, so two files with the same name in
    # different inbox subdirs — or a re-run whose basename already sits in processed/ —
    # silently os.rename-overwrote each other, losing the earlier processed file.
    # (2026-07-05 takeover fix.)
    dest = DONE / src.relative_to(INBOX)
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        stem, suffix, n = dest.stem, dest.suffix, 1
        while dest.exists():
            dest = dest.parent / f"{stem}.{n}{suffix}"
            n += 1
    shutil.move(str(src), str(dest))
    count += 1
    print(f"  ingested: {src.relative_to(INBOX)}")

print(f"done: {count} docs ingested.")
PY

# --- mcp_server.py: search_documents MCP tool ---
cat > mcp_server.py <<'PY'
"""MCP server exposing search_documents over stdio AND HTTP :8765.

Endpoint URLs come from env vars (LITELLM_BASE_URL, QDRANT_URL) so the same
module works as a host-side process today (via /etc/hosts aliases) or as a
containerized service on ai-stack later (via Docker DNS).
"""
import os
from urllib.parse import urlparse
from qdrant_client import QdrantClient
from llama_index.core import VectorStoreIndex, StorageContext
from llama_index.vector_stores.qdrant import QdrantVectorStore
from llama_index.embeddings.openai_like import OpenAILikeEmbedding
from mcp.server.fastmcp import FastMCP

COLL = "ai-stack-docs"
# Local-only embedder (must match what ingest.py used to populate the index).
EMBED_MODEL = "embed-local"
# Bind 0.0.0.0 so the docs-mcp alias (127.0.10.4) reaches us. FastMCP defaults
# to 127.0.0.1, which makes the alias unreachable even with lo0 bound.
mcp = FastMCP("ai-stack-docs", host="0.0.0.0", port=8765, stateless_http=True)  # stateless: accept a bare tools/call (pi's SDK-less MCP-over-HTTP client, no initialize handshake); SDK clients (claude/hermes) still work

LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://litellm:4000")
QDRANT_URL       = os.environ.get("QDRANT_URL", "http://qdrant:6333")

_q = urlparse(QDRANT_URL)
_qdrant_host = _q.hostname or "qdrant"
_qdrant_port = _q.port or (80 if _q.scheme == "http" else 6333)

_client = QdrantClient(host=_qdrant_host, port=_qdrant_port)
_embed  = OpenAILikeEmbedding(
    # Local-only embedder (ollama/nomic-embed-text via LiteLLM `embed-local`).
    model_name=EMBED_MODEL,
    api_base=f"{LITELLM_BASE_URL.rstrip('/')}/v1",
    api_key=os.environ["LITELLM_MASTER_KEY"],
    embed_batch_size=10,
    timeout=180.0,
)
_vstore = QdrantVectorStore(client=_client, collection_name=COLL)
_index  = VectorStoreIndex.from_vector_store(_vstore, embed_model=_embed)

@mcp.tool()
def search_documents(query: str, top_k: int = 5) -> list:
    """Semantic search over the ai-stack-docs Qdrant collection."""
    retriever = _index.as_retriever(similarity_top_k=top_k)
    hits = retriever.retrieve(query)
    return [{"text": h.text, "score": h.score, "meta": h.metadata} for h in hits]

if __name__ == "__main__":
    mcp.run(transport="streamable-http")
PY

ok "wrote ingest.py + mcp_server.py"

# Bake the resolved embedder into BOTH coupled files (EMBED_MODEL in each;
# EMBED_DIM in ingest.py). Keeps the writer (quoted heredoc) safe while honoring
# the models.yml assignment. No-op when the assignment matches the defaults.
_bake_embed_literals ingest.py
_bake_embed_literals mcp_server.py

# --- Start docs_mcp as a background daemon (alias docs-mcp:8765) -----------
# Phase 06 owns the venv; bin/start-docs_mcp.sh owns daemonization (PID file,
# port-bound check, idempotent restart). User explicitly requested all
# services enabled by default.
if [[ -x "$AI_STACK/bin/start-docs_mcp.sh" ]]; then
  bash "$AI_STACK/bin/start-docs_mcp.sh" || warn "docs_mcp daemon start failed — see $STATE_DIR/docs_mcp.log"
else
  warn "$AI_STACK/bin/start-docs_mcp.sh missing — docs_mcp not auto-started"
fi

stamp_mark "$PHASE"
record "phase 06 complete: ingestor venv + ingest.py + mcp_server.py installed + docs_mcp daemon started"
ok "Phase 06 — Documents — complete"
note "Ingest documents:  cd $INGESTOR && source .venv/bin/activate && python ingest.py"
note "docs_mcp daemon:   bash $AI_STACK/bin/start-docs_mcp.sh (idempotent; binds :8765)"
note "Stop docs_mcp:     kill \$(cat $STATE_DIR/docs_mcp.pid)"
