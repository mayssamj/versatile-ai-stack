# Helicone artifacts present (deprecated; user moved to Phoenix).
CHECKS+=(helicone_cleanup)
CHECK_TITLE[helicone_cleanup]="No leftover Helicone artifacts (deprecated)"
FIX_CAPABLE[helicone_cleanup]=1   # <name>_fix MUTATES state (see doctor.sh FIX_CAPABLE)

helicone_cleanup_diagnose() {
  local issues=()
  [[ -d "$AI_STACK/helicone" ]] && issues+=("$AI_STACK/helicone/ directory exists")
  if [[ -n "$(get_env HELICONE_API_KEY "")" ]]; then
    issues+=("HELICONE_API_KEY set in .env")
  fi
  if (( ${#issues[@]} > 0 )); then
    printf '  - %s\n' "${issues[@]}"
    return 1
  fi
}

helicone_cleanup_fix() {
  if [[ -d "$AI_STACK/helicone" ]]; then
    if confirm "Remove $AI_STACK/helicone/?" Y; then
      rm -rf "$AI_STACK/helicone"
      ok "removed $AI_STACK/helicone/"
    fi
  fi
  if [[ -n "$(get_env HELICONE_API_KEY "")" ]]; then
    if confirm "Clear HELICONE_API_KEY in .env?" Y; then
      set_env HELICONE_API_KEY ""
    fi
  fi
}
