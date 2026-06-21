#!/usr/bin/env bash
# embeddings.sh — declarative embedding-model <-> service binding.
#
#   installer/models.yml is the CANONICAL source of truth. The `embeddings:` map
#   is the registry; `embedding_assignments:` binds one embedder per service. The
#   owning phases READ their assignment at install time (with the phase's current
#   hardcoded value as the fallback), so a re-install honors a re-point here.
#
#     vz-ai-stack.sh embedding list  [--json]               READ-ONLY registry + assignments
#     vz-ai-stack.sh embedding show  [<service>]            assignment(s) + consistency check
#     vz-ai-stack.sh embedding assign <service> <model> [--dry-run] [--force]
#     vz-ai-stack.sh embedding global <model> [--dry-run] [--force]
#
# House style mirrors lib/models.sh (its sibling for CHAT models): source the
# libs, simple dispatch, log/ok/warn/err from common.sh, atomic `yq -i` writes
# (temp+mv via a .bak), membership tests that capture-then-grep (pipefail-safe).
#
# WHY a GUARD (the load-bearing safety, per the adversarial critique):
#   1. The docs service is COUPLED — ingest.py (writes) and mcp_server.py (reads)
#      both target the SAME Qdrant collection `ai-stack-docs`, pinned to one
#      vector dimension. Re-pointing docs to an embedder of a DIFFERENT dim is a
#      one-way, data-destroying re-ingest (phase-06 ingest.py refuses it without
#      AI_STACK_FORCE_RECREATE=1). So assign refuses a docs dim change w/o --force.
#   2. `global` only fans out to GENERAL-TEXT, shareable services (docs+openwebui).
#      lumen is code-specific (its own on-disk index) and mempalace is on-device
#      (CoreML, no LiteLLM hop) — a blanket text embedder there is harmful, so
#      global REFUSES them unless --force.
#   3. A code-tuned embedder (kind: code) on a text service — or vice-versa —
#      degrades retrieval quality, so it WARNs (allowed with --force).
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

MODELS_YML="$AI_STACK/installer/models.yml"

# The services that carry an embedder assignment. Each maps to an owning phase
# whose `install <phase>` re-reads models.yml (see DURABILITY in those files):
#   docs      -> install 06   (ingest.py + mcp_server.py — the COUPLED pair)
#   openwebui -> bin/start-openwebui.sh (restart Open WebUI)
#   lumen     -> install 16   (code-specific; its own index)
#   mempalace -> install 26   (on-device CoreML embeddings)
#   honcho    -> install 03   (via LiteLLM OpenAI-compat transport)
EMBED_SERVICES=(docs openwebui lumen mempalace honcho)

# GENERAL-TEXT, shareable services that `global` is allowed to fan out to. lumen
# (code) + mempalace (on-device) are deliberately EXCLUDED (see GUARD #2).
GLOBAL_SAFE_SERVICES=(docs openwebui)

# ---------------------------------------------------------------------------
# 0. models.yml accessors (fail-closed; exit 2 if the file is missing/unparseable)
# ---------------------------------------------------------------------------
my_q() { yq -r "$1" "$MODELS_YML" 2>/dev/null; }

# Membership tests: capture yq output into a var FIRST, then grep the here-string.
# A direct `my_q ... | grep -qxF` dies under `set -o pipefail` — grep -q closes
# the pipe on first match, yq gets SIGPIPE (141), pipefail propagates it as a
# failure, making every lookup wrongly "not found". (Same idiom as models.sh.)
emb_exists() { local out; out="$(my_q '.embeddings | keys | .[]')"; grep -qxF "$1" <<<"$out"; }
svc_is_known() { local s; for s in "${EMBED_SERVICES[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }
svc_is_global_safe() { local s; for s in "${GLOBAL_SAFE_SERVICES[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

# Embedding-model field accessors (resolve from .embeddings.<name>.<field>).
emb_served()  { my_q ".embeddings.\"$1\".served"; }
emb_dim()     { my_q ".embeddings.\"$1\".dim"; }
emb_runtime() { my_q ".embeddings.\"$1\".runtime"; }
emb_kind()    { my_q ".embeddings.\"$1\".kind"; }
emb_via()     { my_q ".embeddings.\"$1\".via"; }
emb_route()   { my_q ".embeddings.\"$1\".route"; }
emb_device()  { my_q ".embeddings.\"$1\".device"; }
# unverified=true marks an entry whose `dim` is NOT pinned/confirmed against code
# (e.g. taken from a model card). Surfaced as a WARN on assign + in show.
emb_unverified() { [[ "$(my_q ".embeddings.\"$1\".unverified")" == "true" ]]; }

# Current assignment for a service (the model NAME, e.g. embed-nomic), or "".
svc_assigned() { local v; v="$(my_q ".embedding_assignments.\"$1\"")"; [[ "$v" == "null" ]] && v=""; echo "$v"; }

# validate — fail-closed. Exits 2 on any structural error in the embedding plane.
validate() {
  if [[ ! -f "$MODELS_YML" ]]; then
    err "installer/models.yml not found at $MODELS_YML"; return 2
  fi
  if ! yq eval '.' "$MODELS_YML" >/dev/null 2>&1; then
    err "installer/models.yml is not valid YAML"; return 2
  fi
  # The embeddings registry must exist and be non-empty.
  local n; n="$(my_q '.embeddings | length')"
  if [[ -z "$n" || "$n" == "null" || "$n" == "0" ]]; then
    err "models.yml: .embeddings registry is missing/empty"; return 2
  fi
  # Every embedding entry must declare runtime + served + dim + kind, runtime in
  # {ollama,onnx,openai}, kind in {text,code}, dim a positive integer.
  local m rt sv dm kd vi ro
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(emb_runtime "$m")"; sv="$(emb_served "$m")"; dm="$(emb_dim "$m")"; kd="$(emb_kind "$m")"; vi="$(emb_via "$m")"
    case "$rt" in ollama|onnx|openai) : ;; *) err "models.yml: embedding '$m' has invalid runtime '$rt' (want ollama|onnx|openai)"; return 2 ;; esac
    case "$kd" in text|code) : ;; *) err "models.yml: embedding '$m' has invalid kind '$kd' (want text|code)"; return 2 ;; esac
    [[ -n "$sv" && "$sv" != "null" ]] || { err "models.yml: embedding '$m' missing .served"; return 2; }
    # `served` is interpolated into shell/grep/docker contexts downstream; restrict
    # it to a safe charset so a malformed id fails HERE (fail-closed) instead of
    # silently aborting a phase via a broken grep/pull. Covers ollama, HF-namespaced,
    # MLX (@), and OpenAI ids (alnum . _ / : @ -).
    [[ "$sv" =~ ^[a-zA-Z0-9_./:@-]+$ ]] || { err "models.yml: embedding '$m' .served '$sv' has unsafe characters (want [a-zA-Z0-9_./:@-])"; return 2; }
    [[ "$dm" =~ ^[1-9][0-9]*$ ]] || { err "models.yml: embedding '$m' has invalid .dim '$dm' (want a positive integer)"; return 2; }
    case "$vi" in litellm|ollama|ondevice) : ;; *) err "models.yml: embedding '$m' has invalid via '$vi' (want litellm|ollama|ondevice)"; return 2 ;; esac
    # A LiteLLM-routed embedder MUST name its config.yaml route (a downstream
    # reader resolves the model_name from it) — fail closed, like the rest.
    if [[ "$vi" == "litellm" ]]; then
      ro="$(emb_route "$m")"
      [[ -n "$ro" && "$ro" != "null" ]] || { err "models.yml: embedding '$m' is via:litellm but has no .route (the litellm/config.yaml model_name)"; return 2; }
    fi
  done < <(my_q '.embeddings | keys | .[]')

  # Every assignment must reference a KNOWN service and a DECLARED embedding model.
  local a am
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    if ! svc_is_known "$a"; then
      err "models.yml: embedding_assignments has unknown service '$a' (want: ${EMBED_SERVICES[*]})"; return 2
    fi
    am="$(svc_assigned "$a")"
    if ! emb_exists "$am"; then
      err "models.yml: service '$a' assigned undeclared embedding '$am'"; return 2
    fi
  done < <(my_q '.embedding_assignments | keys | .[]')
  return 0
}

# owning_phase <service> — the human apply step printed after an assign (the phase
# re-reads models.yml). openwebui is a bin/ restart, not a numbered phase.
owning_phase() {
  case "$1" in
    docs)      echo "vz-ai-stack.sh install 06   (re-runs ingest.py + mcp_server.py)" ;;
    openwebui) echo "bash bin/start-openwebui.sh   (restart Open WebUI)" ;;
    lumen)     echo "vz-ai-stack.sh install 16   (re-pulls + re-points Lumen)" ;;
    mempalace) echo "vz-ai-stack.sh install 26   (re-renders the mempalace wrapper)" ;;
    honcho)    echo "vz-ai-stack.sh install 03   (re-points honcho via LiteLLM)" ;;
    *)         echo "vz-ai-stack.sh install <owning-phase>" ;;
  esac
}

# coupling_note <service> — the one-line caveat shown in list/show.
coupling_note() {
  case "$1" in
    docs)      echo "COUPLED: ingest.py + mcp_server.py share the Qdrant 'ai-stack-docs' collection (dim-pinned)" ;;
    openwebui) echo "general-purpose RAG embedder (Ollama-served)" ;;
    lumen)     echo "code-specific; Lumen keeps its OWN on-disk index" ;;
    mempalace) echo "ON-DEVICE (CoreML, no LiteLLM hop); minilm/embeddinggemma both yield 384-dim at runtime" ;;
    honcho)    echo "RECORDED ONLY (no phase reads it yet); honcho embeds via the LiteLLM OpenAI-compat transport" ;;
    *)         echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. list (READ-ONLY)
# ---------------------------------------------------------------------------
cmd_list() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  validate || exit $?

  if (( json )); then
    # Machine-readable: the registry + per-service assignment overlay.
    yq -o=json '{"embeddings": .embeddings, "embedding_assignments": .embedding_assignments}' "$MODELS_YML"
    return 0
  fi

  hdr "Embedding registry (installer/models.yml .embeddings)"
  printf '  %-20s %-34s %-6s %-9s %-6s %s\n' NAME SERVED DIM RUNTIME KIND VIA
  local m
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    local via="$(emb_via "$m")" route="$(emb_route "$m")"
    [[ "$route" != "null" && -n "$route" ]] && via="$via:$route"
    printf '  %-20s %-34s %-6s %-9s %-6s %s\n' \
      "$m" "$(emb_served "$m")" "$(emb_dim "$m")" "$(emb_runtime "$m")" "$(emb_kind "$m")" "$via"
  done < <(my_q '.embeddings | keys | .[]')

  hdr "Per-service assignment"
  printf '  %-12s %-20s %-6s %-6s %s\n' SERVICE EMBEDDER DIM KIND NOTE
  local s a
  for s in "${EMBED_SERVICES[@]}"; do
    a="$(svc_assigned "$s")"
    if [[ -z "$a" ]]; then
      printf '  %-12s %-20s %-6s %-6s %s\n' "$s" "(unset -> phase default)" "-" "-" "$(coupling_note "$s")"
    else
      printf '  %-12s %-20s %-6s %-6s %s\n' "$s" "$a" "$(emb_dim "$a")" "$(emb_kind "$a")" "$(coupling_note "$s")"
    fi
  done
  printf '\n  Apply a change with the owning phase, e.g.:  %s\n' "$(owning_phase docs)"
  note "DIM is load-bearing for 'docs' (the Qdrant collection is pinned). 'global' targets only: ${GLOBAL_SAFE_SERVICES[*]}."
  return 0
}

# ---------------------------------------------------------------------------
# 2. show (READ-ONLY) — assignment(s) + a consistency check
# ---------------------------------------------------------------------------
# consistency_check <service> — WARN (advisory) on the known footguns; never
# fails. Echoes a count of issues via the global _CC_ISSUES (caller may read it).
consistency_check() {
  local s="$1" a kd
  _CC_ISSUES=0
  a="$(svc_assigned "$s")"
  if [[ -z "$a" ]]; then
    note "$s: no explicit assignment — the owning phase uses its built-in default"
    return 0
  fi
  if ! emb_exists "$a"; then
    warn "$s: assigned '$a' is NOT in the embeddings registry (would break the phase read)"; _CC_ISSUES=$((_CC_ISSUES+1)); return 0
  fi
  kd="$(emb_kind "$a")"
  # docs: the registry dim must equal the value phase-06 pins (768 today). A
  # mismatch means a destructive re-ingest is pending.
  if [[ "$s" == "docs" && "$(emb_dim "$a")" != "768" ]]; then
    warn "$s: assigned '$a' is dim=$(emb_dim "$a") but the docs collection is pinned to 768 — re-ingest with AI_STACK_FORCE_RECREATE=1 required"; _CC_ISSUES=$((_CC_ISSUES+1))
  fi
  # text services carrying a code-tuned embedder (or the reverse) → advisory.
  if [[ "$kd" == "code" && "$s" != "lumen" ]]; then
    warn "$s: assigned a code-tuned embedder ('$a') for a general-text service — retrieval quality may degrade"; _CC_ISSUES=$((_CC_ISSUES+1))
  fi
  if emb_unverified "$a"; then
    warn "$s: assigned '$a' whose dim=$(emb_dim "$a") is UNVERIFIED (not pinned against code) — confirm the real vector size before trusting a dim-pinned service"; _CC_ISSUES=$((_CC_ISSUES+1))
  fi
  if [[ "$kd" == "text" && "$s" == "lumen" ]]; then
    warn "$s: Lumen is code-search but '$a' is a text embedder — code retrieval may degrade"; _CC_ISSUES=$((_CC_ISSUES+1))
  fi
  (( _CC_ISSUES == 0 )) && ok "$s -> $a (dim=$(emb_dim "$a"), kind=$kd) — consistent"
  return 0
}

cmd_show() {
  validate || exit $?
  local svc="${1:-}"
  if [[ -n "$svc" ]]; then
    if ! svc_is_known "$svc"; then
      err "unknown service '$svc' (want: ${EMBED_SERVICES[*]})"; exit 2
    fi
    hdr "Embedding assignment — $svc"
    local a; a="$(svc_assigned "$svc")"
    printf '  service:  %s\n' "$svc"
    printf '  embedder: %s\n' "${a:-(unset -> phase default)}"
    if [[ -n "$a" ]]; then
      printf '  served:   %s\n' "$(emb_served "$a")"
      printf '  dim:      %s\n' "$(emb_dim "$a")"
      printf '  runtime:  %s\n' "$(emb_runtime "$a")"
      printf '  kind:     %s\n' "$(emb_kind "$a")"
    fi
    printf '  coupling: %s\n' "$(coupling_note "$svc")"
    printf '  apply:    %s\n' "$(owning_phase "$svc")"
    consistency_check "$svc"
    return 0
  fi
  hdr "Embedding assignments — all services"
  local s
  for s in "${EMBED_SERVICES[@]}"; do consistency_check "$s"; done
  return 0
}

# ---------------------------------------------------------------------------
# 3. GUARD — the load-bearing safety, shared by assign + global
# ---------------------------------------------------------------------------
# guard_assignment <service> <model> <force> — returns 0 to PROCEED, 1 to REFUSE.
# WARNs are advisory (proceed); a REFUSE prints the reason + the --force hint and
# returns 1. `force`=1 downgrades every refusal to a warning.
guard_assignment() {
  local svc="$1" model="$2" force="$3"
  local new_dim new_kind cur cur_dim
  new_dim="$(emb_dim "$model")"; new_kind="$(emb_kind "$model")"
  cur="$(svc_assigned "$svc")"

  # GUARD #1 — docs is COUPLED + dim-pinned. A dim change is destructive.
  if [[ "$svc" == "docs" ]]; then
    # Compare against the CURRENT assignment's dim (fallback to 768 — the value
    # phase-06 ingest.py pins today — when docs is unset, so a first-time assign
    # to a non-768 embedder still trips the guard).
    cur_dim=768
    [[ -n "$cur" ]] && emb_exists "$cur" && cur_dim="$(emb_dim "$cur")"
    if [[ "$new_dim" != "$cur_dim" ]]; then
      if [[ "$force" == "1" ]]; then
        warn "docs: dim change ${cur_dim} -> ${new_dim} (--force). Re-ingest is REQUIRED: re-run ingest with AI_STACK_FORCE_RECREATE=1 or the phase-06 ingest.py will refuse and abort."
      else
        err "REFUSED: docs is COUPLED — ingest.py + mcp_server.py share the Qdrant 'ai-stack-docs' collection pinned to dim=${cur_dim}, but '$model' is dim=${new_dim}."
        err "  Changing it is a ONE-WAY, data-destroying re-ingest. The phase-06 ingest.py enforces this — it aborts unless you re-ingest with AI_STACK_FORCE_RECREATE=1."
        err "  Re-run with --force to record the assignment anyway (you must then re-ingest with AI_STACK_FORCE_RECREATE=1)."
        return 1
      fi
    fi
  fi

  # GUARD #3 — kind mismatch (code embedder on a text service, or text on lumen).
  # Advisory only (never blocks); --force silences it (the message says so, so it
  # must actually honor it — otherwise the hint lies). The mismatch still stands;
  # we just don't nag when the operator has explicitly opted in.
  if [[ "$force" != "1" ]]; then
    if [[ "$new_kind" == "code" && "$svc" != "lumen" ]]; then
      warn "$svc: '$model' is a CODE-tuned embedder (kind: code) on a general-text service — retrieval quality may degrade. (proceeding; pass --force to silence)"
    fi
    if [[ "$new_kind" == "text" && "$svc" == "lumen" ]]; then
      warn "lumen: '$model' is a TEXT embedder (kind: text) but Lumen is CODE search — code retrieval may degrade. (proceeding; pass --force to silence)"
    fi
    # UNVERIFIED dim — advisory; the dim guard for docs still uses it, so flag it.
    if emb_unverified "$model"; then
      warn "$svc: '$model' has an UNVERIFIED dim=${new_dim} (not pinned against code) — confirm the real vector size. (proceeding; pass --force to silence)"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4. assign — write .embedding_assignments.<service> atomically
# ---------------------------------------------------------------------------
cmd_assign() {
  local svc="" model="" dry=0 force=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --force)   force=1 ;;
      -*) err "assign: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$svc" ]]; then svc="$a"; elif [[ -z "$model" ]]; then model="$a"; fi ;;
    esac
  done
  validate || exit $?
  if [[ -z "$svc" || -z "$model" ]]; then
    err "usage: vz-ai-stack.sh embedding assign <service> <model> [--dry-run] [--force]"
    err "  services: ${EMBED_SERVICES[*]}"
    exit 2
  fi
  if ! svc_is_known "$svc"; then
    err "unknown service '$svc' (want: ${EMBED_SERVICES[*]})"; exit 2
  fi
  if ! emb_exists "$model"; then
    err "unknown embedding model '$model'. Valid embedders:"
    my_q '.embeddings | keys | .[]' | sed 's/^/    /' >&2
    exit 2
  fi

  local before; before="$(svc_assigned "$svc")"

  # No-op fast path: assigning the model that's already bound changes nothing, so
  # don't write a .bak or imply a re-ingest/apply is needed. (Idempotent + honest.)
  if [[ "$before" == "$model" ]]; then
    ok "$svc is already assigned '$model' — nothing to do (no write, no apply needed)"
    return 0
  fi

  note "assign embedding: $svc  ${before:-(unset)} -> $model  (dim=$(emb_dim "$model"), kind=$(emb_kind "$model"))"

  # Run the GUARD. A refusal (return 1) blocks the write unless --force.
  if ! guard_assignment "$svc" "$model" "$force"; then
    exit 2
  fi

  if (( dry )); then
    note "[dry-run] would set embedding_assignments.$svc: ${before:-(unset)} -> $model (no write)"
    note "[dry-run] apply step would be: $(owning_phase "$svc")"
    exit 0
  fi

  # Atomic write: back up first (rollback path), then a single in-place yq set.
  cp -p "$MODELS_YML" "$MODELS_YML.bak" 2>/dev/null || true
  if ! SVC="$svc" MODEL="$model" yq -i '.embedding_assignments[strenv(SVC)] = strenv(MODEL)' "$MODELS_YML"; then
    err "yq -i set embedding assignment failed — models.yml unchanged (restore: cp $MODELS_YML.bak $MODELS_YML)"
    exit 1
  fi
  ok "embedding_assignments.$svc: ${before:-(unset)} -> $model  (prior models.yml backed up to $(basename "$MODELS_YML").bak)"
  note "APPLY (the phase re-reads models.yml): $(owning_phase "$svc")"
  return 0
}

# ---------------------------------------------------------------------------
# 5. global — assign one embedder to the GENERAL-TEXT shareable services
# ---------------------------------------------------------------------------
# Fans out to docs + openwebui only. REFUSES lumen + mempalace (harmful: lumen is
# code-specific, mempalace is on-device) unless --force. Enforces the GUARD per
# target. Writes ALL targets in ONE atomic yq -i.
cmd_global() {
  local model="" dry=0 force=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --force)   force=1 ;;
      -*) err "global: unknown flag '$a'"; exit 2 ;;
      *) [[ -z "$model" ]] && model="$a" ;;
    esac
  done
  validate || exit $?
  if [[ -z "$model" ]]; then
    err "usage: vz-ai-stack.sh embedding global <model> [--dry-run] [--force]"
    exit 2
  fi
  if ! emb_exists "$model"; then
    err "unknown embedding model '$model'. Valid embedders:"
    my_q '.embeddings | keys | .[]' | sed 's/^/    /' >&2
    exit 2
  fi

  # GUARD #2 (global-scope): a CODE-tuned embedder is never appropriate for the
  # general-text fan-out (it degrades prose retrieval on docs + openwebui). Refuse
  # the whole `global` outright unless --force. (Per-service `assign` only WARNs —
  # there a code embedder on lumen is correct; here every target is general-text.)
  if [[ "$(emb_kind "$model")" == "code" ]]; then
    if [[ "$force" != "1" ]]; then
      err "REFUSED: '$model' is a CODE-tuned embedder (kind: code) — 'global' fans out to GENERAL-TEXT services (${GLOBAL_SAFE_SERVICES[*]}), where a code embedder degrades retrieval."
      err "  Use 'embedding assign lumen $model' for code search, or re-run 'global' with --force to override."
      exit 2
    fi
    warn "global --force: '$model' is a CODE-tuned embedder being applied to general-text services — retrieval quality may degrade."
  fi

  # Build the target set. Default = GLOBAL_SAFE_SERVICES (docs + openwebui). With
  # --force, also fan out to the harmful targets (lumen + mempalace) — but state
  # loudly why each was excluded by default.
  local targets=("${GLOBAL_SAFE_SERVICES[@]}")
  if [[ "$force" == "1" ]]; then
    warn "global --force: also targeting lumen + mempalace (normally REFUSED)."
    warn "  lumen is code-specific (its own index) and mempalace is on-device (CoreML) — a general text embedder there can be harmful."
    targets=(docs openwebui lumen mempalace)
  else
    note "global: targeting ONLY the general-text shareable services: ${GLOBAL_SAFE_SERVICES[*]}"
    note "  REFUSING lumen (code-specific) + mempalace (on-device) — pass --force to include them."
  fi

  # GLOBAL DIM POLICY (council P1-A): a `global` --force is a CONVENIENCE override
  # for the lumen/mempalace SCOPE exclusion — it must NOT silently also force-past
  # the docs destructive-re-ingest guard. Those are two distinct intents and one
  # flag shouldn't conflate them. So if docs is a target and the model's dim
  # differs from docs' current dim, REFUSE the whole global outright (even under
  # --force) and direct the operator to the explicit, targeted, acknowledged path.
  local _docs_is_target=0 t
  for t in "${targets[@]}"; do [[ "$t" == "docs" ]] && _docs_is_target=1; done
  if (( _docs_is_target )); then
    local _gdim _cur _cdim=768
    _gdim="$(emb_dim "$model")"
    _cur="$(svc_assigned docs)"; [[ -n "$_cur" ]] && emb_exists "$_cur" && _cdim="$(emb_dim "$_cur")"
    if [[ "$_gdim" != "$_cdim" ]]; then
      err "REFUSED: 'global' would change the docs embedder dim ${_cdim} -> ${_gdim} — a one-way, data-destroying Qdrant re-ingest."
      err "  'global --force' overrides the lumen/mempalace SCOPE only, NOT the docs dim guard (two separate intents)."
      err "  Do it explicitly + acknowledged:  vz-ai-stack.sh embedding assign docs $model --force   (then re-ingest with AI_STACK_FORCE_RECREATE=1)"
      exit 2
    fi
  fi

  # Per-target GUARD (kind/unverified WARNs; the docs dim case is already handled
  # above). We pass the caller's --force through to silence the advisory WARNs.
  hdr "embedding global -> $model  (dim=$(emb_dim "$model"), kind=$(emb_kind "$model"))"
  local s blocked=0
  for s in "${targets[@]}"; do
    note "  target: $s  (${s}: $(svc_assigned "$s" | sed 's/^$/unset/') -> $model)"
    if ! guard_assignment "$s" "$model" "$force"; then
      blocked=1
    fi
  done
  if (( blocked )); then
    err "global aborted — at least one target was REFUSED by the GUARD above (pass --force to override)."
    exit 2
  fi

  if (( dry )); then
    note "[dry-run] would set embedding_assignments for: ${targets[*]} -> $model (no write)"
    local s2; for s2 in "${targets[@]}"; do note "[dry-run]   apply: $(owning_phase "$s2")"; done
    exit 0
  fi

  # ONE atomic yq -i over all targets (no half-written file on interrupt).
  cp -p "$MODELS_YML" "$MODELS_YML.bak" 2>/dev/null || true
  local expr="" s3
  for s3 in "${targets[@]}"; do
    [[ -n "$expr" ]] && expr+=" | "
    expr+=".embedding_assignments[\"$s3\"] = strenv(MODEL)"
  done
  if ! MODEL="$model" yq -i "$expr" "$MODELS_YML"; then
    err "global assign failed — models.yml unchanged (restore: cp $MODELS_YML.bak $MODELS_YML)"
    exit 1
  fi
  ok "embedding global: ${targets[*]} -> $model  (prior models.yml backed up to $(basename "$MODELS_YML").bak)"
  note "APPLY each target's owning phase:"
  local s4; for s4 in "${targets[@]}"; do note "  $(owning_phase "$s4")"; done
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  local sub="${1:-list}"
  shift || true
  case "$sub" in
    list)   cmd_list "$@" ;;
    show)   cmd_show "$@" ;;
    assign) cmd_assign "$@" ;;
    global) cmd_global "$@" ;;
    -h|--help|help)
      cat <<'EOF'
vz-ai-stack.sh embedding — declarative embedding-model<->service binding (installer/models.yml)
  embedding list [--json]                       READ-ONLY registry + per-service assignments
  embedding show [<service>]                    assignment(s) + a consistency check
  embedding assign <service> <model> [--dry-run] [--force]
                                                re-point ONE service (GUARDed; writes models.yml)
  embedding global <model> [--dry-run] [--force]
                                                assign to the general-text services (docs+openwebui);
                                                REFUSES lumen+mempalace unless --force

  services : docs openwebui lumen mempalace honcho
  GUARD    : (1) docs is dim-pinned to its Qdrant collection — a dim change is REFUSED
                 unless --force (then re-ingest with AI_STACK_FORCE_RECREATE=1);
             (2) global refuses lumen (code) + mempalace (on-device) unless --force;
             (3) a code embedder on a text service (or vice-versa) WARNs.
  apply    : the owning phase re-reads models.yml — e.g. `vz-ai-stack.sh install 06` for docs.
EOF
      ;;
    *) err "embedding: unknown subcommand '$sub' (want list|show|assign|global)"; exit 2 ;;
  esac
}

main "$@"
