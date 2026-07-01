#!/usr/bin/env bash
# Smoke for config_validate (installer/lib/validate.sh) — the fail-fast guardrail
# that catches a malformed services.yml / models.yml BEFORE any phase runs (the
# class that hung `install all` at phase 26 on a one-char models.yml typo).
#
# Runs against a THROWAWAY temp AI_STACK (never the real configs):
#   valid yaml          -> config_validate returns 0
#   stray-quote typo    -> returns non-zero (the exact 2026-06-21 failure shape)
#   missing colon       -> returns non-zero
#   .services not a map -> returns non-zero (structural sanity)
# Run: bash installer/smoke/config_validate.sh
set -Eeuo pipefail
REAL_AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AI_STACK="$REAL_AI_STACK"   # common.sh requires AI_STACK set (the _run_cv subshell overrides it to the temp tree)
source "$REAL_AI_STACK/installer/lib/common.sh"

hdr "Smoke config_validate — fail-fast malformed-config guardrail"
command -v yq >/dev/null 2>&1 || { warn "yq not on PATH — skipping (not a failure)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/installer/lib"

# config_validate reads $AI_STACK/services.yml + $AI_STACK/installer/models.yml.
# Run it in a SUBSHELL with AI_STACK pointed at the temp tree (so set -e exits in
# config_validate can't kill this script, and the real configs are never touched).
_run_cv() { ( set +e; AI_STACK="$TMP"; source "$REAL_AI_STACK/installer/lib/validate.sh"; config_validate >/dev/null 2>&1; echo $? ); }

# 1. valid configs -> 0
cat > "$TMP/services.yml" <<'YML'
version: 2
services:
  litellm: {type: docker, enabled: true}
YML
cat > "$TMP/installer/models.yml" <<'YML'
primary: local
models:
  local: {runtime: ollama, served: nemotron-3-nano:4b}
assignments:
  pi: local
YML
[[ "$(_run_cv)" == "0" ]] && ok "valid configs -> pass" || { err "valid configs wrongly REJECTED"; exit 1; }

# 2. stray-quote typo in models.yml (the real 2026-06-21 shape) -> non-zero
printf '  local-x: {runtime: ollama, served: foo, note: "2.84G""}\n' >> "$TMP/installer/models.yml"
[[ "$(_run_cv)" != "0" ]] && ok "stray-quote models.yml typo -> rejected" || { err "stray-quote typo NOT caught"; exit 1; }

# 3. missing colon (a mapping key with no ':') -> non-zero
cat > "$TMP/installer/models.yml" <<'YML'
models:
  local: {runtime: ollama, served: nemotron-3-nano:4b}
  local-broken
    runtime: ollama
YML
[[ "$(_run_cv)" != "0" ]] && ok "missing-colon models.yml -> rejected" || { err "missing-colon NOT caught"; exit 1; }

# 4. structural: services.yml without a .services map -> non-zero
cat > "$TMP/installer/models.yml" <<'YML'
models: {local: {runtime: ollama, served: nemotron-3-nano:4b}}
YML
cat > "$TMP/services.yml" <<'YML'
version: 2
notservices: {}
YML
[[ "$(_run_cv)" != "0" ]] && ok "services.yml missing .services map -> rejected" || { err "missing .services map NOT caught"; exit 1; }

ok "config_validate: all cases pass (valid accepted; typo/missing-colon/bad-structure rejected)"
