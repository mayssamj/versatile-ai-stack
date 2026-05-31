#!/usr/bin/env bash
# start-deerflow.sh — bring up DeerFlow with LITELLM_MASTER_KEY exported
# into the shell so docker compose's ${LITELLM_MASTER_KEY} substitution
# resolves at parse time.
#
# Why this wrapper exists: deer-flow's scripts/deploy.sh runs
#   docker compose -p deer-flow -f docker/docker-compose.yaml ...
# without --env-file. Compose then looks for `.env` next to the compose
# file (i.e. deer-flow/docker/.env, which doesn't exist) for variable
# substitution. The gateway's environment: block has
#   - LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
# which substitutes to empty when LITELLM_MASTER_KEY isn't in the shell,
# emitting the WARN[0000] line you saw. The env_file: directive (which
# points at deer-flow/.env) only feeds in-container env at runtime — it
# doesn't help compose's parse-time substitution.
#
# This wrapper sources the master key from ~/ai-stack/.env (which the
# installer mode-0600 owns) and exports it before invoking deploy.sh,
# so the substitution resolves cleanly and the warning goes away.
#
# Usage:
#   bin/start-deerflow.sh           # bring up
#   bin/start-deerflow.sh build     # rebuild images, then start
#   bin/start-deerflow.sh down      # stop (equivalent to bin/stop-deerflow.sh)
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-deerflow.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

DF_DIR="$AI_STACK/deer-flow"
[[ -d "$DF_DIR" && -f "$DF_DIR/scripts/deploy.sh" ]] || {
  err "DeerFlow not installed at $DF_DIR — run 'bash install.sh install 10' first."
  exit 1
}

# Read LITELLM_MASTER_KEY from ai-stack root .env (mode 0600).
# get_env returns the value or the supplied default ("") if absent.
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY "")"
if [[ -z "$LITELLM_MASTER_KEY" ]]; then
  err "LITELLM_MASTER_KEY missing from $AI_STACK/.env — Phase 01 may not have run."
  exit 1
fi
export LITELLM_MASTER_KEY

ACTION="${1:-start}"
case "$ACTION" in
  start|build|down|"") : ;;
  *) err "Unknown action: $ACTION (expected start|build|down)"; exit 2 ;;
esac

cd "$DF_DIR"
exec bash scripts/deploy.sh "$ACTION"
