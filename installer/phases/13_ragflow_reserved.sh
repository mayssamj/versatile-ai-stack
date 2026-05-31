#!/usr/bin/env bash
# Phase 13 — RAGFlow (reserved placeholder; do not install yet per brief).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=13
hdr "Phase 13 — RAGFlow (reserved)"
note "RAGFlow is a reserved placeholder per the install guide; no install action."
note "Re-purpose this phase when you decide what (if anything) RAGFlow becomes."
stamp_mark "$PHASE"
record "phase 13 complete: reserved placeholder (no-op)"
ok "Phase 13 — RAGFlow — placeholder complete"
