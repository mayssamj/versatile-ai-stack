# /etc/hosts must be root:wheel mode 0644. The Y-1 patch fixed a regression
# where `sudo mv` left the file owned by the invoking user; this check
# guarantees that regression cannot ship silently again.
#
# Uses BSD `stat -f` because macOS doesn't have GNU `stat -c`.
CHECKS+=(etc_hosts_ownership)
CHECK_TITLE[etc_hosts_ownership]="/etc/hosts is owned root:wheel mode 644 (OS integrity)"
FIX_CAPABLE[etc_hosts_ownership]=1   # <name>_fix MUTATES state (see doctor.sh FIX_CAPABLE)

etc_hosts_ownership_diagnose() {
  # shellcheck source=../../lib/verify.sh
  source "$AI_STACK/installer/lib/verify.sh"
  if ! verify_etc_hosts_correctly_owned 2>&1; then
    return 1
  fi
}

etc_hosts_ownership_fix() {
  if [[ -t 0 ]] || sudo -n true 2>/dev/null; then
    log "Re-applying canonical /etc/hosts ownership (sudo required)..."
    if sudo chown root:wheel /etc/hosts && sudo chmod 644 /etc/hosts; then
      ok "/etc/hosts ownership restored"
      return 0
    fi
    err "chown/chmod failed"
    return 1
  fi
  warn "Cannot prompt for sudo from this terminal. Run manually:"
  warn "  sudo chown root:wheel /etc/hosts && sudo chmod 644 /etc/hosts"
  return 1
}
