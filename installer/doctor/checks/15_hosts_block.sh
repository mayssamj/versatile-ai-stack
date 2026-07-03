# /etc/hosts has the managed ai-stack block and every alias is correct.
CHECKS+=(hosts_block)
CHECK_TITLE[hosts_block]="/etc/hosts has the managed ai-stack block (all aliases present)"

hosts_block_diagnose() {
  # shellcheck source=../../lib/network.sh
  source "$AI_STACK/installer/lib/network.sh"
  aliases_load || { echo "could not load aliases.tsv"; return 1; }

  if ! grep -qF "$HOSTS_MARK_BEGIN" /etc/hosts 2>/dev/null; then
    echo "/etc/hosts has no >>> ai-stack managed block"
    return 1
  fi

  local missing=() wrong=() a got
  for a in "${ALIASES_LIST[@]}"; do
    # Look for a line in /etc/hosts that lists this alias.
    got="$(awk -v a="$a" '
      /^[[:space:]]*#/ { next }
      {
        for (i=2; i<=NF; i++) if ($i == a) { print $1; exit }
      }
    ' /etc/hosts)"
    if [[ -z "$got" ]]; then
      missing+=("$a")
    elif [[ "$got" != "${ALIAS_IP[$a]}" ]]; then
      wrong+=("${a}→${got} expected ${ALIAS_IP[$a]}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "missing aliases in /etc/hosts: ${missing[*]}"
    return 1
  fi
  if (( ${#wrong[@]} > 0 )); then
    echo "mismatched aliases: ${wrong[*]}"
    return 1
  fi
}

hosts_block_fix() {
  # Per Reviewer A's caveat on the prepare-sudo design: we don't auto-call
  # hosts_ensure_block from doctor because that would silently invoke sudo
  # mid-doctor, breaking the "no sudo after prepare-sudo" invariant.
  # Instead, surface the exact command the user should run.
  warn "Auto-fix would require sudo. Run this from a terminal:"
  warn "    sudo bash $AI_STACK/vz-ai-stack.sh prepare-sudo"
  warn "(idempotent; re-running on a healthy block is a no-op)"
  return 1
}
