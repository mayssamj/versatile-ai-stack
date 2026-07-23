# SkillSpector installed (Phase 23): NVIDIA's pre-install security scanner for
# agent skills / MCP servers.
#
# Verifies the vendored checkout's venv imports a working `skillspector` CLI and
# the bin/skillspector wrapper exists. Skips cleanly (passes) when SkillSpector was
# never installed (skillspector/.venv absent) — it's an optional opt-in add-on.
# Makes NO external network calls: it only runs the LOCAL CLI's --help (the scanner
# is offline-by-default; we don't trigger a scan here).
CHECKS+=(skillspector)
CHECK_TITLE[skillspector]="SkillSpector skill/MCP security scanner installed (Phase 23)"

skillspector_diagnose() {
  local ss_dir="$AI_STACK/skillspector"
  local ss_cli="$ss_dir/.venv/bin/skillspector"
  # Not installed yet → skip (don't fail a stack that never ran Phase 23).
  if [[ ! -x "$ss_dir/.venv/bin/python" ]]; then
    echo "SkillSpector not installed (skillspector/.venv absent) — run 'mayssam-ai-stack.sh install 23' to add it. [skip]"
    return 0
  fi
  if [[ ! -x "$ss_cli" ]]; then
    echo "skillspector CLI missing from venv ($ss_cli) — re-run 'install 23'"
    return 1
  fi
  if [[ ! -x "$AI_STACK/bin/skillspector" ]]; then
    echo "bin/skillspector wrapper missing — re-run 'install 23'"
    return 1
  fi
  # Prove the CLI actually runs (catches dep drift / a broken editable install).
  if ! "$ss_cli" --help >/dev/null 2>&1; then
    echo "'skillspector --help' did not run cleanly (broken deps?) — re-run 'install 23'"
    return 1
  fi
  echo "  (installed; offline-by-default. Scan with: bin/skillspector scan ./path/to/skill)"
  return 0
}

skillspector_fix() {
  warn "Re-run Phase 23 to (re)clone + (re)install SkillSpector + write bin/skillspector:"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install 23"
  return 1
}
