# portless (agent-aware local dev proxy) healthy (Phase 21).
#
# portless is an OPT-IN host tool. This check passes (no-op) when the CLI isn't
# installed. Node 24+ is RECOMMENDED by upstream but NOT required — portless runs
# under Node 22 — so an old-Node host is an advisory note, NOT a failure. Only a
# genuinely non-runnable binary fails. Makes NO external network calls.
CHECKS+=(portless)
CHECK_TITLE[portless]="portless local dev proxy installed (Phase 21)"

_portless_node_major() {
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  local v; v="$(node -v 2>/dev/null)"; v="${v#v}"; v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf ''
}

portless_diagnose() {
  local rec=24
  if ! command -v portless >/dev/null 2>&1; then
    echo "portless not installed — run 'mayssam-ai-stack.sh install portless' to add it. [skip]"
    return 0
  fi
  # Installed: a non-runnable binary is the only real failure.
  if ! portless --version >/dev/null 2>&1; then
    echo "portless on PATH but '--version' failed — the install looks broken. Re-run 'mayssam-ai-stack.sh install portless'."
    return 1
  fi
  local maj ver
  maj="$(_portless_node_major)"
  ver="$(portless --version 2>/dev/null | head -1 | tr -d '[:space:]')"
  if [[ -n "$maj" ]] && (( maj < rec )); then
    echo "  (portless ${ver:-?} on PATH; Node v${maj} < ${rec} — upstream recommends ${rec}+; works today, pin a newer Node via nvm/fnm if you hit issues)"
    return 0
  fi
  echo "  (portless ${ver:-?} on PATH; Node v${maj:-?}. Try: portless list | portless trust)"
  return 0
}

portless_fix() {
  warn "Install or repair portless via its phase:"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install portless"
  return 1
}
