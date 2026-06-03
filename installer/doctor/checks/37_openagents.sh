# OpenAgents Launcher present (Phase 24).
#
# Verifies the OpenAgents CLI (`agn`) is installed. OpenAgents is an OPT-IN,
# host-only tool that OVERLAPS this stack (its own agent launcher + Workspace
# UI), so it is NOT installed by default. This check SKIPS CLEANLY (passes)
# when `agn` is absent — its absence is the expected state. It makes NO network
# calls; it only resolves the binary on PATH or under the ~/.openagents prefix.
CHECKS+=(openagents)
CHECK_TITLE[openagents]="OpenAgents Launcher installed (Phase 24, opt-in)"

# Resolve `agn` whether or not it's on the current shell's PATH. The installer
# appends a PATH line to your rc file, which the doctor's shell may not have
# sourced — so also probe the known install prefix.
_oa_bin_dir() { echo "$HOME/.openagents/nodejs/node_modules/.bin"; }
_oa_resolve_agn() {
  if command -v agn >/dev/null 2>&1; then command -v agn; return 0; fi
  local d; d="$(_oa_bin_dir)"
  if [[ -x "$d/agn" ]]; then echo "$d/agn"; return 0; fi
  return 1
}

openagents_diagnose() {
  local agn
  if ! agn="$(_oa_resolve_agn 2>/dev/null)"; then
    echo "agn not installed — opt-in; run 'vz-ai-stack.sh install 24' to add it. [skip]"
    return 0
  fi
  # Installed but not on the active PATH? Surface it (still a pass — it works
  # when invoked directly; the installer's rc edit applies to new shells).
  if ! command -v agn >/dev/null 2>&1; then
    echo "  (installed at $agn but not on this shell's PATH — open a new shell, or run it directly)"
    return 0
  fi
  echo "  (agn on PATH at $agn; OpenAgents is opt-in and NOT wired into LiteLLM/sandboxes/UIs)"
  return 0
}

openagents_fix() {
  warn "OpenAgents is opt-in. Install or repair it with:"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 24"
  warn "If it's installed but 'agn' isn't found, open a new shell (the installer"
  warn "edits your rc) or run it directly: $(_oa_bin_dir)/agn"
  return 1
}
