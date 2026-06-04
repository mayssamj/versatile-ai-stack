"""mempalace-qdrant — Qdrant storage backend for MemPalace (RFC-001).

Staged / forward-compatible: MemPalace 3.3.5 does not yet consume the backend
registry at runtime (palace.py hardcodes ChromaBackend). See backend.py header.
"""

from .backend import QdrantBackend, QdrantCollection

__all__ = ["QdrantBackend", "QdrantCollection"]
__version__ = "0.1.0"
