"""Standalone conformance test for the Qdrant MemPalace backend adapter.

Exercises the RFC-001 BaseBackend/BaseCollection contract against a LIVE Qdrant
(default http://qdrant:6333, override via MEMPALACE_QDRANT_URL). Uses caller-
provided embeddings so it needs neither the ONNX model nor network downloads.

Run:  <env-python> mempalace/backend-qdrant/tests/test_adapter.py
Exit 0 = all assertions passed. Creates + drops a unique throwaway collection.
"""

import os
import sys
import uuid

# PalaceNotFoundError is the base of CollectionNotInitializedError on develop and
# the only "missing" error on released 3.3.5 — catching it covers both versions.
from mempalace.backends.base import PalaceRef, QueryResult, GetResult, PalaceNotFoundError
from mempalace_qdrant import QdrantBackend


def _vec(seed: float):
    # Deterministic 384-d unit-ish vector; distinct per seed so ranking is stable.
    v = [0.0] * 384
    v[0] = 1.0
    v[1] = seed
    return v


def main() -> int:
    url = os.environ.get("MEMPALACE_QDRANT_URL", "http://qdrant:6333")
    backend = QdrantBackend(url=url)

    h = backend.health()
    assert h.ok, f"Qdrant not healthy at {url}: {h.detail}"
    print(f"[ok] Qdrant healthy at {url}")

    palace = PalaceRef(id=f"test-{uuid.uuid4().hex[:8]}", namespace=f"t{uuid.uuid4().hex[:8]}")

    # create=False on a missing collection must raise (spec).
    try:
        backend.get_collection(palace=palace, collection_name="drawers", create=False)
        raise AssertionError("expected PalaceNotFoundError on missing collection")
    except PalaceNotFoundError:
        print("[ok] create=False raises PalaceNotFoundError (missing collection)")

    col = backend.get_collection(palace=palace, collection_name="drawers", create=True)
    qname = col._name
    client = backend._get_client()
    try:
        assert col.count() == 0
        print("[ok] fresh collection count == 0")

        # add with explicit embeddings (passthrough path)
        col.add(
            documents=["the watchdog is warn-only by default", "qdrant stores vectors"],
            ids=["d1", "d2"],
            metadatas=[{"wing": "ops", "source_file": "a.md"}, {"wing": "db", "source_file": "b.md"}],
            embeddings=[_vec(0.10), _vec(0.90)],
        )
        assert col.count() == 2, f"expected 2, got {col.count()}"
        print("[ok] add + count == 2")

        # query by embedding closest to d1
        q = col.query(query_embeddings=[_vec(0.11)], n_results=2,
                      include=["documents", "metadatas", "distances"])
        assert isinstance(q, QueryResult)
        assert q.ids[0][0] == "d1", f"nearest should be d1, got {q.ids[0]}"
        assert q.documents[0][0].startswith("the watchdog")
        assert q.metadatas[0][0]["wing"] == "ops"
        assert all(0.0 <= d <= 2.0 for d in q.distances[0]), q.distances
        assert "__mp_id" not in q.metadatas[0][0] and "__mp_doc" not in q.metadatas[0][0]
        print(f"[ok] query nearest=d1, distance={q.distances[0][0]:.4f}, metadata stripped")

        # where filter (equality) via get
        g = col.get(where={"wing": "db"}, include=["documents", "metadatas"])
        assert isinstance(g, GetResult)
        assert g.ids == ["d2"], g.ids
        print("[ok] get(where eq) -> d2")

        # $in filter
        g2 = col.get(where={"wing": {"$in": ["ops", "db"]}})
        assert set(g2.ids) == {"d1", "d2"}, g2.ids
        print("[ok] get(where $in) -> {d1,d2}")

        # get by ids
        g3 = col.get(ids=["d1"], include=["documents"])
        assert g3.ids == ["d1"] and g3.documents[0].startswith("the watchdog")
        print("[ok] get(ids) -> d1 with document")

        # where_document $contains (uses the text index)
        g4 = col.get(where_document={"$contains": "qdrant"}, include=["documents"])
        assert g4.ids == ["d2"], g4.ids
        print("[ok] get(where_document $contains 'qdrant') -> d2")

        # upsert overwrites
        col.upsert(documents=["updated d1"], ids=["d1"], metadatas=[{"wing": "ops2"}],
                   embeddings=[_vec(0.12)])
        g5 = col.get(ids=["d1"], include=["documents", "metadatas"])
        assert g5.documents[0] == "updated d1" and g5.metadatas[0]["wing"] == "ops2"
        assert col.count() == 2, "upsert must not add a new point"
        print("[ok] upsert overwrites in place (count stays 2)")

        # delete by id
        col.delete(ids=["d1"])
        assert col.count() == 1
        # delete by where
        col.delete(where={"wing": "db"})
        assert col.count() == 0
        print("[ok] delete by id + by where -> count == 0")

        # unsupported operator must raise, not silently drop
        try:
            col.get(where={"wing": {"$regex": "x"}})
            raise AssertionError("expected UnsupportedFilterError for $regex")
        except Exception as e:  # noqa: BLE001
            assert "regex" in str(e).lower() or "not supported" in str(e).lower(), e
        print("[ok] unsupported operator raises (no silent drop)")

    finally:
        client.delete_collection(collection_name=qname)
        print(f"[cleanup] dropped {qname}")

    print("\nALL ADAPTER CONFORMANCE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
