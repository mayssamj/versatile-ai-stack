# Embedding dimensionality consistency (canonical-768 enforcement, §24 council 2026-07-15).
#
# GUARDS the operator invariant "no index/query dim disparity ANYWHERE": for each dim-pinned
# embedding consumer, the LIVE store's vector dim must equal the dim of the model assigned to
# it in models.yml (.embedding_assignments -> .embeddings[m].dim). The CANONICAL TARGET is 768;
# this check enforces store==assigned-dim (consistency), and once every text consumer is on a
# 768 embedder the whole fleet is canonical. Consumers covered:
#   - docs   : Qdrant `ai-stack-docs` vector size, the deployed ingest.py EMBED_DIM, the
#              deployed ingest.py EMBED_MODEL == the assigned route (code-drift guard), AND
#              the per-point embedder FAMILY STAMP == the assigned embedder (see below).
#   - honcho : pgvector column typmod on the base tables documents + message_embeddings.
# openwebui/lumen self-manage their index dim (lumen hash-keys its dir by embed_model);
# mempalace is on-device/isolated 384; ai-town is an isolated opt-in sim — all out of scope.
#
# GRACEFUL + FAIL-CLOSED-SAFE: a store that is absent/unreachable is SKIP-CLEAN (distinct from
# present-but-wrong-dim = FAIL). CRITICAL: the doctor runner uses `set -Eeuo pipefail;
# inherit_errexit`, so EVERY command-substitution-into-assignment here is `|| true`-guarded and
# every helper returns 0 — otherwise an empty `grep`/failed `curl`/down `docker exec` would
# errexit-ABORT diagnose mid-run and swallow real findings (the check 40 `|| true` lesson).
#
# Routine run is cheap (schema/registry/code only, no model load). Under EMBEDDING_DIM_DEEP=1
# (or DOCTOR_ALL=1) it ALSO does a live 1-vector round-trip per consumer and asserts the EMITTED
# vector length == store dim — catching a route that silently emits the wrong dim (e.g. a cloud
# route missing its `dimensions` param). The round-trip only touches EMBEDDERS (never a chat
# model), and is opt-in so routine doctor never cold-starts.
#
# FAMILY STAMP (closes tracked follow-up "3c", the §24 strongest-objection). Dim equality does
# NOT prove a store is queryable: embed-nomic and embed-openai-small-768 are BOTH 768 but are
# different vector SPACES. Re-pointing docs between them + `install 06` (which re-bakes
# EMBED_MODEL, satisfying the code-drift guard above) but FORGETTING the re-index left the store
# full of old-geometry vectors while queries embedded in the new one — total recall collapse,
# everything green. So ingest.py now stamps the models.yml registry key of the embedder that
# produced each vector into that same point's payload (`embedder`, excluded from the embedded
# text so it cannot pollute the space it audits), and this check counts, via the Qdrant count
# API, any point NOT carrying the assigned embedder. Provenance rides in the same write as the
# vector, so it cannot drift from what it describes and it dies with the collection.
# Semantics: entirely-unstamped store (pre-dates the stamp) = SKIP-CLEAN; any wrong-family point
# = FAIL; a partially-stamped store = FAIL (mixed geometry from a partial re-index).
# RESIDUAL, honestly scoped: honcho gets NO family stamp — it owns its embedding pipeline
# upstream, so stamping its writes means patching code that an upgrade overwrites. Its dim guard
# + boot validator cover the dim case; a same-dim family swap on honcho is still only caught by
# the documented re-index runbook (doc/TROUBLESHOOTING.md).
CHECKS+=(embedding_dim)
CHECK_TITLE[embedding_dim]="Embedding dim + family consistency: live store dim == assigned model dim AND the embedder that populated it == the assigned one (canonical target 768; skip-clean when a store is absent/unstamped)"

_edc_models_yml() { echo "${AI_STACK:-$HOME/ai-stack}/installer/models.yml"; }

# dim assigned to a service via models.yml (.embedding_assignments.<svc> -> .embeddings[m].dim)
_edc_assigned_dim() {
  local svc="$1" my; my="$(_edc_models_yml)"
  yq -r "(.embedding_assignments.${svc} // \"\") as \$k | .embeddings[\$k].dim // \"\"" "$my" 2>/dev/null || true
}
_edc_assigned_model() {
  local svc="$1" my; my="$(_edc_models_yml)"
  yq -r ".embedding_assignments.${svc} // \"\"" "$my" 2>/dev/null || true
}
_edc_route_for() {
  local model="$1" my; my="$(_edc_models_yml)"
  yq -r ".embeddings[\"${model}\"].route // \"\"" "$my" 2>/dev/null || true
}

# ai-stack-docs live vector size, or "" when the collection/qdrant is absent/unreachable.
_edc_qdrant_dim() {
  local url body; url="${QDRANT_URL:-http://qdrant:6333}"
  body="$(curl -s --max-time 4 "$url/collections/ai-stack-docs" 2>/dev/null || true)"
  [[ -z "$body" ]] && { echo ""; return 0; }
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get("result")
    if not r: print(""); sys.exit()
    v = r["config"]["params"]["vectors"]
    if isinstance(v, dict) and "size" in v: print(v["size"])
    elif isinstance(v, dict) and v:        print(next(iter(v.values())).get("size",""))
    else: print("")
except Exception:
    print("")
' 2>/dev/null || true
}

# Exact ai-stack-docs point count under an optional Qdrant JSON filter (pass "" for all).
# Echoes an integer, or "" when qdrant/the collection is absent/unreachable (-> SKIP, never FAIL:
# a down store must not be reported as a family violation).
_edc_qdrant_count() {
  local filter="${1:-}" url payload body
  url="${QDRANT_URL:-http://qdrant:6333}"
  if [[ -z "$filter" ]]; then payload='{"exact":true}'; else payload="{\"exact\":true,\"filter\":${filter}}"; fi
  body="$(curl -s --max-time 4 -X POST "$url/collections/ai-stack-docs/points/count" \
          -H 'content-type: application/json' -d "$payload" 2>/dev/null || true)"
  [[ -z "$body" ]] && { echo ""; return 0; }
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
    r = d.get("result")
    print(r["count"] if r and "count" in r else "")
except Exception:
    print("")
' 2>/dev/null || true
}

# distinct pgvector dims across honcho base-table embedding columns (relkind=r filters out the
# HNSW *index* relations which otherwise surface as vector columns). "" when honcho DB is absent.
_edc_honcho_dims() {
  docker exec honcho-database-1 psql -U postgres -d postgres -tAc "
    SELECT DISTINCT COALESCE(NULLIF(regexp_replace(format_type(a.atttypid,a.atttypmod),'[^0-9]','','g'),''),'unbounded')
    FROM pg_attribute a
    JOIN pg_class c ON c.oid=a.attrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE c.relkind='r' AND n.nspname='public'
      AND c.relname IN ('documents','message_embeddings')
      AND a.attname='embedding' AND NOT a.attisdropped;" 2>/dev/null | tr -d ' ' | grep -v '^$' || true
}

# EMBED_DIM literal baked into the deployed ingest.py (the code that populates the collection).
_edc_ingest_dim() {
  local f="${AI_STACK:-$HOME/ai-stack}/ingestor/ingest.py"
  [[ -f "$f" ]] || { echo ""; return 0; }
  grep -oE '^EMBED_DIM[[:space:]]*=[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+$' || true
}

# EMBED_MODEL (litellm route) baked into the deployed ingest.py.
_edc_ingest_model() {
  local f="${AI_STACK:-$HOME/ai-stack}/ingestor/ingest.py"
  [[ -f "$f" ]] || { echo ""; return 0; }
  grep -oE '^EMBED_MODEL[[:space:]]*=[[:space:]]*"[^"]*"' "$f" 2>/dev/null | grep -oE '"[^"]*"$' | tr -d '"' || true
}

# DEEP: emitted vector length for a litellm embedding route. Returns:
#   "<n>"     emitted length n (200 OK)
#   "ERR:<c>" the route errored (HTTP <c>, e.g. 400 invalid-model / 401 auth) -> a FAIL signal
#   ""        unreachable / no key / timeout / malformed -> SKIP (do not fail on infra-down)
_edc_emitted_len() {
  local route="$1" key resp code bodyj len
  key="$(get_env LITELLM_MASTER_KEY '' 2>/dev/null || true)"
  [[ -n "$key" && -n "$route" ]] || { echo ""; return 0; }
  resp="$(curl -s --max-time 40 -w $'\n%{http_code}' "http://litellm:4000/v1/embeddings" \
        -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
        -d "{\"model\":\"$route\",\"input\":\"doctor dim probe\"}" 2>/dev/null || true)"
  [[ -z "$resp" ]] && { echo ""; return 0; }
  code="$(printf '%s' "$resp" | tail -1)"
  bodyj="$(printf '%s' "$resp" | sed '$d')"
  if [[ "$code" == "200" ]]; then
    len="$(printf '%s' "$bodyj" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(len(d["data"][0]["embedding"]) if "data" in d else "")
except Exception: print("")' 2>/dev/null || true)"
    echo "$len"
  elif [[ "$code" =~ ^[0-9]+$ ]]; then
    echo "ERR:$code"
  else
    echo ""
  fi
  return 0
}

embedding_dim_diagnose() {
  command -v yq >/dev/null 2>&1 || { echo "(yq not available — cannot read models.yml assignments; skip)"; return 0; }
  local fails=() notes=()
  local deep=0
  [[ "${EMBEDDING_DIM_DEEP:-0}" == "1" || "${DOCTOR_ALL:-0}" == "1" ]] && deep=1

  # ---- docs (Qdrant ai-stack-docs) ----
  local docs_dim docs_model docs_route
  docs_dim="$(_edc_assigned_dim docs || true)"
  docs_model="$(_edc_assigned_model docs || true)"
  docs_route="$(_edc_route_for "$docs_model" || true)"
  if [[ "$docs_dim" =~ ^[0-9]+$ ]]; then
    local qd; qd="$(_edc_qdrant_dim || true)"
    if [[ -z "$qd" ]]; then
      notes+=("  docs: Qdrant ai-stack-docs absent/unreachable — skip (assigned dim=$docs_dim, not yet populated)")
    elif [[ "$qd" != "$docs_dim" ]]; then
      fails+=("  docs: Qdrant ai-stack-docs vector size=$qd != assigned $docs_model dim=$docs_dim — recreate the collection (AI_STACK_FORCE_RECREATE=1 ingest) after 'install 06'")
    fi
    # deployed ingest.py must agree with the assigned dim (else next populate writes wrong-dim vectors)
    local idim; idim="$(_edc_ingest_dim || true)"
    if [[ -n "$idim" && "$idim" != "$docs_dim" ]]; then
      fails+=("  docs: deployed ingestor/ingest.py EMBED_DIM=$idim != assigned dim=$docs_dim — re-run 'vz-ai-stack.sh install 06' to re-bake ingest.py/mcp_server.py")
    fi
    # deployed ingest.py EMBED_MODEL must equal the assigned route (family-drift: registry re-pointed
    # to a same-dim different-family embedder but 'install 06' not re-run).
    local imodel; imodel="$(_edc_ingest_model || true)"
    if [[ -n "$imodel" && -n "$docs_route" && "$imodel" != "$docs_route" ]]; then
      fails+=("  docs: deployed ingestor/ingest.py EMBED_MODEL=$imodel != assigned route=$docs_route — re-run 'vz-ai-stack.sh install 06' (registry↔deployed embedder-family drift)")
    fi
    # ---- FAMILY STAMP ("3c"): which embedder ACTUALLY populated the store? ----
    # The two guards above are satisfied by `install 06` alone; only this one needs the
    # RE-INDEX to have actually happened. Counts are exact and filter-side (no vectors move).
    local n_total n_bad n_unstamped
    n_total="$(_edc_qdrant_count "" || true)"
    if [[ "$n_total" =~ ^[0-9]+$ ]] && (( n_total > 0 )) && [[ -n "$docs_model" ]]; then
      # not-assigned = wrong-family points PLUS unstamped points (a missing field can't match)
      n_bad="$(_edc_qdrant_count "{\"must_not\":[{\"key\":\"embedder\",\"match\":{\"value\":\"${docs_model}\"}}]}" || true)"
      n_unstamped="$(_edc_qdrant_count '{"must":[{"is_empty":{"key":"embedder"}}]}' || true)"
      if [[ "$n_bad" =~ ^[0-9]+$ && "$n_unstamped" =~ ^[0-9]+$ ]]; then
        local n_wrongfam=$(( n_bad - n_unstamped ))
        if (( n_unstamped == n_total )); then
          notes+=("  docs: ai-stack-docs holds $n_total points with NO embedder family stamp (populated before the stamp existed) — skip; re-index to stamp them and arm the family guard")
        elif (( n_wrongfam > 0 )); then
          fails+=("  docs: $n_wrongfam/$n_total points in ai-stack-docs were embedded by an embedder OTHER than the assigned '$docs_model' — same dim != same vector space, so every query silently retrieves noise. RE-INDEX (the one step 'install 06' does NOT do): cp -R ingestor/processed/* ingestor/inbox/ && cd ingestor && AI_STACK_FORCE_RECREATE=1 .venv/bin/python ingest.py && bash bin/start-docs_mcp.sh")
        elif (( n_unstamped > 0 )); then
          fails+=("  docs: ai-stack-docs is MIXED provenance — $n_unstamped/$n_total points carry no family stamp alongside stamped '$docs_model' points (a partial re-index left two geometries in one collection). Re-index the WHOLE corpus with AI_STACK_FORCE_RECREATE=1")
        fi
      fi
    fi
  else
    notes+=("  docs: no resolvable assigned-model dim in models.yml — skip")
  fi

  # ---- honcho (pgvector) ----
  local honcho_dim honcho_model
  honcho_dim="$(_edc_assigned_dim honcho || true)"
  honcho_model="$(_edc_assigned_model honcho || true)"
  if [[ "$honcho_dim" =~ ^[0-9]+$ ]]; then
    local hdims; hdims="$(_edc_honcho_dims || true)"
    if [[ -z "$hdims" ]]; then
      notes+=("  honcho: pgvector DB absent/unreachable — skip (assigned dim=$honcho_dim)")
    else
      local d
      while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        if [[ "$d" != "$honcho_dim" ]]; then
          fails+=("  honcho: pgvector embedding column dim=$d != assigned $honcho_model dim=$honcho_dim — reconcile via honcho scripts/configure_embeddings.py (EMBEDDING_VECTOR_DIMENSIONS=$honcho_dim)")
        fi
      done <<< "$hdims"
    fi
  else
    notes+=("  honcho: no resolvable assigned-model dim in models.yml — skip")
  fi

  # ---- DEEP: live emitted-length round-trip (opt-in; embedders only, never a chat model) ----
  if (( deep )); then
    local svc
    for svc in docs honcho; do
      local adim amodel aroute elen
      adim="$(_edc_assigned_dim "$svc" || true)"
      amodel="$(_edc_assigned_model "$svc" || true)"
      aroute="$(_edc_route_for "$amodel" || true)"
      [[ "$adim" =~ ^[0-9]+$ && -n "$aroute" ]] || continue
      elen="$(_edc_emitted_len "$aroute" || true)"
      if [[ -z "$elen" ]]; then
        notes+=("  $svc: DEEP round-trip could not reach route '$aroute' (litellm down or no key) — skip")
      elif [[ "$elen" == ERR:* ]]; then
        fails+=("  $svc: LIVE route '$aroute' errored (HTTP ${elen#ERR:}) — route not live/misconfigured (a consumer on it would emit into a mismatched store)")
      elif [[ "$elen" != "$adim" ]]; then
        fails+=("  $svc: LIVE route '$aroute' emits len=$elen != assigned dim=$adim — the route/model is misconfigured (a store at $adim would reject every insert)")
      fi
    done
  else
    notes+=("  (schema/registry/code check only; set EMBEDDING_DIM_DEEP=1 for the LIVE emitted-vector-length round-trip)")
  fi

  (( ${#notes[@]} > 0 )) && printf '%s\n' "${notes[@]}"
  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

embedding_dim_fix() {
  warn "Embedding dim/family disparity: a live store's vector dim — or the embedder that actually populated it — != its assigned model (models.yml)."
  warn "  docs   -> flip models.yml .embedding_assignments.docs, 'install 06', then recreate ai-stack-docs (AI_STACK_FORCE_RECREATE=1)."
  warn "  docs (family) -> 'install 06' re-bakes the code but NEVER re-embeds. A same-dim family swap needs a full RE-INDEX:"
  warn "                   cp -R ingestor/processed/* ingestor/inbox/ && cd ingestor && AI_STACK_FORCE_RECREATE=1 .venv/bin/python ingest.py"
  warn "                   then 'bash bin/start-docs_mcp.sh' — docs_mcp caches its index handle and returns 0 hits until restarted."
  warn "  honcho -> set EMBEDDING_VECTOR_DIMENSIONS to the assigned dim + run honcho scripts/configure_embeddings.py --yes (wired via 'install honcho_mcp')."
  return 1
}
