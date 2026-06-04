"""Qdrant storage backend for MemPalace (RFC-001 BaseBackend/BaseCollection).

STATUS — STAGED / FORWARD-COMPATIBLE (not the live backend on MemPalace 3.3.5).
================================================================================
MemPalace 3.3.5 hardcodes ``ChromaBackend()`` in ``palace.py`` (and repair.py /
dedup.py / migrate.py / cli.py) and does NOT consume the entry-point registry,
``resolve_backend_for_palace`` or ``MEMPALACE_BACKEND`` at runtime. So installing
this package and setting ``MEMPALACE_BACKEND=qdrant`` does NOT yet redirect the
live store — that wiring is a pending upstream PR (see base.py: "registry … land
in follow-up PRs"). This adapter is implemented + tested against the published
``BaseBackend``/``BaseCollection`` ABC so it is ready the moment upstream wires
the registry into ``palace.get_collection``. Until then, MemPalace stays on its
local on-device ChromaDB (which is itself no-cloud / constitution-compliant).

Design notes:
* Qdrant does not embed text. When ``add``/``upsert`` is called without explicit
  ``embeddings`` (the Chroma auto-embed path), we embed via MemPalace's own
  on-device EF (``mempalace.embedding.get_embedding_function``) — same vectors,
  same 384-dim space, still no cloud.
* MemPalace drawer ids are arbitrary strings; Qdrant point ids must be uint64 or
  UUID. We map ``point_id = uuid5(NAMESPACE, original_id)`` and stash the original
  id (``__mp_id``) + document text (``__mp_doc``) in the payload alongside the
  metadata. Reads reconstruct the original id/doc from the payload.
* Chroma cosine *distance* = ``1 - cosine_similarity``; Qdrant returns the
  similarity *score*. We return ``distance = 1 - score`` so the searcher's
  cosine interpretation (it reads ``collection.metadata['hnsw:space']``) holds.
"""

from __future__ import annotations

import os
import uuid
from typing import Any, Optional

from mempalace.backends.base import (
    BaseBackend,
    BaseCollection,
    GetResult,
    HealthStatus,
    PalaceNotFoundError,
    PalaceRef,
    QueryResult,
    UnsupportedFilterError,
    _IncludeSpec,
)

# Version-robust: develop has CollectionNotInitializedError (a PalaceNotFoundError
# subclass); released 3.3.5 only has PalaceNotFoundError. Use whichever exists so
# the adapter works across the versions where the registry may get wired in.
try:  # pragma: no cover - import shim
    from mempalace.backends.base import CollectionNotInitializedError as _NotInitError
except ImportError:  # pragma: no cover
    _NotInitError = PalaceNotFoundError

# Reserved payload keys (not part of user metadata).
_ID_KEY = "__mp_id"
_DOC_KEY = "__mp_doc"
_RESERVED = frozenset({_ID_KEY, _DOC_KEY})

# Deterministic namespace so the same drawer id always maps to the same point id.
_NS = uuid.UUID("6d656d70-616c-6163-6520-71647261746e")  # "mempalace qdratn"

_VEC_DIM = 384  # both minilm and embeddinggemma (MRL→384) — see mempalace.embedding
_SUPPORTED_OPERATORS = frozenset(
    {"$eq", "$ne", "$in", "$nin", "$and", "$or", "$contains", "$gt", "$gte", "$lt", "$lte"}
)


def _point_id(original_id: str) -> str:
    return str(uuid.uuid5(_NS, str(original_id)))


def _embedder():
    """Return MemPalace's on-device EF (callable: list[str] -> list[list[float]])."""
    from mempalace.embedding import get_embedding_function

    return get_embedding_function()


# ---------------------------------------------------------------------------
# Where-clause translation: Chroma dict -> Qdrant Filter
# ---------------------------------------------------------------------------


def _validate_where(where: Optional[dict]) -> None:
    if not where:
        return
    stack = [where]
    while stack:
        node = stack.pop()
        if not isinstance(node, dict):
            continue
        for k, v in node.items():
            if k.startswith("$") and k not in _SUPPORTED_OPERATORS:
                raise UnsupportedFilterError(f"operator {k!r} not supported by qdrant backend")
            if isinstance(v, dict):
                stack.append(v)
            elif isinstance(v, list):
                stack.extend(x for x in v if isinstance(x, dict))


def _translate_where(where: Optional[dict]):
    """Translate a Chroma-style where dict into a qdrant_client Filter (or None)."""
    if not where:
        return None
    from qdrant_client import models as qm

    def field_cond(key: str, op: str, value: Any):
        if op == "$eq":
            return qm.FieldCondition(key=key, match=qm.MatchValue(value=value))
        if op == "$ne":
            return qm.Filter(must_not=[qm.FieldCondition(key=key, match=qm.MatchValue(value=value))])
        if op == "$in":
            return qm.FieldCondition(key=key, match=qm.MatchAny(any=list(value)))
        if op == "$nin":
            return qm.Filter(must_not=[qm.FieldCondition(key=key, match=qm.MatchAny(any=list(value)))])
        if op in ("$gt", "$gte", "$lt", "$lte"):
            rng = {"$gt": "gt", "$gte": "gte", "$lt": "lt", "$lte": "lte"}[op]
            return qm.FieldCondition(key=key, range=qm.Range(**{rng: value}))
        if op == "$contains":
            # Tokenized full-text match (requires the __mp_doc text index created
            # at collection bootstrap). Approximates Chroma's substring contains.
            return qm.FieldCondition(key=key, match=qm.MatchText(text=str(value)))
        raise UnsupportedFilterError(f"operator {op!r} not supported by qdrant backend")

    def translate_node(node: dict):
        conditions = []
        for key, val in node.items():
            if key == "$and":
                conditions.append(qm.Filter(must=[translate_node(c) for c in val]))
            elif key == "$or":
                conditions.append(qm.Filter(should=[translate_node(c) for c in val]))
            elif key == "$contains":
                # where_document {"$contains": "x"} → match against the document text
                conditions.append(field_cond(_DOC_KEY, "$contains", val))
            elif isinstance(val, dict):
                # {field: {$op: value}} — one or more operators on a field
                for op, opval in val.items():
                    conditions.append(field_cond(key, op, opval))
            else:
                conditions.append(field_cond(key, "$eq", val))
        if len(conditions) == 1:
            return conditions[0]
        return qm.Filter(must=conditions)

    result = translate_node(where)
    # Qdrant's top-level filter field requires a Filter (not a bare condition).
    # $ne/$nin/$and/$or already produce Filters; wrap the bare-condition cases.
    if isinstance(result, qm.Filter):
        return result
    return qm.Filter(must=[result])


# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------


class QdrantCollection(BaseCollection):
    def __init__(self, client, name: str, embed=None):
        self._client = client
        self._name = name
        self._embed = embed or _embedder

    # --- helpers ---
    def _vectors_for(self, documents, embeddings):
        if embeddings is not None:
            return list(embeddings)
        ef = self._embed()
        return list(ef(list(documents)))

    def _payload(self, original_id, document, metadata):
        payload = dict(metadata or {})
        payload[_ID_KEY] = original_id
        payload[_DOC_KEY] = document if document is not None else ""
        return payload

    # --- writes ---
    def add(self, *, documents, ids, metadatas=None, embeddings=None):
        self.upsert(documents=documents, ids=ids, metadatas=metadatas, embeddings=embeddings)

    def upsert(self, *, documents, ids, metadatas=None, embeddings=None):
        from qdrant_client import models as qm

        vectors = self._vectors_for(documents, embeddings)
        metas = metadatas if metadatas is not None else [{} for _ in ids]
        points = [
            qm.PointStruct(
                id=_point_id(i),
                vector=list(vectors[n]),
                payload=self._payload(i, documents[n], metas[n]),
            )
            for n, i in enumerate(ids)
        ]
        self._client.upsert(collection_name=self._name, points=points, wait=True)

    # --- reads ---
    def query(
        self,
        *,
        query_texts=None,
        query_embeddings=None,
        n_results=10,
        where=None,
        where_document=None,
        include=None,
    ) -> QueryResult:
        _validate_where(where)
        _validate_where(where_document)
        if (query_texts is None) == (query_embeddings is None):
            raise ValueError("query requires exactly one of query_texts or query_embeddings")
        chosen = query_texts if query_texts is not None else query_embeddings
        if not chosen:
            raise ValueError("query input must be a non-empty list")

        spec = _IncludeSpec.resolve(include, default_distances=True)
        if query_embeddings is not None:
            vectors = [list(v) for v in query_embeddings]
        else:
            ef = self._embed()
            vectors = list(ef(list(query_texts)))

        flt = self._merge_filters(where, where_document)
        ids_out, docs_out, metas_out, dist_out, emb_out = [], [], [], [], []
        for vec in vectors:
            # query_points is the current API (qdrant-client >= 1.10; .search was
            # removed in 1.18). Returns a response whose .points are ScoredPoints.
            hits = self._client.query_points(
                collection_name=self._name,
                query=vec,
                limit=n_results,
                query_filter=flt,
                with_payload=True,
                with_vectors=spec.embeddings,
            ).points
            ids_out.append([h.payload.get(_ID_KEY) for h in hits])
            docs_out.append([h.payload.get(_DOC_KEY, "") for h in hits] if spec.documents else [])
            metas_out.append(
                [self._strip(h.payload) for h in hits] if spec.metadatas else []
            )
            dist_out.append([1.0 - float(h.score) for h in hits] if spec.distances else [])
            if spec.embeddings:
                emb_out.append([list(h.vector) if h.vector is not None else [] for h in hits])

        return QueryResult(
            ids=ids_out,
            documents=docs_out,
            metadatas=metas_out,
            distances=dist_out,
            embeddings=emb_out if spec.embeddings else None,
        )

    def get(
        self,
        *,
        ids=None,
        where=None,
        where_document=None,
        limit=None,
        offset=None,
        include=None,
    ) -> GetResult:
        _validate_where(where)
        _validate_where(where_document)
        spec = _IncludeSpec.resolve(include, default_distances=False)

        records = []
        if ids is not None:
            records = self._client.retrieve(
                collection_name=self._name,
                ids=[_point_id(i) for i in ids],
                with_payload=True,
                with_vectors=spec.embeddings,
            )
        else:
            flt = self._merge_filters(where, where_document)
            # Integer-offset pagination over Qdrant's cursor scroll: skip `offset`
            # points, then take `limit`. O(offset+limit) per call.
            want_skip = int(offset or 0)
            want_take = limit if limit is not None else 10_000_000
            cursor = None
            skipped = 0
            page = 256
            while len(records) < want_take:
                batch, cursor = self._client.scroll(
                    collection_name=self._name,
                    scroll_filter=flt,
                    limit=page,
                    offset=cursor,
                    with_payload=True,
                    with_vectors=spec.embeddings,
                )
                if not batch:
                    break
                for rec in batch:
                    if skipped < want_skip:
                        skipped += 1
                        continue
                    records.append(rec)
                    if len(records) >= want_take:
                        break
                if cursor is None:
                    break

        out_ids = [r.payload.get(_ID_KEY) for r in records]
        out_docs = [r.payload.get(_DOC_KEY, "") for r in records] if spec.documents else []
        out_metas = [self._strip(r.payload) for r in records] if spec.metadatas else []
        out_emb = (
            [list(r.vector) if r.vector is not None else [] for r in records]
            if spec.embeddings
            else None
        )
        return GetResult(ids=out_ids, documents=out_docs, metadatas=out_metas, embeddings=out_emb)

    def delete(self, *, ids=None, where=None):
        _validate_where(where)
        from qdrant_client import models as qm

        if ids is not None:
            self._client.delete(
                collection_name=self._name,
                points_selector=qm.PointIdsList(points=[_point_id(i) for i in ids]),
                wait=True,
            )
        elif where is not None:
            self._client.delete(
                collection_name=self._name,
                points_selector=qm.FilterSelector(filter=_translate_where(where)),
                wait=True,
            )

    def count(self) -> int:
        return int(self._client.count(collection_name=self._name, exact=True).count)

    def health(self) -> HealthStatus:
        try:
            self._client.count(collection_name=self._name, exact=False)
            return HealthStatus.healthy()
        except Exception as e:  # noqa: BLE001
            return HealthStatus.unhealthy(str(e))

    @property
    def metadata(self) -> dict:
        # The searcher reads hnsw:space to confirm cosine semantics; we always
        # create Cosine collections, so report it.
        return {"hnsw:space": "cosine"}

    # --- internals ---
    @staticmethod
    def _strip(payload: dict) -> dict:
        return {k: v for k, v in (payload or {}).items() if k not in _RESERVED}

    @staticmethod
    def _merge_filters(where, where_document):
        from qdrant_client import models as qm

        parts = []
        w = _translate_where(where)
        if w is not None:
            parts.append(w)
        wd = _translate_where(where_document)
        if wd is not None:
            parts.append(wd)
        if not parts:
            return None
        if len(parts) == 1:
            return parts[0]
        return qm.Filter(must=parts)


# ---------------------------------------------------------------------------
# Backend
# ---------------------------------------------------------------------------


class QdrantBackend(BaseBackend):
    """Server-mode Qdrant backend. Selected via MEMPALACE_BACKEND=qdrant once
    upstream wires the registry; until then, staged/forward-compatible."""

    name = "qdrant"
    capabilities = frozenset(
        {
            "supports_embeddings_in",
            "supports_embeddings_passthrough",
            "supports_embeddings_out",
            "supports_metadata_filters",
            "server_mode",
        }
    )

    def __init__(self, url: Optional[str] = None, api_key: Optional[str] = None):
        self._url = url or os.environ.get("MEMPALACE_QDRANT_URL", "http://qdrant:6333")
        self._api_key = api_key or os.environ.get("MEMPALACE_QDRANT_API_KEY") or None
        self._client = None
        self._known: set[str] = set()

    def _get_client(self):
        if self._client is None:
            from qdrant_client import QdrantClient

            self._client = QdrantClient(url=self._url, api_key=self._api_key)
        return self._client

    def _collection_name(self, palace: PalaceRef, collection_name: str) -> str:
        # Namespace by palace id so multiple palaces don't collide in one Qdrant.
        ns = palace.namespace or (palace.id or "default")
        safe = "".join(c if c.isalnum() else "_" for c in f"{ns}_{collection_name}")
        return f"mp_{safe}"[:255]

    def get_collection(
        self,
        *,
        palace: PalaceRef,
        collection_name: str,
        create: bool = False,
        options: Optional[dict] = None,
    ) -> QdrantCollection:
        from qdrant_client import models as qm

        client = self._get_client()
        qname = self._collection_name(palace, collection_name)
        exists = client.collection_exists(qname)
        if not exists:
            if not create:
                raise _NotInitError(palace.local_path or palace.id)
            dim = int((options or {}).get("dim", _VEC_DIM))
            client.create_collection(
                collection_name=qname,
                vectors_config=qm.VectorParams(size=dim, distance=qm.Distance.COSINE),
            )
            # Text index on the document payload so where_document $contains works.
            try:
                client.create_payload_index(
                    collection_name=qname,
                    field_name=_DOC_KEY,
                    field_schema=qm.TextIndexParams(
                        type="text", tokenizer=qm.TokenizerType.WORD, lowercase=True
                    ),
                )
            except Exception:  # noqa: BLE001 — index is best-effort
                pass
            self._known.add(qname)
        return QdrantCollection(client, qname)

    def health(self, palace: Optional[PalaceRef] = None) -> HealthStatus:
        try:
            self._get_client().get_collections()
            return HealthStatus.healthy(self._url)
        except Exception as e:  # noqa: BLE001
            return HealthStatus.unhealthy(f"{self._url}: {e}")

    def close(self) -> None:
        if self._client is not None:
            try:
                self._client.close()
            except Exception:  # noqa: BLE001
                pass
            self._client = None

    @classmethod
    def detect(cls, path: str) -> bool:
        # Server-mode: nothing on the local palace path identifies us.
        return False
