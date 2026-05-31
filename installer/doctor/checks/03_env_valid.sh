# .env exists, mode 0600, parses cleanly, no CRLF.
CHECKS+=(env_valid)
CHECK_TITLE[env_valid]=".env file exists, 0600, parses cleanly"

env_valid_diagnose() {
  [[ -f "$AI_STACK/.env" ]] || { echo ".env missing"; return 1; }
  local perm; perm="$(stat -f '%Sp' "$AI_STACK/.env")"
  [[ "$perm" == "-rw-------" ]] || { echo ".env permissions are '$perm' (should be -rw-------)"; return 1; }
  load_env_strict 2>&1 || return 1
}

env_valid_fix() {
  ensure_env_file
  chmod 600 "$AI_STACK/.env"
  fix_crlf
  load_env_strict
}
