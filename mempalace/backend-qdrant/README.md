# mempalace-qdrant — Qdrant backend for MemPalace (STAGED)

A drop-in [Qdrant](https://qdrant.tech) storage backend for MemPalace, implementing
the RFC-001 `BaseBackend` / `BaseCollection` contract. It exists so the ai-stack
can eventually consolidate MemPalace onto the **existing stack Qdrant** (`qdrant:6333`)
instead of running a second vector store (ChromaDB).

## ⚠️ Status: staged / forward-compatible — NOT the live backend yet

MemPalace **3.3.5 does not consume the backend registry at runtime.** `palace.py`
hardcodes `_DEFAULT_BACKEND = ChromaBackend()`, and `repair.py` / `dedup.py` /
`migrate.py` / `cli.py` each instantiate `ChromaBackend()` directly. The
`mempalace.backends` entry-point group, `resolve_backend_for_palace`, and the
`MEMPALACE_BACKEND` env var all exist in the package but are **never called** by
any runtime path (upstream `base.py`: *"registry … land in follow-up PRs"*).

So: installing this package and setting `MEMPALACE_BACKEND=qdrant` does **not**
redirect the live store today. MemPalace stays on its local, on-device ChromaDB
(which is itself no-cloud and constitution-compliant). This adapter is built and
**verified against the ABC + live Qdrant** so it's ready the moment upstream
wires the registry into `palace.get_collection`.

Also note: **do not co-install `qdrant-client` into the MemPalace `uv tool`
environment** — its gRPC/protobuf pins conflict with chromadb's and break
`import chromadb` (hence `mempalace` itself). That's why Phase 26 does not add it
to the tool env, and why this adapter is tested in an isolated venv.

## What it does

- Embeds via MemPalace's own on-device EF (`mempalace.embedding`) when documents
  are added without explicit vectors — same 384-dim space, still no cloud.
- Maps MemPalace string ids → deterministic `uuid5` Qdrant point ids; stores the
  original id + document text in the payload.
- Translates Chroma-style `where` / `where_document` filters
  (`$eq/$ne/$in/$nin/$and/$or/$gt/$gte/$lt/$lte/$contains`) to Qdrant filters;
  raises `UnsupportedFilterError` on anything else (no silent drops).
- Cosine collections; returns `distance = 1 - score` so the searcher's cosine
  interpretation holds.

## Run the conformance test (against live Qdrant)

```bash
bash run-tests.sh            # builds an isolated venv, runs tests/test_adapter.py
# or point at another instance:
MEMPALACE_QDRANT_URL=http://127.0.0.1:6333 bash run-tests.sh
```

The test exercises the full `BaseCollection` surface against a real Qdrant using
caller-provided embeddings (no model download), in a unique throwaway collection
that is dropped on exit.

## When upstream wires the registry

1. `uv tool install mempalace --with <this-dir>` *(in an env where qdrant-client
   and chromadb's protobuf pins are compatible — verify first)*, **or** run
   MemPalace from a venv that has both.
2. `export MEMPALACE_BACKEND=qdrant MEMPALACE_QDRANT_URL=http://qdrant:6333`
3. `mempalace mine … && mempalace search …` now read/write Qdrant.

Until then, treat this as a tested, shelf-ready component.
