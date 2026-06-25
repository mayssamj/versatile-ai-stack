# Model & Agent Console (models-serve) plumbing is present + wired, and models.yml
# is parseable so the console can read/stage against it.
#
# Pure file/parse check — NO cold-start, NO network, NO container calls (directive:
# doctor must not cold-start). Deep model<->agent binding, config.yaml coverage and
# allowlist correctness are owned by check 40 (models_binding); this check deliberately
# does NOT duplicate them. It asserts only what the console itself needs to exist:
#   1. installer/lib/models-serve.sh + installer/lib/models_proxy.py are present, and
#      the proxy is syntactically valid Python (so `models-serve` will actually boot).
#   2. `models-serve` is wired into vz-ai-stack.sh dispatch (lib present but unreachable
#      is the regression this guards).
#   3. doc/MODELS.html (the console page) is present.
#   4. installer/models.yml parses (fail-closed — the console reads it via the CLI).
#   5. litellm/config.yaml .litellm_settings.fallbacks parses and is a LIST (the fallback
#      editor + LiteLLM failover policy read it). yq type-check only — still NO cold-start.
#   6. ADVISORY (WARN, never red): every models.yml model with a key_env has that env
#      var set in .env. A missing vendor key is surfaced as a red dot in the console and
#      means that route will 401 at call time — worth flagging, but not a stack fault
#      (a keyless box is a legitimate local-only setup).
CHECKS+=(models_console)
CHECK_TITLE[models_console]="Model & Agent Console (models-serve) present + wired (vz-ai-stack.sh models-serve)"

models_console_diagnose() {
  local serve="$AI_STACK/installer/lib/models-serve.sh"
  local proxy="$AI_STACK/installer/lib/models_proxy.py"
  local html="$AI_STACK/doc/MODELS.html"
  local vz="$AI_STACK/vz-ai-stack.sh"
  local yml="$AI_STACK/installer/models.yml"
  local missing=""

  [[ -f "$serve" ]] || missing+="    installer/lib/models-serve.sh"$'\n'
  [[ -f "$proxy" ]] || missing+="    installer/lib/models_proxy.py"$'\n'
  [[ -f "$html"  ]] || missing+="    doc/MODELS.html"$'\n'
  if [[ -n "$missing" ]]; then
    printf "Model & Agent Console file(s) missing:\n%s" "$missing"
    return 1
  fi

  # Proxy must be valid Python or `models-serve` 500s on boot. compile() writes no .pyc.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "$proxy" 2>/dev/null \
      || { echo "installer/lib/models_proxy.py has a Python syntax error — models-serve would fail to start."; return 1; }
  fi

  # Wired into dispatch? (lib present but unreachable verb is the regression we guard.)
  if [[ -f "$vz" ]] && ! grep -qE 'models-serve\)[[:space:]]*cmd_models_serve' "$vz"; then
    echo "installer/lib/models-serve.sh exists but 'models-serve' is not wired into vz-ai-stack.sh dispatch."
    return 1
  fi

  # models.yml must parse (the console reads it through the `model` CLI). Fail-closed.
  if command -v yq >/dev/null 2>&1; then
    yq -e '.models | keys' "$yml" >/dev/null 2>&1 \
      || { echo "installer/models.yml does not parse (yq) — the console cannot read the catalog."; return 1; }
  fi

  # config.yaml fallback policy must parse + be a LIST (the fallback editor edits it and
  # LiteLLM reads it for failover). yq TYPE-CHECK only — no cold-start. Absent/null -> [] (ok).
  local cfg="$AI_STACK/litellm/config.yaml"
  if command -v yq >/dev/null 2>&1 && [[ -f "$cfg" ]]; then
    local fbtype; fbtype="$(yq -r '.litellm_settings.fallbacks // [] | type' "$cfg" 2>/dev/null || echo ERR)"
    [[ "$fbtype" != "ERR" ]] \
      || { echo "litellm/config.yaml does not parse for .litellm_settings.fallbacks — fallback editor + failover policy unreadable."; return 1; }
    [[ "$fbtype" == "!!seq" ]] \
      || { echo "litellm/config.yaml .litellm_settings.fallbacks is not a list (got '$fbtype') — fallback policy is malformed."; return 1; }
  fi

  # ADVISORY: declared key_env present in .env? (WARN-only — keyless box is legitimate.)
  local envf="${ENV_FILE:-$AI_STACK/.env}" warn=""
  if command -v yq >/dev/null 2>&1 && [[ -f "$envf" ]]; then
    local ke
    while IFS= read -r ke; do
      [[ -z "$ke" || "$ke" == "null" ]] && continue
      # present iff a non-empty KEY=VAL line exists in .env
      grep -qE "^[[:space:]]*${ke}=[[:space:]]*[^[:space:]\"']" "$envf" 2>/dev/null \
        || warn+="    $ke   (a model declares it; route will 401 until it's set in .env)"$'\n'
    done < <(yq -r '.models[].key_env' "$yml" 2>/dev/null | grep -vE '^(null)?$' | sort -u)
    if [[ -n "$warn" ]]; then
      printf "Console present + wired. ADVISORY — declared key_env(s) not set in .env:\n%s" "$warn"
      printf "  (the console flags these with a red dot; not a stack fault.)\n"
      return 0
    fi
  fi

  echo "  (models-serve.sh + models_proxy.py + MODELS.html present, wired, proxy compiles, models.yml parses)"
  return 0
}

models_console_fix() {
  warn "Model & Agent Console is incomplete. Expected, on branch feat/model-console (or main once merged):"
  warn "  • installer/lib/models-serve.sh  + installer/lib/models_proxy.py"
  warn "  • doc/MODELS.html"
  warn "  • a 'models-serve) cmd_models_serve' dispatch line in vz-ai-stack.sh"
  warn "Serve it with:  vz-ai-stack.sh models-serve   (run from the MAIN checkout)"
  return 1
}
