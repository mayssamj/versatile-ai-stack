# MetaGPT (Phase 32): host-venv multi-agent software-company sim. OPT-IN — skips
# clean when Phase 32 hasn't run. PASS requires: venv + import + bin wrapper +
# a scoped LiteLLM key that actually lists models (a stale/revoked key returns
# 200 + empty data[], so we require a real "id"). A down key-store DB is reported
# as "heal the DB" (check 05a), NOT "re-mint" — re-minting against a dead DB fails.
CHECKS+=(metagpt)
CHECK_TITLE[metagpt]="MetaGPT venv + scoped LiteLLM key (Phase 32)"

metagpt_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_32*.done" >/dev/null 2>&1; then
    echo "MetaGPT not installed in this stack — Phase 32 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local venv="$AI_STACK/metagpt/.venv"
  [[ -x "$venv/bin/metagpt" ]] || { echo "metagpt venv missing ($venv) — re-run 'vz-ai-stack.sh install 32'"; return 1; }
  "$venv/bin/python" -c "import metagpt" >/dev/null 2>&1 || { echo "import metagpt failed in the venv — re-run 'vz-ai-stack.sh install 32'"; return 1; }
  [[ -x "$AI_STACK/bin/metagpt" ]] || { echo "bin/metagpt wrapper missing — re-run 'vz-ai-stack.sh install 32'"; return 1; }

  local key; key="$(get_env METAGPT_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "METAGPT_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 32'"; return 1; }
  local models
  models="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'vz-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "METAGPT_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'vz-ai-stack.sh install 32'"
    return 1
  fi
  # Allow-list assertion: /v1/models passing only proves the key lists SOME model — a key
  # still scoped to an OLD alias after a model rename/re-assign passes the probe yet
  # SILENT-403s the model the sim actually calls. Resolve the bound model the way phase 32
  # does (models.yml assignment, else local-gemma4) and verify the key ALLOWS it. Self-
  # lookup (Bearer = the scoped key, no ?key= in URL); metadata read only — never cold-
  # starts. Skips on yq-absent / wildcard / empty([]/=unrestricted) / unparseable / down.
  if command -v yq >/dev/null 2>&1; then
    local want
    want="$(yq -r '.assignments.metagpt // ""' "$AI_STACK/installer/models.yml" 2>/dev/null || true)"
    [[ -n "$want" && "$want" != "null" ]] || want="local-gemma4"
    local allow
    allow="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/key/info 2>/dev/null || litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/key/info 2>/dev/null || true)"
    allow="$(printf '%s' "$allow" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
info=d.get("info")
if not isinstance(info,dict): sys.exit(0)
m=info.get("models") or []
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null || true)"
    if [[ -n "$allow" ]] && ! printf '%s\n' "$allow" | grep -qxF '__wildcard__' \
       && ! printf '%s\n' "$allow" | grep -qxF "$want"; then
      echo "METAGPT_LITELLM_KEY allow-list missing '$want' (the model MetaGPT calls) — stale key after a model rename/re-assign; re-run 'vz-ai-stack.sh install 32' to self-heal"
      return 1
    fi
  fi
  echo "MetaGPT ready (venv + import + scoped key lists models); run: bin/metagpt \"<brief>\""
  return 0
}

metagpt_fix() {
  echo "vz-ai-stack.sh install 32   # rebuild venv + re-mint scoped key + refresh bin/metagpt"
}
