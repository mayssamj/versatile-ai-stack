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
  "hermes_cos|chief of staff|local-heavy"
  "hermes_software_engineer|pragmatic senior engineer|local-heavy"
  "hermes_researcher|research collaborator|local-heavy"
  "hermes_creator|careful writer|local-heavy"
  "hermes_reviewer|rigorous reviewer|local-heavy"
  "hermes_data_analyst|data analyst|local-heavy"
  "hermes_ops|ops engineer|local-heavy"
)
for entry in "${ROSTER[@]}"; do
  IFS='|' read -r name desc model <<< "$entry"
  if hermes profile list 2>/dev/null | awk '{print $1}' | grep -qxF "$name"; then
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
