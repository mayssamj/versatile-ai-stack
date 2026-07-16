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
# models.yml registry KEY of the assigned embedder — must match the `embedder` stamp
# ingest.py wrote onto the points, else queries are embedded in a different vector space
# than the store (same dim, silent recall collapse). doctor check 77 enforces this.
EMBED_NAME  = "embed-nomic"

# Asymmetric task prefixes — MUST mirror ingest.py. nomic-embed-text is trained to see
# "search_query: " on queries against a corpus embedded with "search_document: ".
# Family-conditional: empty (exact no-op) for non-nomic families such as
# embed-openai-small-768, which have no prefix convention and would be HURT by one.
_NOMIC_FAMILIES = {"embed-nomic"}
_DOC_PREFIX   = "search_document: " if EMBED_NAME in _NOMIC_FAMILIES else ""
_QUERY_PREFIX = "search_query: "    if EMBED_NAME in _NOMIC_FAMILIES else ""


class PrefixedEmbedding(OpenAILikeEmbedding):
    """OpenAILikeEmbedding + optional asymmetric task prefixes (mirrors ingest.py).

    This version's OpenAILikeEmbedding has no query_instruction/text_instruction ctor
    arg; overriding the _get_*_embedding hooks is the supported extension point.
    """

    doc_prefix: str = ""
    query_prefix: str = ""

    def _get_query_embedding(self, query: str):
        return super()._get_query_embedding(self.query_prefix + query)

    async def _aget_query_embedding(self, query: str):
        return await super()._aget_query_embedding(self.query_prefix + query)

    def _get_text_embedding(self, text: str):
        return super()._get_text_embedding(self.doc_prefix + text)

    async def _aget_text_embedding(self, text: str):
        return await super()._aget_text_embedding(self.doc_prefix + text)

    def _get_text_embeddings(self, texts):
        return super()._get_text_embeddings([self.doc_prefix + t for t in texts])

    async def _aget_text_embeddings(self, texts):
        return await super()._aget_text_embeddings([self.doc_prefix + t for t in texts])


# Bind 0.0.0.0 so the docs-mcp alias (127.0.10.4) reaches us. FastMCP defaults
# to 127.0.0.1, which makes the alias unreachable even with lo0 bound.
mcp = FastMCP("ai-stack-docs", host="0.0.0.0", port=8765, stateless_http=True)  # stateless: accept a bare tools/call (pi's SDK-less MCP-over-HTTP client, no initialize handshake); SDK clients (claude/hermes) still work

LITELLM_BASE_URL = os.environ.get("LITELLM_BASE_URL", "http://litellm:4000")
QDRANT_URL       = os.environ.get("QDRANT_URL", "http://qdrant:6333")

_q = urlparse(QDRANT_URL)
_qdrant_host = _q.hostname or "qdrant"
_qdrant_port = _q.port or (80 if _q.scheme == "http" else 6333)

_client = QdrantClient(host=_qdrant_host, port=_qdrant_port)
_embed  = PrefixedEmbedding(
    # Local-only embedder (ollama/nomic-embed-text via LiteLLM `embed-local`).
    model_name=EMBED_MODEL,
    api_base=f"{LITELLM_BASE_URL.rstrip('/')}/v1",
    api_key=os.environ["LITELLM_MASTER_KEY"],
    embed_batch_size=10,
    timeout=180.0,
    doc_prefix=_DOC_PREFIX,
    query_prefix=_QUERY_PREFIX,
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
