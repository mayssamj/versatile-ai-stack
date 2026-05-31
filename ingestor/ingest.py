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
    shutil.move(str(src), str(DONE / src.name))
    count += 1
    print(f"  ingested: {src.name}")

print(f"done: {count} docs ingested.")
