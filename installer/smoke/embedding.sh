#!/usr/bin/env bash
# Unit tests for installer/lib/embeddings.sh — the embedding registry/command.
# Runs entirely OFFLINE (no daemon, no containers). All writes go to a THROWAWAY
# models.yml copy via the MODELS_YML override — the real installer/models.yml is
# NEVER touched. Run:  bash installer/smoke/embedding.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

EMB="$AI_STACK/installer/lib/embeddings.sh"
REAL_YML="$AI_STACK/installer/models.yml"

# A fresh throwaway copy of the canonical models.yml for each write test.
fresh_yml() { local t; t="$(mktemp -t aistack-emb-yml.XXXXXX)"; cp "$REAL_YML" "$t"; echo "$t"; }
# run <models.yml> <args...> — invoke the embedding CLI against a copy. Called as a
# STATEMENT (not in $(...)) so it can set the globals OUT (combined output) + RC
# (exit code) in the parent shell. Never aborts the suite (guarded).
run() { local yml="$1"; shift; OUT="$(MODELS_YML="$yml" bash "$EMB" "$@" 2>&1)" && RC=0 || RC=$?; }

hdr "Smoke embedding — registry + guards (offline, throwaway models.yml)"

# --- 1. list renders the registry + assignments -----------------------------
log "list renders registry + per-service assignments"
run "$REAL_YML" list; out="$OUT"
[[ "$RC" == 0 ]] || { err "list exited $RC: $out"; exit 1; }
for m in embed-nomic embed-jina-code embed-minilm embed-gemma embed-openai-small; do
  grep -q "$m" <<<"$out" || { err "list missing '$m'"; exit 1; }
done
grep -q 'docs' <<<"$out" && grep -q 'honcho' <<<"$out" || { err "list missing services"; exit 1; }
ok "list renders registry + services"

# --- 2. list --json is valid JSON with both maps ----------------------------
log "list --json is valid JSON carrying embeddings + embedding_assignments"
run "$REAL_YML" list --json; out="$OUT"
[[ "$RC" == 0 ]] || { err "list --json exited $RC"; exit 1; }
yq -e '.embeddings.["embed-nomic"].dim == 768' <<<"$out" >/dev/null 2>&1 \
  || { err "list --json missing embed-nomic.dim=768"; exit 1; }
yq -e '.embedding_assignments.docs == "embed-nomic"' <<<"$out" >/dev/null 2>&1 \
  || { err "list --json missing docs assignment"; exit 1; }
ok "list --json valid"

# --- 3. embed-gemma dim is the corrected 384 (regression for the 768 contradiction) ---
log "embed-gemma dim == 384 (MRL runtime; was a contradictory 768)"
run "$REAL_YML" list --json; out="$OUT"
yq -e '.embeddings.["embed-gemma"].dim == 384' <<<"$out" >/dev/null 2>&1 \
  || { err "embed-gemma dim not corrected to 384"; exit 1; }
yq -e '.embeddings.["embed-gemma"].unverified == true' <<<"$out" >/dev/null 2>&1 \
  || { err "embed-gemma not flagged unverified"; exit 1; }
ok "embed-gemma dim=384 + unverified"

# --- 4. validate is fail-closed: an assignment to an undeclared model → exit 2 ---
log "validate rejects an assignment to an undeclared embedder (fail-closed, exit 2)"
bad="$(fresh_yml)"; trap 'rm -f "$bad"' EXIT
SVC=docs yq -i '.embedding_assignments.docs = "no-such-embedder"' "$bad"
run "$bad" show; out="$OUT"
[[ "$RC" == 2 ]] || { err "validate should exit 2 on undeclared embedder, got $RC: $out"; exit 1; }
rm -f "$bad"
ok "validate fail-closed (exit 2) on undeclared embedder"

# --- 5. assign docs to a DIFFERENT-dim embedder is REFUSED (no write) --------
log "assign docs embed-minilm (dim 384 != 768) → REFUSED, exit 2, no write"
t="$(fresh_yml)"
before="$(MODELS_YML="$t" yq -r '.embedding_assignments.docs' "$t")"
run "$t" assign docs embed-minilm; out="$OUT"
[[ "$RC" == 2 ]] || { err "docs dim-change assign should exit 2, got $RC: $out"; exit 1; }
grep -qi 'REFUSED' <<<"$out" || { err "docs dim-change should print REFUSED: $out"; exit 1; }
[[ "$(yq -r '.embedding_assignments.docs' "$t")" == "$before" ]] || { err "REFUSED assign still wrote the file!"; exit 1; }
rm -f "$t"
ok "docs dim-change refused + no write"

# --- 6. --force downgrades the docs dim guard to a warning (dry-run, no write) ---
log "assign docs embed-minilm --force --dry-run → warns dim change, exit 0, no write"
t="$(fresh_yml)"
run "$t" assign docs embed-minilm --force --dry-run; out="$OUT"
[[ "$RC" == 0 ]] || { err "--force --dry-run should exit 0, got $RC: $out"; exit 1; }
grep -qiE 'dim change|384' <<<"$out" || { err "--force should warn about the dim change: $out"; exit 1; }
[[ "$(yq -r '.embedding_assignments.docs' "$t")" == "embed-nomic" ]] || { err "--dry-run must NOT write"; exit 1; }
rm -f "$t"
ok "--force dim guard downgraded; --dry-run wrote nothing"

# --- 7. idempotent no-op: assigning the already-bound model writes nothing ----
log "assign openwebui embed-nomic (already bound) → no-op, exit 0, no .bak"
t="$(fresh_yml)"
run "$t" assign openwebui embed-nomic; out="$OUT"
[[ "$RC" == 0 ]] || { err "idempotent assign should exit 0, got $RC: $out"; exit 1; }
grep -qi 'already assigned' <<<"$out" || { err "should say already assigned: $out"; exit 1; }
[[ ! -f "$t.bak" ]] || { err "no-op assign must NOT create a .bak"; exit 1; }
rm -f "$t" "$t.bak"
ok "idempotent no-op (no write, no .bak)"

# --- 8. real write path: assign mempalace embed-gemma mutates the copy + backs up ---
log "assign mempalace embed-gemma → writes the copy + creates .bak (real write path)"
t="$(fresh_yml)"
run "$t" assign mempalace embed-gemma; out="$OUT"
[[ "$RC" == 0 ]] || { err "mempalace assign should exit 0, got $RC: $out"; exit 1; }
[[ "$(yq -r '.embedding_assignments.mempalace' "$t")" == "embed-gemma" ]] || { err "write did not land"; exit 1; }
[[ -f "$t.bak" ]] || { err "atomic write must create a .bak rollback"; exit 1; }
rm -f "$t" "$t.bak"
ok "real write path mutates copy + writes .bak"

# --- 9. honcho assign surfaces the apply-note (honcho is now CONSUMED, not recorded-only) -----
# honcho defaults to embed-nomic, so assign a DIFFERENT embedder to force a real change that
# reaches the honcho apply-note (install honcho_mcp + pgvector dim reconcile).
log "assign honcho embed-openai-small --dry-run → apply-note points at install honcho_mcp + pgvector reconcile"
t="$(fresh_yml)"
run "$t" assign honcho embed-openai-small --dry-run; out="$OUT"
[[ "$RC" == 0 ]] || { err "honcho dry-run should exit 0, got $RC: $out"; exit 1; }
grep -qi 'install honcho_mcp' <<<"$out" || { err "honcho assign must point to 'install honcho_mcp': $out"; exit 1; }
grep -qi 'pgvector' <<<"$out" || { err "honcho assign note must mention the pgvector dim reconcile: $out"; exit 1; }
rm -f "$t"
ok "honcho apply-note honestly surfaced (consumed, not recorded-only)"

# --- 10. global refuses a CODE embedder ---------------------------------------
log "global embed-jina-code (kind: code) → REFUSED, exit 2"
t="$(fresh_yml)"
run "$t" global embed-jina-code; out="$OUT"
[[ "$RC" == 2 ]] || { err "global code embedder should exit 2, got $RC: $out"; exit 1; }
grep -qi 'REFUSED\|code' <<<"$out" || { err "global should refuse the code embedder: $out"; exit 1; }
rm -f "$t"
ok "global refuses code embedder"

# --- 11. global --force does NOT punch through the docs dim guard ------------
log "global embed-minilm --force (dim 384 != docs 768) → still REFUSED (scope!=dim override)"
t="$(fresh_yml)"
run "$t" global embed-minilm --force; out="$OUT"
[[ "$RC" == 2 ]] || { err "global --force must still refuse a docs dim change, got $RC: $out"; exit 1; }
[[ "$(yq -r '.embedding_assignments.docs' "$t")" == "embed-nomic" ]] || { err "global --force corrupted docs dim!"; exit 1; }
rm -f "$t"
ok "global --force does not override the docs dim guard"

# --- 12. global targets only the general-text services (docs+openwebui) ------
log "global embed-nomic --dry-run → targets docs+openwebui only (NOT lumen/mempalace)"
t="$(fresh_yml)"
run "$t" global embed-nomic --dry-run; out="$OUT"
[[ "$RC" == 0 ]] || { err "global dry-run should exit 0, got $RC: $out"; exit 1; }
grep -q 'docs' <<<"$out" && grep -q 'openwebui' <<<"$out" || { err "global should target docs+openwebui: $out"; exit 1; }
rm -f "$t"
ok "global scope = docs+openwebui only"

ok "embedding smoke: all tests passed"
