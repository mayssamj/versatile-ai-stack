#!/usr/bin/env bash
# Phase 18 — RLM (Recursive Language Models).
#
# RLM (github.com/alexzhang13/rlm, PyPI `rlms`, MIT OASYS lab) is an inference
# paradigm for near-infinite context: instead of one llm.completion() call, the
# model programmatically examines/decomposes its input in a REPL and recursively
# calls itself. It's the substrate HALO (Phase 11) is built on ("RLM-based
# Automatic Agent Optimization Loop").
#
# Stack integration (mirrors Phase 17 ACE):
#   - venv via uv + `uv pip install rlms`.
#   - Mint RLM_LITELLM_KEY scoped to local models; render rlm/.env with
#     OPENAI_API_KEY + OPENAI_BASE_URL=http://litellm:4000/v1 so every LLM call
#     (and every recursive sub-call) routes through LiteLLM → local models.
#   - REPL runs in a DOCKER SANDBOX (environment="docker"), NOT on the host:
#     RLM's model-generated Python executes in a throwaway python:3.11-slim
#     container that calls back to a host LM-proxy. This is the safety boundary
#     (RLM's default 'local' backend would exec generated code on the host).
#   - bin/rlm wrapper + rlm/run_rlm.py runner (no upstream CLI — it's a library).
#
# Verified 2026-05-31: `bin/rlm "compute 2**10 in the REPL"` → 1024, model
# local (gemma4:e4b) via LiteLLM, code executed in a Docker sandbox. Unlike HALO,
# RLM uses chat-completions so it works with ollama-via-LiteLLM.
#
# Standalone install: `bash install.sh install 18`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=18
RLM_DIR="$AI_STACK/rlm"
RLM_VENV="$RLM_DIR/.venv"
RLM_RUNNER="$RLM_DIR/run_rlm.py"
RLM_WRAPPER="$AI_STACK/bin/rlm"
RLM_SANDBOX_IMAGE="${RLM_SANDBOX_IMAGE:-python:3.11-slim}"

precheck() {
  [[ -x "$RLM_VENV/bin/python" ]] || return 1
  "$RLM_VENV/bin/python" -c 'import rlm' 2>/dev/null || return 1
  [[ -f "$RLM_RUNNER" ]] || return 1
  [[ -x "$RLM_WRAPPER" ]] || return 1
  [[ -f "$RLM_DIR/.env" ]] || return 1
  grep -q '^OPENAI_BASE_URL=http://litellm:4000/v1' "$RLM_DIR/.env" 2>/dev/null || return 1
  local k; k="$(get_env RLM_LITELLM_KEY '')"
  [[ -n "$k" ]] || return 1
  curl -sf --max-time 5 -H "Authorization: Bearer $k" http://litellm:4000/v1/models >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 18 — RLM — already installed (use 'install.sh install 18' to re-run)"
  exit 0
fi

hdr "Phase 18 — RLM (Recursive Language Models)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || { err "uv not on PATH — run 'bash $AI_STACK/install.sh install 14' (Unsloth installs uv)."; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing from .env — Phase 01 must run first."; exit 1; }
if ! curl -sf --max-time 3 -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://litellm:4000/v1/models >/dev/null 2>&1; then
  err "LiteLLM not reachable at http://litellm:4000 — run 'stack start litellm'."; exit 1
fi
docker info >/dev/null 2>&1 || warn "Docker not reachable — the 'docker' REPL sandbox won't work until OrbStack is up."

# --- 1. venv + install rlms ---
[[ -d "$RLM_VENV" ]] || { log "Creating venv via uv..."; uv venv "$RLM_VENV" --python 3.12 2>&1 | tail -3; }
log "Installing rlms into venv (pulls openai SDK + deps)..."
uv pip install --python "$RLM_VENV/bin/python" rlms 2>&1 | tail -5 || { err "uv pip install rlms failed"; exit 1; }
"$RLM_VENV/bin/python" -c 'import rlm' 2>/dev/null || { err "rlm import failed after install"; exit 1; }
ok "rlms installed in $RLM_VENV"

# --- 2. Mint LiteLLM virtual key (mirrors Phase 17 ACE) ---
RLM_KEY_CURRENT="$(get_env RLM_LITELLM_KEY '')"
if [[ -z "$RLM_KEY_CURRENT" ]] \
   || ! curl -sf --max-time 5 -H "Authorization: Bearer $RLM_KEY_CURRENT" http://litellm:4000/v1/models >/dev/null 2>&1; then
  # Mint against the fixed SUPERSET so `install.sh model assign/sync` can re-point
  # RLM without re-minting. Canonical IDs are registered in config.yaml by Phase
  # 01 first (superset-before-mint).
  log "Minting LiteLLM virtual key for RLM (models=superset[local,local-gemma4,local-heavy,local-lfm2,local-qwen3-coder,local-qwen3.6])..."
  RLM_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate \
    -d '{"models":["local","local-gemma4","local-heavy","local-lfm2","local-qwen3-coder","local-qwen3.6"],"key_alias":"rlm-recursive","metadata":{"owner":"rlm","purpose":"phase18"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$RLM_KEY_NEW" ]] || { err "Failed to mint RLM_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env RLM_LITELLM_KEY "$RLM_KEY_NEW"
  ok "RLM_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "RLM_LITELLM_KEY already present + valid"
fi
RLM_KEY_NOW="$(get_env RLM_LITELLM_KEY '')"

# --- 3. Render rlm/.env (routes through LiteLLM) ---
# RLM's bound model from installer/models.yml (availability-gated). RLM defaults
# to local-gemma4 (Ollama, always servable). run_rlm.py reads $RLM_MODEL.
RLM_MODEL_VAL="local"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _rm="$(yq -r '.assignments.rlm // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  _rrt="$(yq -r ".models.\"$_rm\".runtime" "$AI_STACK/installer/models.yml" 2>/dev/null)"
  if [[ -n "$_rm" && "$_rm" != "null" ]]; then
    if [[ "$_rrt" == "lmstudio" ]] \
       && ! { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null \
              && grep -qF "model_name: ${_rm}" "$AI_STACK/litellm/config.yaml" 2>/dev/null; }; then
      RLM_MODEL_VAL="$(yq -r '.default' "$AI_STACK/installer/models.yml" 2>/dev/null)"
    else
      RLM_MODEL_VAL="$_rm"
    fi
  fi
fi
set_env RLM_MODEL "$RLM_MODEL_VAL"
( umask 077; cat > "$RLM_DIR/.env" <<ENVEOF
# ai-stack: rendered by installer/phases/18_rlm.sh. Routes RLM through LiteLLM.
# Do not edit; re-run 'bash install.sh install 18' to regenerate.
OPENAI_API_KEY=$RLM_KEY_NOW
OPENAI_BASE_URL=http://litellm:4000/v1
RLM_MODEL=$RLM_MODEL_VAL
ENVEOF
)
chmod 600 "$RLM_DIR/.env"
ok "wrote $RLM_DIR/.env (mode 0600; LiteLLM-routed; model=$RLM_MODEL_VAL)"

# --- 4. Runner (rlm/run_rlm.py) ---
cat > "$RLM_RUNNER" <<'PYEOF'
#!/usr/bin/env python3
"""Thin RLM runner: recursive completion via LiteLLM, REPL in a Docker sandbox."""
import argparse, os, sys


def main() -> int:
    ap = argparse.ArgumentParser(prog="rlm",
        description="Recursive Language Model — routed through LiteLLM, REPL sandboxed in Docker.")
    ap.add_argument("prompt", nargs="?", help="The task / prompt for the recursive LM.")
    ap.add_argument("-m", "--model", default=os.environ.get("RLM_MODEL", "local"),
                    help="LiteLLM model (default: local=gemma4:e4b). Try local-heavy / local-lfm2.")
    ap.add_argument("--env", default=os.environ.get("RLM_ENV", "docker"),
                    choices=["docker", "local", "ipython"],
                    help="REPL backend (default: docker — sandboxed; 'local' runs generated code on the HOST).")
    ap.add_argument("--image", default=os.environ.get("RLM_DOCKER_IMAGE", "python:3.11-slim"))
    ap.add_argument("--max-depth", type=int, default=int(os.environ.get("RLM_MAX_DEPTH", "1")))
    ap.add_argument("--max-iterations", type=int, default=int(os.environ.get("RLM_MAX_ITERATIONS", "30")))
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    if not args.prompt:
        ap.print_help(); return 0
    base_url = os.environ.get("OPENAI_BASE_URL", "http://litellm:4000/v1")
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        print("rlm: OPENAI_API_KEY empty — is rlm/.env present (RLM_LITELLM_KEY minted)?", file=sys.stderr)
        return 2
    if args.env != "docker":
        print(f"rlm: WARNING — env='{args.env}' runs model-generated code on the HOST, not a sandbox.", file=sys.stderr)
    from rlm import RLM
    rlm = RLM(
        backend="openai",
        backend_kwargs={"model_name": args.model, "base_url": base_url, "api_key": api_key},
        environment=args.env,
        environment_kwargs={"image": args.image} if args.env == "docker" else None,
        max_depth=args.max_depth,
        max_iterations=args.max_iterations,
        verbose=args.verbose,
    )
    result = rlm.completion(args.prompt)
    print(getattr(result, "response", result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
ok "wrote $RLM_RUNNER"

# --- 5. bin/rlm wrapper ---
cat > "$RLM_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/rlm — Recursive Language Models (rlms), routed through LiteLLM, REPL in Docker.
#   bin/rlm "Summarize this 500-page log: <paste or path>"
#   bin/rlm "..." -m local-heavy --max-depth 2
#   bin/rlm --help
# Generated by installer/phases/18_rlm.sh.
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
RLM_DIR="\$AI_STACK/rlm"
[[ -x "\$RLM_DIR/.venv/bin/python" ]] || { echo "RLM not installed — run 'bash install.sh install 18'" >&2; exit 1; }
# Load OPENAI_BASE_URL + OPENAI_API_KEY (LiteLLM routing) from rlm/.env.
set -a; [[ -f "\$RLM_DIR/.env" ]] && source "\$RLM_DIR/.env"; set +a
exec "\$RLM_DIR/.venv/bin/python" "\$RLM_DIR/run_rlm.py" "\$@"
WRAPEOF
chmod +x "$RLM_WRAPPER"
ok "wrote $RLM_WRAPPER"

# --- 6. Pre-pull the sandbox image (best-effort; first real run otherwise pulls) ---
if docker info >/dev/null 2>&1; then
  if ! docker image inspect "$RLM_SANDBOX_IMAGE" >/dev/null 2>&1; then
    log "Pre-pulling REPL sandbox image $RLM_SANDBOX_IMAGE..."
    docker pull "$RLM_SANDBOX_IMAGE" 2>&1 | tail -2 || warn "pull $RLM_SANDBOX_IMAGE failed — first 'bin/rlm' run will pull it."
  else
    ok "sandbox image $RLM_SANDBOX_IMAGE present"
  fi
fi

# --- 7. Smoke test: wrapper runs (--help only; a real recursive run is on-demand) ---
if ! "$RLM_WRAPPER" --help >/dev/null 2>&1; then
  err "bin/rlm --help failed — wrapper/runner broken; phase will not stamp."
  exit 1
fi
ok "bin/rlm --help: smoke-test passed"

stamp_mark "$PHASE"
record "phase 18 complete: rlms venv + RLM_LITELLM_KEY + .env + run_rlm.py + bin/rlm (docker-sandboxed REPL)"
ok "Phase 18 — RLM — complete"
note "Try:   $RLM_WRAPPER \"Use the REPL to compute the 20th Fibonacci number.\""
note "Model: bin/rlm \"...\" -m local-heavy        (more capable; 22GB — watch RAM)"
note "Safety: REPL code runs in a Docker sandbox (python:3.11-slim). '--env local' would run it on the HOST."
note "Docs:  RLM is the substrate HALO (Phase 11) is built on. github.com/alexzhang13/rlm"
