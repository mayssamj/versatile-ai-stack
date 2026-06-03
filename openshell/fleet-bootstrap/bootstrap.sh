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
  "hermes_manager|engineering manager + product intake — specs acceptance criteria, decomposes, delegates, orchestrates the gate order; writes no code"
  "hermes_techlead|tech lead / architect — ADRs, interface contracts, design review, standards; co-designs ML work"
  "hermes_frontend_engineer|frontend engineer — accessible, performant UI against the design contract"
  "hermes_backend_engineer|backend engineer — APIs, services, data and security basics against the contract"
  "hermes_ml_engineer|ML engineer — model selection, evals, data pipelines, finetuning, RAG; guards against overkill models"
  "hermes_qa_test_engineer|QA / test engineer — test strategy + automation; the green-bar quality gate"
  "hermes_reviewing_engineer|reviewing engineer (read-only) — adversarial review including the security pass"
  "hermes_sre_engineer|SRE — reliability, IaC, observability, CI/CD, safe deploys; prod-credentialed"
  "hermes_incident_manager|incident manager (read-only) — incident command + blameless postmortems"
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
# Prune in-sandbox profiles not in the current roster (REPLACE semantics -- removes
# stale roles from a previous fleet so a 7->9 swap doesn't leave 16 profiles).
_keep="$(printf '%s\n' "${ROSTER[@]}" | cut -d'|' -f1)"
for d in "$HOME"/.hermes/profiles/*/; do
  [ -d "$d" ] || continue
  pn="$(basename "$d")"
  [ "$pn" = "default" ] && continue
  if ! printf '%s\n' "$_keep" | grep -qxF "$pn"; then
    echo "==> pruning stale profile $pn"
    rm -rf "$d"
  fi
done
hermes profile list 2>&1 | tail -10
