# Every 127.0.10.x alias is actually bound to lo0.
#
# macOS does NOT auto-route 127.0.0.0/8; only 127.0.0.1 is on lo0 by default.
# Without `sudo ifconfig lo0 alias 127.0.10.X up` for each alias, Docker port
# bindings to those IPs succeed at bind time but the OS has no route, so
# every curl returns 000 (no response). This check catches it loudly.
CHECKS+=(lo0_aliases)
CHECK_TITLE[lo0_aliases]="127.0.10.x loopback aliases bound to lo0 (macOS-specific)"

lo0_aliases_diagnose() {
  source "$AI_STACK/installer/lib/network.sh"
  aliases_load || { echo "could not load aliases.tsv"; return 1; }
  local already_bound missing=() a ip
  already_bound="$(ifconfig lo0 2>/dev/null | awk '/inet 127\.0\.10\./ {print $2}')"
  for a in "${ALIASES_LIST[@]}"; do
    ip="${ALIAS_IP[$a]}"
    if ! grep -qxF "$ip" <<<"$already_bound"; then
      missing+=("$ip")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "missing lo0 aliases: ${missing[*]}"
    echo "(without these, curl http://litellm:4000 returns 000)"
    return 1
  fi
}

lo0_aliases_fix() {
  # Auto-fix requires sudo. Surface the canonical command rather than try sudo
  # mid-doctor (the prepare-sudo design says no inline sudo).
  warn "Auto-fix requires sudo. Run:"
  warn "    sudo bash $AI_STACK/install.sh prepare-sudo"
  warn "(idempotent; binds all 14 aliases + installs reboot persistence)"
  return 1
}
