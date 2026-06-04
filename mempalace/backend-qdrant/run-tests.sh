#!/usr/bin/env bash
# Build an isolated venv (mempalace + qdrant-client + this adapter) and run the
# Qdrant-backend conformance test against a live Qdrant. Kept OUT of the
# mempalace uv-tool env on purpose: qdrant-client's protobuf/grpc pins conflict
# with chromadb's and break `import chromadb`. PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION
# =python sidesteps that clash for the test run.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${MPQ_TEST_VENV:-/tmp/mpq-testenv}"
export MEMPALACE_QDRANT_URL="${MEMPALACE_QDRANT_URL:-http://qdrant:6333}"

command -v uv >/dev/null || { echo "uv not on PATH (Phase 14 installs it)"; exit 1; }
echo "Building test venv at $VENV ..."
uv venv "$VENV" >/dev/null 2>&1 || true
uv pip install --python "$VENV" --quiet --reinstall-package mempalace-qdrant \
  mempalace qdrant-client "$HERE" 2>&1 | tail -2

echo "Running conformance test against $MEMPALACE_QDRANT_URL ..."
PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python "$VENV/bin/python" "$HERE/tests/test_adapter.py"
