#!/usr/bin/env bash
# Phase 23 — SkillSpector (NVIDIA's pre-install security scanner for agent skills/MCP).
#
# SkillSpector (github.com/NVIDIA/skillspector, Apache-2.0) vets agent skills and
# MCP servers for prompt-injection, tool-poisoning, dangerous shell/exfil patterns,
# etc. BEFORE you install them. It runs an OFFLINE static analysis stage by default;
# an OPTIONAL second stage adds LLM-based semantic analysis via an OpenAI-compatible
# endpoint. We keep this phase OFFLINE-first — the wrapper defaults to `--no-llm` so
# nothing leaves the box unless the user explicitly opts in.
#
# Stack integration (mirrors Phase 18 RLM's venv-via-uv shape):
#   - Vendored clone into $AI_STACK/skillspector (GITIGNORED by the orchestrator —
#     it's an upstream checkout, not our source).
#   - venv via uv (`uv venv`), then `uv pip install --python <venv> -e .` (editable
#     install of the checkout). This is more robust than relying on `make install`
#     + an activated shell — make's install target just runs `uv sync`/`pip install
#     -e .` and ASSUMES a pre-activated venv, which we don't have in a non-interactive
#     installer. We drive the venv's interpreter directly instead.
#   - bin/skillspector wrapper (mirrors bin/rlm) that execs the venv's console script.
#     The wrapper injects `--no-llm` UNLESS the user already passed an --llm/--no-llm
#     flag, so the default is offline/static and nothing is sent to any model.
#
# Optional LLM stage (NOT wired by default — opt-in at call time):
#   To route the semantic stage through the stack's LiteLLM (local-first), set in
#   your shell before invoking:
#     SKILLSPECTOR_PROVIDER=openai
#     OPENAI_BASE_URL=http://litellm:4000/v1
#     OPENAI_API_KEY=<a LiteLLM virtual key>
#   then call:  bin/skillspector scan ./some-skill   (omit --no-llm; pass --llm)
#   We deliberately do NOT mint a key or default this on — keeping the scanner
#   offline is the safer default for a security tool.
#
# Idempotent: skips when the venv interpreter + console script + wrapper all exist.
# Resilient: any unmet hard prerequisite (no uv, no git, no network, wrong Python)
# prints an actionable warning and exits 0 WITHOUT stamping, so a later re-run
# completes once the prereq is satisfied — it never leaves the tree half-broken.
#
# Very new upstream (~5 commits at time of writing) so the install step is defensive:
# clone failures, missing console script, and import failures all degrade gracefully.
#
# Standalone install: `bash vz-ai-stack.sh install 23`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=23
SS_REPO="https://github.com/NVIDIA/skillspector.git"
SS_DIR="$AI_STACK/skillspector"          # vendored upstream checkout (gitignored)
SS_VENV="$SS_DIR/.venv"
SS_PY="$SS_VENV/bin/python"
SS_CLI="$SS_VENV/bin/skillspector"       # console script installed by `pip install -e .`
SS_WRAPPER="$AI_STACK/bin/skillspector"

precheck() {
  [[ -x "$SS_PY" ]]      || return 1
  [[ -x "$SS_CLI" ]]     || return 1
  [[ -x "$SS_WRAPPER" ]] || return 1
  # Prove the CLI actually runs (catches a broken editable install / dep drift).
  "$SS_CLI" --help >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 23 — SkillSpector — already installed (use 'vz-ai-stack.sh install 23' to re-run)"
  exit 0
fi

hdr "Phase 23 — SkillSpector (agent-skill / MCP security scanner)"

# --- Preconditions (soft-fail: warn + exit 0 WITHOUT stamping) ---------------
if ! command -v git >/dev/null 2>&1; then
  warn "git not on PATH — cannot clone SkillSpector. Install git (xcode-select --install) then re-run 'vz-ai-stack.sh install 23'."
  exit 0
fi
if ! command -v uv >/dev/null 2>&1; then
  warn "uv not on PATH — SkillSpector needs it to build its venv."
  warn "Run 'bash $AI_STACK/vz-ai-stack.sh install 14' (Unsloth installs uv), then re-run 'vz-ai-stack.sh install 23'."
  exit 0
fi

# --- 1. Clone (or update) the vendored checkout ------------------------------
# NOTE: $AI_STACK/skillspector is gitignored by the orchestrator — it's an
# upstream checkout, not part of our tree.
if [[ ! -d "$SS_DIR/.git" ]]; then
  log "Cloning SkillSpector into $SS_DIR ..."
  if ! git clone --depth 1 "$SS_REPO" "$SS_DIR" 2>&1 | tail -3; then
    warn "git clone failed (no network, or the repo moved?). Nothing stamped — re-run 'vz-ai-stack.sh install 23' when connectivity is back."
    # Clean up a partial clone so the next run starts fresh.
    [[ -d "$SS_DIR" && ! -d "$SS_DIR/.git" ]] && rm -rf "$SS_DIR"
    exit 0
  fi
  ok "cloned SkillSpector → $SS_DIR"
else
  log "Updating existing SkillSpector checkout (git pull --ff-only)..."
  git -C "$SS_DIR" pull --ff-only 2>&1 | tail -3 || \
    warn "git pull failed (local edits or diverged?) — continuing with the existing checkout."
fi

# Sanity: the checkout must be a Python package (pyproject.toml) we can install.
if [[ ! -f "$SS_DIR/pyproject.toml" && ! -f "$SS_DIR/setup.py" ]]; then
  warn "Cloned checkout has no pyproject.toml/setup.py — upstream layout may have changed."
  warn "Inspect $SS_DIR and update this phase. Nothing stamped."
  exit 0
fi

# --- 2. venv via uv (Python 3.12+ required by upstream) ----------------------
if [[ ! -x "$SS_PY" ]]; then
  log "Creating venv via uv (Python 3.12)..."
  if ! uv venv "$SS_VENV" --python 3.12 2>&1 | tail -3; then
    warn "uv venv failed (Python 3.12+ unavailable to uv?). uv can fetch it — check 'uv python list'."
    warn "Resolve the interpreter, then re-run 'vz-ai-stack.sh install 23'. Nothing stamped."
    exit 0
  fi
fi

# --- 3. Editable install of the checkout into the venv -----------------------
log "Installing SkillSpector (editable) into its venv..."
if ! uv pip install --python "$SS_PY" -e "$SS_DIR" 2>&1 | tail -8; then
  warn "uv pip install -e failed (network or upstream dep issue). Nothing stamped — re-run 'vz-ai-stack.sh install 23'."
  exit 0
fi

# --- 4. Verify the console script landed + runs ------------------------------
if [[ ! -x "$SS_CLI" ]]; then
  warn "Expected console script not found at $SS_CLI after install."
  warn "Upstream may name its entry point differently — check '$SS_VENV/bin/'. Nothing stamped."
  exit 0
fi
if ! "$SS_CLI" --help >/dev/null 2>&1; then
  warn "'$SS_CLI --help' did not run cleanly (broken deps?). Nothing stamped — re-run 'vz-ai-stack.sh install 23'."
  exit 0
fi
ok "skillspector CLI installed + runs in $SS_VENV"

# --- 5. bin/skillspector wrapper (OFFLINE-first) -----------------------------
# Mirrors bin/rlm. Defaults to --no-llm so the static-only stage runs and nothing
# is sent to any model — unless the user explicitly passes --llm or --no-llm.
cat > "$SS_WRAPPER" <<'WRAP'
#!/usr/bin/env bash
# bin/skillspector — OFFLINE-first wrapper around the vendored NVIDIA SkillSpector.
#
# Scan an agent skill / MCP server for prompt-injection, tool-poisoning, dangerous
# shell/exfil patterns, etc. BEFORE you install it:
#   bin/skillspector scan ./some-skill/          # local dir
#   bin/skillspector scan ./SKILL.md             # single file
#   bin/skillspector scan https://github.com/u/r # git repo
#   bin/skillspector scan ./some-skill.zip       # zip
#
# DEFAULT = offline static analysis only (this wrapper injects --no-llm). Nothing
# leaves your machine unless you OPT IN to the LLM semantic stage.
#
# Opt in to the LLM stage (route through the stack's LiteLLM, local-first):
#   export SKILLSPECTOR_PROVIDER=openai
#   export OPENAI_BASE_URL=http://litellm:4000/v1
#   export OPENAI_API_KEY=<a LiteLLM virtual key>
#   bin/skillspector scan ./some-skill --llm      # --llm overrides the default --no-llm
#
# Generated by installer/phases/23_skillspector.sh.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SS_CLI="$AI_STACK/skillspector/.venv/bin/skillspector"
[[ -x "$SS_CLI" ]] || { echo "SkillSpector not installed — run 'bash vz-ai-stack.sh install 23'" >&2; exit 1; }

# --no-llm is a `scan` subcommand flag, NOT a global one — injecting it on
# `--help`, `version`, etc. errors on a strict CLI. So only inject when the first
# non-flag token is `scan` AND the caller hasn't already chosen a mode, and insert
# it right after the `scan` token.
mode_chosen=0 subcmd=""
for a in "$@"; do
  case "$a" in
    --llm|--no-llm) mode_chosen=1 ;;
    -*) ;;                                   # other flags: ignore
    *) [[ -z "$subcmd" ]] && subcmd="$a" ;;  # first positional = subcommand
  esac
done

if [[ "$subcmd" == "scan" && "$mode_chosen" == "0" ]]; then
  out=(); inserted=0
  for a in "$@"; do
    out+=("$a")
    if [[ "$inserted" == "0" && "$a" == "scan" ]]; then out+=(--no-llm); inserted=1; fi
  done
  exec "$SS_CLI" "${out[@]}"
else
  exec "$SS_CLI" "$@"
fi
WRAP
chmod 0755 "$SS_WRAPPER"
ok "wrote $SS_WRAPPER (offline-first; injects --no-llm by default)"

# --- 6. Smoke test the wrapper -----------------------------------------------
log "Smoke test: bin/skillspector --help ..."
if "$SS_WRAPPER" --help >/dev/null 2>&1; then
  ok "wrapper runs"
else
  # Non-fatal: the CLI itself verified above; some tools exit non-zero on --help.
  warn "bin/skillspector --help returned non-zero (some CLIs do) — CLI itself verified OK."
fi

stamp_mark "$PHASE"
record "phase 23 complete: SkillSpector (vendored clone + uv venv + bin/skillspector, offline-first --no-llm)"
ok "Phase 23 — SkillSpector — complete"
note "Scan a skill before installing:  bin/skillspector scan ./path/to/skill"
note "Scan a remote repo:              bin/skillspector scan https://github.com/user/skill"
note "Offline by default (--no-llm). Opt into the LLM stage by exporting"
note "  SKILLSPECTOR_PROVIDER=openai OPENAI_BASE_URL=http://litellm:4000/v1 OPENAI_API_KEY=<litellm key>"
note "  and passing --llm.  Checkout lives in $SS_DIR (gitignored)."
