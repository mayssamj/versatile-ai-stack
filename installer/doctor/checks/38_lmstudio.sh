# LM Studio (MLX) wired as a second runtime behind LiteLLM (Phase 25).
#
# Opt-in. Passes (no-op) when LM Studio isn't installed. When installed, verifies
# the lms CLI + the OpenAI server on :1234 + the local-lfm2-mlx provider in
# litellm/config.yaml. Does NOT run a (slow) model round-trip — it only checks
# the wiring is in place. NO secrets printed.
CHECKS+=(lmstudio)
CHECK_TITLE[lmstudio]="LM Studio (MLX) wired behind LiteLLM (Phase 25)"

lmstudio_diagnose() {
  # LM Studio is OPT-IN. Its server is a GUI/manual process (NOT a managed daemon
  # with a PID file), and `install all` does not start it. The .app also persists
  # in /Applications across `reset --hard`. So "installed but server down" is the
  # EXPECTED default state, not a fault — treat it as advisory (green) and only go
  # RED for a genuine misconfiguration: server IS up but LiteLLM isn't wired to it.
  if [[ ! -d "/Applications/LM Studio.app" ]]; then
    echo "  (LM Studio not installed — opt-in; run 'vz-ai-stack.sh install lmstudio' to add MLX behind LiteLLM)"
    return 0
  fi
  local lms=""
  [[ -x "$HOME/.lmstudio/bin/lms" ]] && lms="$HOME/.lmstudio/bin/lms"
  if [[ -z "$lms" ]]; then
    echo "  (LM Studio.app present but lms CLI not bootstrapped — opt-in; open the app once or re-run 'vz-ai-stack.sh install lmstudio')"
    return 0
  fi
  if ! curl -s -o /dev/null --max-time 4 "http://127.0.0.1:1234/v1/models" 2>/dev/null; then
    echo "  (LM Studio installed but server not running — opt-in; start it with '$lms server start -p 1234 --bind 0.0.0.0' or re-run 'install lmstudio')"
    return 0
  fi
  # Server is UP — from here a wiring gap IS a real failure (the phase ran but
  # didn't finish wiring LiteLLM, so the running server is unusable by the stack).
  if ! grep -q 'model_name: local-lfm2-mlx\b' "$AI_STACK/litellm/config.yaml" 2>/dev/null; then
    echo "server up on :1234 but local-lfm2-mlx NOT wired into litellm/config.yaml — re-run 'vz-ai-stack.sh install lmstudio'"
    return 1
  fi
  local n
  n="$(curl -s --max-time 5 http://127.0.0.1:1234/v1/models 2>/dev/null | python3 -c 'import sys,json; print(sum(1 for m in json.load(sys.stdin).get("data",[]) if "embed" not in m["id"].lower()))' 2>/dev/null || echo 0)"
  echo "  (LM Studio server up on :1234, $n LLM(s) served; local-lfm2-mlx wired into LiteLLM. A/B vs Ollama via Phoenix.)"

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
      echo "server up on :1234 but models.yml lmstudio slug(s) NOT in config.yaml: ${missing[*]} — run 'vz-ai-stack.sh model sync'"
      return 1
    fi
  fi

  # one-big-MLX RAM policy: WARN (advisory, NOT red) if BOTH big MLX models are
  # resident at once — they're ~17GB each and cannot coexist on a 24GB box.
  local lms2=""
  [[ -x "$HOME/.lmstudio/bin/lms" ]] && lms2="$HOME/.lmstudio/bin/lms"
  if [[ -n "$lms2" ]]; then
    local loaded big_loaded
    loaded="$("$lms2" ps 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' || true)"
    big_loaded=0
    grep -q 'qwen/qwen3.6-27b' <<<"$loaded" && big_loaded=$((big_loaded+1))
    grep -q 'qwen3-coder-30b' <<<"$loaded" && big_loaded=$((big_loaded+1))
    if (( big_loaded >= 2 )); then
      echo "  (advisory) BOTH big MLX models resident in LM Studio — they're ~17GB each and thrash a 24GB box."
      echo "             Unload one:  $lms2 unload --all   (the TTL also auto-evicts; one-big-MLX policy)"
    fi
  fi
  return 0
}

lmstudio_fix() {
  warn "Re-run the LM Studio phase (idempotent: starts the server, ensures the MLX model, re-wires LiteLLM):"
  warn "    bash $AI_STACK/vz-ai-stack.sh install lmstudio"
  return 1
}
