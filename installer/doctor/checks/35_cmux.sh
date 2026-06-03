# cmux installed (Phase 22).
#
# cmux is an opt-in HOST GUI app (native macOS terminal for parallel AI-agent
# sessions). There is NO daemon/port to probe — this check only confirms the
# app is present. Skips cleanly (passes) when cmux was never installed, since
# it's an optional add-on. Makes NO external network calls.
CHECKS+=(cmux)
CHECK_TITLE[cmux]="cmux installed (Phase 22, parallel AI-agent terminal)"

# True when cmux is on the machine — Homebrew cask record or the app bundle.
_cmux_present() {
  if command -v brew >/dev/null 2>&1; then
    brew list --cask cmux >/dev/null 2>&1 && return 0
  fi
  [[ -d /Applications/cmux.app ]] && return 0
  return 1
}

cmux_diagnose() {
  # macOS-only tool; on any other OS it's simply not applicable.
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "cmux is macOS-only — not applicable on $(uname -s). [skip]"
    return 0
  fi
  if ! _cmux_present; then
    echo "cmux not installed — run 'vz-ai-stack.sh install 22' to add it. [skip]"
    return 0
  fi
  echo "  (installed — launch with 'open -a cmux'; update via 'brew upgrade --cask cmux')"
  return 0
}

cmux_fix() {
  warn "Install / repair cmux:"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 22"
  warn "Or manually:  brew tap manaflow-ai/cmux && brew install --cask cmux"
  return 1
}
