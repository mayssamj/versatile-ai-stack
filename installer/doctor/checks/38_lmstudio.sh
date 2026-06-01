# LM Studio (MLX) wired as a second runtime behind LiteLLM (Phase 25).
#
# Opt-in. Passes (no-op) when LM Studio isn't installed. When installed, verifies
# the lms CLI + the OpenAI server on :1234 + the local-lfm2-mlx provider in
# litellm/config.yaml. Does NOT run a (slow) model round-trip — it only checks
# the wiring is in place. NO secrets printed.
CHECKS+=(lmstudio)
CHECK_TITLE[lmstudio]="LM Studio (MLX) wired behind LiteLLM (Phase 25)"

lmstudio_diagnose() {
  if [[ ! -d "/Applications/LM Studio.app" ]]; then
    echo "LM Studio not installed — run 'install.sh install lmstudio' to add MLX behind LiteLLM. [skip]"
    return 0
  fi
  local lms=""
  [[ -x "$HOME/.lmstudio/bin/lms" ]] && lms="$HOME/.lmstudio/bin/lms"
  if [[ -z "$lms" ]]; then
    echo "LM Studio.app present but lms CLI not bootstrapped — open the app once or re-run 'install.sh install lmstudio'"
    return 1
  fi
  if ! curl -s -o /dev/null --max-time 4 "http://127.0.0.1:1234/v1/models" 2>/dev/null; then
    echo "LM Studio server not reachable on :1234 — start it: '$lms server start -p 1234 --bind 0.0.0.0' (or re-run 'install lmstudio')"
    return 1
  fi
  if ! grep -q 'model_name: local-lfm2-mlx\b' "$AI_STACK/litellm/config.yaml" 2>/dev/null; then
    echo "server up but local-lfm2-mlx not wired into litellm/config.yaml — re-run 'install.sh install lmstudio'"
    return 1
  fi
  local n
  n="$(curl -s --max-time 5 http://127.0.0.1:1234/v1/models 2>/dev/null | python3 -c 'import sys,json; print(sum(1 for m in json.load(sys.stdin).get("data",[]) if "embed" not in m["id"].lower()))' 2>/dev/null || echo 0)"
  echo "  (LM Studio server up on :1234, $n LLM(s) served; local-lfm2-mlx wired into LiteLLM. A/B vs Ollama via Phoenix.)"
  return 0
}

lmstudio_fix() {
  warn "Re-run the LM Studio phase (idempotent: starts the server, ensures the MLX model, re-wires LiteLLM):"
  warn "    bash $AI_STACK/install.sh install lmstudio"
  return 1
}
