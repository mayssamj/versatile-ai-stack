# LM Studio (MLX) wired as a second runtime behind LiteLLM (Phase 25).
#
# Opt-in. Passes (no-op) when LM Studio isn't installed. When installed, verifies
# the lms CLI + the OpenAI server on :1234 + that any models.yml-ASSIGNED lmstudio
# MLX slugs are wired into litellm/config.yaml. (`install lmstudio` is
# assignment-driven; the LFM2.5 `local-lfm2-mlx` demo is opt-in via LMS_LOAD_LFM2
# and is NOT required.) Does NOT run a (slow) model round-trip. NO secrets printed.
CHECKS+=(lmstudio)
CHECK_TITLE[lmstudio]="LM Studio (MLX) wired behind LiteLLM (Phase 25)"

lmstudio_diagnose() {
  # LM Studio is OPT-IN. Its server is a GUI/manual process (NOT a managed daemon
  # with a PID file), and `install all` does not start it. The .app also persists
  # in /Applications across `reset --hard`. So "installed but server down" is the
  # EXPECTED default state, not a fault — treat it as advisory (green) and only go
  # RED for a genuine misconfiguration: server IS up but LiteLLM isn't wired to it.
  if [[ ! -d "/Applications/LM Studio.app" ]]; then
    echo "  (LM Studio not installed — opt-in; run 'mayssam-ai-stack.sh install lmstudio' to add MLX behind LiteLLM)"
    return 0
  fi
  local lms=""
  [[ -x "$HOME/.lmstudio/bin/lms" ]] && lms="$HOME/.lmstudio/bin/lms"
  if [[ -z "$lms" ]]; then
    echo "  (LM Studio.app present but lms CLI not bootstrapped — opt-in; open the app once or re-run 'mayssam-ai-stack.sh install lmstudio')"
    return 0
  fi
  if ! curl -s -o /dev/null --max-time 4 "http://127.0.0.1:1234/v1/models" 2>/dev/null; then
    echo "  (LM Studio installed but server not running — opt-in; start it with '$lms server start -p 1234 --bind 0.0.0.0' or re-run 'install lmstudio')"
    return 0
  fi
  # Server is UP. NOTE: `install lmstudio` is ASSIGNMENT-DRIVEN — it wires only the
  # models.yml-assigned MLX slugs (checked below). The LFM2.5 `local-lfm2-mlx` demo
  # is OPT-IN (LMS_LOAD_LFM2=1), so it is NOT required here — its absence is normal,
  # not a fault (this used to false-RED a correct default install).
  local n
  n="$(curl -s --max-time 5 http://127.0.0.1:1234/v1/models 2>/dev/null | python3 -c 'import sys,json; print(sum(1 for m in json.load(sys.stdin).get("data",[]) if "embed" not in m["id"].lower()))' 2>/dev/null || echo 0)"
  echo "  (LM Studio server up on :1234, $n LLM(s) served; assignment-driven wiring checked below. A/B vs Ollama via Phoenix.)"

  # models.yml lmstudio slugs: when the server is up, the canonical MLX slugs
  # SHOULD be wired into config.yaml (registered by Phase 01 / 'model sync').
  # A missing slug is a real wiring gap (the assigned agents would 503).
  local yml="$AI_STACK/installer/models.yml" cfg="$AI_STACK/litellm/config.yaml" missing=()
  if [[ -f "$yml" ]] && command -v yq >/dev/null 2>&1; then
    local s
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      grep -qF "model_name: ${s}" "$cfg" 2>/dev/null || missing+=("$s")
    done < <(yq -r '.models | to_entries | .[] | select(.value.runtime == "lmstudio") | .key' "$yml" 2>/dev/null)
    if (( ${#missing[@]} > 0 )); then
      echo "server up on :1234 but models.yml lmstudio slug(s) NOT in config.yaml: ${missing[*]} — run 'mayssam-ai-stack.sh model sync'"
      return 1
    fi
  fi

  # RAM policy: the only MLX slug now is `local-nemotron3-nano-4b-mlx` (~3GB) — the
  # nemotron-only migration (2026-07-01) removed the big qwen MLX models, so the old
  # "two big MLX resident thrash a 24GB box" advisory no longer applies (nothing big
  # to coexist). Kept as a no-op comment for provenance.
  return 0
}

lmstudio_fix() {
  warn "Re-run the LM Studio phase (idempotent: starts the server, ensures the MLX model, re-wires LiteLLM):"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install lmstudio"
  return 1
}
