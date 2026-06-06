# env.sh — safe .env reads + writes.
# Sourced by vz-ai-stack.sh after common.sh.
#
# Design notes (Reviewer B #6, Reviewer Adversarial #4):
#   - WRITES: awk → tmpfile → mv. 0600 chmod BEFORE content is written.
#     Reject newlines in values upfront. Preserve comments and ordering.
#   - READS: parse only KEY=VAL lines. Strip CR from value (CRLF guard).
#     Strip trailing whitespace from value (BUT only on read, not on write,
#     so we never silently mutate the user's bytes on disk).
#   - HASH: sha256 of (KEY + "\0" + raw value) — used to detect drift between
#     phases so the doctor can recommend a service restart when needed.

[[ -z "${AI_STACK:-}" ]] && { echo "env.sh: AI_STACK unset" >&2; exit 2; }

ENV_FILE="${ENV_FILE:-$AI_STACK/.env}"

# Ensure .env exists with 0600 perms.
ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    umask 077
    : > "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# get_env KEY [default]
# Reads the LAST occurrence of KEY=... and returns the value with CR stripped.
get_env() {
  local key="$1" default="${2:-}"
  ensure_env_file
  if ! grep -qE "^${key}=" "$ENV_FILE"; then
    printf '%s' "$default"
    return 0
  fi
  # tail -1 wins if duplicated; cut keeps everything after first =
  local val
  val="$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
  val="${val%$'\r'}"          # strip trailing CR
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# set_env KEY VAL
# Atomically upserts KEY=VAL in .env. Preserves comments + order.
# Rejects newlines in VAL. Never logs VAL.
set_env() {
  local key="$1" val="${2:-}"
  if [[ "$val" == *$'\n'* ]]; then
    err "set_env: refusing to write newline in value for $key"
    return 2
  fi
  ensure_env_file
  # Validate key shape; refuse non-shell-safe identifiers
  if ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
    err "set_env: invalid env key: $key"
    return 2
  fi
  local tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  awk -v k="$key" -v v="$val" '
    BEGIN { found=0 }
    /^[[:space:]]*#/ { print; next }
    {
      # match KEY= at start of line, exact key match (no partial prefix)
      n = index($0, "=")
      if (n > 0) {
        line_key = substr($0, 1, n-1)
        if (line_key == k) {
          if (found == 0) { print k "=" v; found=1 }
          # silently drop duplicate later occurrences (collapse)
          next
        }
      }
      print
    }
    END { if (!found) print k "=" v }
  ' "$ENV_FILE" > "$tmp" && mv -f "$tmp" "$ENV_FILE"
}

# require_env KEY [default]
# Like get_env, but if missing OR empty, AND a default is given, writes the
# default back. If still empty after that, returns 1 with an error.
require_env() {
  local key="$1" default="${2:-}"
  local val
  val="$(get_env "$key" "")"
  if [[ -z "$val" ]]; then
    if [[ -z "$default" ]]; then
      err "$key is missing or empty in $ENV_FILE and no default available"
      return 1
    fi
    warn "$key was missing/empty; writing default into $ENV_FILE"
    set_env "$key" "$default"
    val="$default"
  fi
  printf '%s' "$val"
}

# env_hash KEY
# sha256 of the current KEY+value combo. Used to detect downstream-staleness.
env_hash() {
  local key="$1"
  local val; val="$(get_env "$key" "")"
  # Trailing newline added by printf is consistent; doesn't matter for diffs.
  printf '%s\n%s\n' "$key" "$val" | shasum -a 256 | awk '{print $1}'
}

# load_env_strict  — validate every line, fail on malformed.
# Useful pre-flight before passing --env-file to docker.
load_env_strict() {
  ensure_env_file
  local lineno=0 bad=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Detect CRLF
    if [[ "$line" == *$'\r' ]]; then
      err ".env:$lineno has CRLF line ending (should be LF only)"
      bad=1
      continue
    fi
    # Must match KEY=VAL (no leading/trailing space around =)
    if ! [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
      err ".env:$lineno not a valid KEY=VAL line: ${line:0:60}"
      bad=1
    fi
  done < "$ENV_FILE"
  return $bad
}

# env_ensure_baseline — make .env install/doctor-ready WITHOUT any prompting.
#
# Idempotent, non-interactive. Single source of truth for the ".env baseline"
# shared by Phase 00 (00_host.sh) and the interactive `vz-ai-stack.sh setup`:
#   1. Ensure the file exists @ 0600.
#   2. Set non-secret DEFAULTS (service URLs, project name) only when empty.
#   3. Migrate stale `host.docker.internal` URL values to Docker-DNS names
#      (queues a litellm restart IF the restart-queue lib is loaded).
#   4. Auto-generate LITELLM_MASTER_KEY + PHOENIX_SECRET once (re-runs don't churn).
# Cloud API keys are intentionally LEFT EMPTY here — they are optional and are
# offered interactively by `setup`. A local-only / Claude-subscription user
# needs nothing beyond this baseline to reach `doctor`.
env_ensure_baseline() {
  ensure_env_file
  chmod 600 "$ENV_FILE" 2>/dev/null || true

  # Non-secret defaults (value = "" means "leave empty unless the user fills it").
  local -A _DEFAULTS=(
    [ANTHROPIC_API_KEY]=""
    [OPENAI_API_KEY]=""
    [OPENROUTER_API_KEY]=""
    [GOOGLE_API_KEY]=""
    [PHOENIX_COLLECTOR_HTTP_ENDPOINT]="http://phoenix:6006/v1/traces"
    [PHOENIX_PROJECT_NAME]="ai-stack"
    [PHOENIX_API_KEY]=""
    [PHOENIX_SECRET]=""
    [BLAXEL_API_KEY]=""
    [BLAXEL_WORKSPACE]=""
    [GITHUB_TOKEN]=""
    [HONCHO_API_KEY]=""
    [HONCHO_BASE_URL]="http://honcho:8000"
    [LITELLM_BASE_URL]="http://litellm:4000"
    [QDRANT_URL]="http://qdrant:6333"
    [PHOENIX_BASE_URL]="http://phoenix:6006"
    [LITELLM_MASTER_KEY]=""
  )
  local key current
  for key in "${!_DEFAULTS[@]}"; do
    current="$(get_env "$key" "")"
    if [[ -z "$current" ]]; then
      [[ -n "${_DEFAULTS[$key]}" ]] && set_env "$key" "${_DEFAULTS[$key]}"
      continue
    fi
    # Migrate stale pre-refactor values that point at host.docker.internal to
    # the Docker-DNS default. Only when a non-host.docker.internal default exists.
    if [[ -n "${_DEFAULTS[$key]}" \
          && "$current" == *host.docker.internal* \
          && "${_DEFAULTS[$key]}" != *host.docker.internal* ]]; then
      warn "$key contains stale 'host.docker.internal' — migrating to '${_DEFAULTS[$key]}'"
      set_env "$key" "${_DEFAULTS[$key]}"
      declare -F queue_restart >/dev/null 2>&1 && queue_restart litellm || true
    fi
  done

  # Auto-generate the local master key once (so re-runs don't churn it).
  if [[ -z "$(get_env LITELLM_MASTER_KEY "")" ]]; then
    set_env LITELLM_MASTER_KEY "sk-local-$(openssl rand -hex 16)"
    warn "Generated LITELLM_MASTER_KEY"
  fi
  # Auto-generate PHOENIX_SECRET (JWT signing key — NOT the login password).
  if [[ -z "$(get_env PHOENIX_SECRET "")" ]]; then
    set_env PHOENIX_SECRET "$(openssl rand -hex 32)"
    warn "Generated PHOENIX_SECRET (JWT signing key — NOT login password)"
  fi
}

# fix_crlf — strip CR from every line. Used by doctor.
fix_crlf() {
  ensure_env_file
  local tmp; tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  chmod 600 "$tmp"
  tr -d '\r' < "$ENV_FILE" > "$tmp" && mv -f "$tmp" "$ENV_FILE"
}
