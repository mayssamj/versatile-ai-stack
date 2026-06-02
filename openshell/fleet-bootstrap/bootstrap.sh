#!/usr/bin/env bash
# Runs INSIDE the OpenShell sandbox. Souls live under /sandbox/fleet-souls
# (uploaded by host — `sandbox upload` copies, doesn't bind-mount).
# The OpenShell base sandbox ships a uv-managed venv at /sandbox/.venv,
# whose bin dir is on PATH. `pip install hermes-agent` lands `hermes` at
# /sandbox/.venv/bin/hermes — already on PATH, no rewiring needed.
set -Eeuo pipefail
SOULS=/sandbox/fleet-souls
if ! command -v hermes >/dev/null 2>&1; then
  echo "FATAL: hermes not on PATH — pip install may have failed" >&2
  echo "PATH=$PATH" >&2
  exit 1
fi
ROSTER=(
  "hermes_cos|chief of staff — decomposes goals, routes to specialists, does not implement"
  "hermes_software_engineer|pragmatic senior engineer — minimal-diff code, tests, refactors"
  "hermes_researcher|research collaborator — cites every claim, distinguishes evidence from speculation"
  "hermes_creator|careful writer — shapes research into audience-ready prose"
  "hermes_reviewer|rigorous reviewer — blocks with review-required: prefix when changes needed"
  "hermes_data_analyst|data analyst — SQL and Python answering specific questions over real data"
  "hermes_ops|ops engineer — deploys, monitoring, incidents; prefers boring working systems"
)
for entry in "${ROSTER[@]}"; do
  IFS='|' read -r name desc <<< "$entry"
  # Capture-then-grep: a direct `hermes profile list | awk | grep -q` pipe dies
  # under `set -o pipefail` when grep -q closes the pipe (SIGPIPE 141) — that
  # could wedge the bootstrap mid-roster. Capture first, then grep the var.
  _plist="$(hermes profile list 2>/dev/null | awk '{print $1}')"
  if grep -qxF "$name" <<<"$_plist"; then
    echo "==> $name exists — updating SOUL + config"
  else
    echo "==> creating $name"
    hermes profile create "$name" --description "$desc" --no-alias 2>&1 | tail -3 || true
  fi
  if [[ -f "$SOULS/${name}.md" ]]; then
    mkdir -p "$HOME/.hermes/profiles/$name"
    cp "$SOULS/${name}.md" "$HOME/.hermes/profiles/$name/SOUL.md"
  fi
  # NOTE: LLM routing (model/provider/base_url/api_key) is configured per-profile
  # by the HOST side after this bootstrap, via `hermes --profile <name> config
  # set model.* / providers.litellm.*`. hermes v0.15.2 removed `profile config`
  # and has NO `llm.*` namespace, so the old `profile config --set llm.model=`
  # was a silent no-op (CHANGELOG 2026-05-30).
done
hermes profile list 2>&1 | tail -10
