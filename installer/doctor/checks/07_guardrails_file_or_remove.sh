# If guardrails.handler is in callbacks list, guardrails.py must exist (else ImportError).
CHECKS+=(guardrails_file_or_remove)
CHECK_TITLE[guardrails_file_or_remove]="guardrails.handler callback has matching guardrails.py"

guardrails_file_or_remove_diagnose() {
  if ! litellm_has_callback "guardrails.handler"; then return 0; fi
  if [[ ! -f "$AI_STACK/litellm/guardrails.py" ]]; then
    echo "guardrails.handler in callbacks but litellm/guardrails.py missing — LiteLLM will ImportError"
    return 1
  fi
}

guardrails_file_or_remove_fix() {
  if [[ -f "$AI_STACK/litellm/guardrails.py" ]]; then
    return 0
  fi
  if confirm "Remove guardrails.handler from callbacks list (alternative: install phase 04·G first)?" Y; then
    litellm_remove_callback "guardrails.handler"
    queue_restart litellm
  else
    err "Run phase 04·G to install guardrails.py."
    return 1
  fi
}
