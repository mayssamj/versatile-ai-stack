# setup.sh — interactive .env / API-key bootstrap for new users.
# Sourced by mayssam-ai-stack.sh AFTER common.sh + env.sh + prompt.sh.
#
# Backs `mayssam-ai-stack.sh setup` (alias `keys`) and the first-run auto-offer in
# `cmd_install`. Two guarantees:
#   1. It ALWAYS ensures the non-interactive .env baseline first
#      (env.sh::env_ensure_baseline) — so a local-only / Claude-subscription
#      user can skip every prompt and still reach `doctor`.
#   2. Every external secret is OPTIONAL + skippable. Values are written via
#      set_env (atomic, 0600) and NEVER echoed; only a masked last-4 preview of
#      an already-set value is shown.
#
# Non-interactive (NO_PROMPT=1 or stdin not a TTY): ensure baseline, skip all
# prompts, print how to add keys later. Safe to source twice.

[[ -z "${AI_STACK:-}" ]] && { echo "setup.sh: AI_STACK unset" >&2; exit 2; }

SETUP_OFFERED_STAMP="${SETUP_OFFERED_STAMP:-$AI_STACK/installer/state/setup-offered}"

# Cloud LLM keys that, if any is already set, mean the user has configured the
# stack — so the install auto-offer should stay quiet.
_SETUP_CLOUD_KEYS=(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY)

# Optional-secret catalog. One entry per line: GROUP|KEY|SECRET(1/0)|WHAT-IT-UNLOCKS
# Order defines display order; entries are grouped by their GROUP label.
_setup_catalog() {
  cat <<'CATALOG'
Cloud LLM providers (optional)|ANTHROPIC_API_KEY|1|Anthropic API-key models in LiteLLM (the claude-* API routes; NOT needed for the -sub subscription models)
Cloud LLM providers (optional)|OPENAI_API_KEY|1|OpenAI gpt-* models in LiteLLM
Cloud LLM providers (optional)|OPENROUTER_API_KEY|1|OpenRouter-proxied models in LiteLLM
Cloud LLM providers (optional)|GOOGLE_API_KEY|1|Google Gemini models in LiteLLM
Observability (optional)|HELICONE_API_KEY|1|Helicone request logging (doctor check 10)
Integrations (optional)|GITHUB_TOKEN|1|GitHub-backed flows (repo access for tools that use it)
Integrations (optional)|BLAXEL_API_KEY|1|Blaxel CLI auth (Phase 12)
Integrations (optional)|BLAXEL_WORKSPACE|0|Blaxel workspace name (pairs with BLAXEL_API_KEY)
Telegram fleet control (optional, Phase 20)|HERMES_TELEGRAM_BOT_TOKEN|1|Drive the Hermes fleet from Telegram via @BotFather token
Telegram fleet control (optional, Phase 20)|HERMES_TELEGRAM_ALLOWED_USERS|0|Comma-list of numeric Telegram user ids allowed to drive the fleet (REQUIRED for the bot to answer anyone — secure-by-default denies all)
CATALOG
}

# setup_mask VALUE — privacy-preserving preview of an already-set value.
setup_mask() {
  local v="$1"
  if [[ "${#v}" -le 4 ]]; then printf 'set'; else printf '…%s' "${v: -4}"; fi
}

# setup_prompt_one KEY SECRET DESC — show current state + prompt once.
# Enter (empty) keeps the current value (or skips). Non-empty writes via set_env.
setup_prompt_one() {
  local key="$1" is_secret="$2" desc="$3"
  local current state val
  current="$(get_env "$key" "")"
  if [[ -n "$current" ]]; then state="[set: $(setup_mask "$current")]"; else state="[not set]"; fi
  printf '  %-30s %s\n      ↳ %s\n' "$key" "$state" "$desc" >&2
  if [[ "$is_secret" == "1" ]]; then
    val="$(secret_input "    $key (Enter to skip/keep):")" || val=""
  else
    printf '    %s (Enter to skip/keep): ' "$key" >&2
    read -r val || val=""
  fi
  if [[ -n "$val" ]]; then
    set_env "$key" "$val"
    ok "$key saved (.env, 0600)"
  elif [[ -n "$current" ]]; then
    note "$key — kept unchanged"
  else
    note "$key — skipped"
  fi
}

# setup_docker_context — interactive, skippable preference for whether ai-stack
# auto-points your GLOBAL `docker context` at the selected engine. This is the
# ONLY place a human is asked about it: install / doctor apply the saved policy
# silently (never prompt). Default (and Enter) = switch; 'n' = keep (non-invasive).
setup_docker_context() {
  # Belt-and-suspenders against NO_PROMPT even if a future refactor calls this
  # outside setup_run's interactive gate (setup_run already enforces the ! -t 0 gate).
  [[ "${NO_PROMPT:-0}" == "1" ]] && return 0
  local cur; cur="$(get_env AI_STACK_DOCKER_CONTEXT switch)" || cur="switch"
  printf '\n— Docker context —\n' >&2
  printf '  %-30s [%s]\n      ↳ %s\n' "AI_STACK_DOCKER_CONTEXT" "$cur" \
    "auto-point your global 'docker context' at ai-stack-<engine> (other shells see it too; ai-stack itself always uses DOCKER_HOST regardless)" >&2
  if confirm "    Auto-switch the global docker context to the ai-stack engine?" Y; then
    set_env AI_STACK_DOCKER_CONTEXT switch && ok "AI_STACK_DOCKER_CONTEXT=switch (.env)"
  else
    set_env AI_STACK_DOCKER_CONTEXT keep && ok "AI_STACK_DOCKER_CONTEXT=keep — global context left untouched (.env)"
  fi
}

# setup_run — the `mayssam-ai-stack.sh setup` body. Ensures baseline, then (if
# interactive) walks the optional-secret catalog.
setup_run() {
  hdr "Interactive .env setup"
  env_ensure_baseline
  ok "Baseline ready — .env @ 0600, service URLs set, LITELLM_MASTER_KEY + PHOENIX_SECRET generated."

  # Self-heal: an earlier setup had a stdin-collision bug (fixed below) that could
  # write THIS catalog's own definition lines into .env as VALUES, e.g.
  #   ANTHROPIC_API_KEY=Cloud LLM providers (optional)|OPENAI_API_KEY|1|...
  # Scrub them back to empty — but ONLY when a key's value is byte-IDENTICAL to an
  # actual catalog definition line. (A shape heuristic could nuke a legit value
  # that happens to look catalog-ish; exact membership cannot false-positive — a
  # real key/token/id-list can't equal a definition line by accident.)
  local _sk _sv _cl _g _sec _desc
  local -a _catlines=()
  mapfile -t _catlines < <(_setup_catalog)
  for _cl in "${_catlines[@]}"; do
    IFS='|' read -r _g _sk _sec _desc <<<"$_cl"
    [[ -z "$_sk" ]] && continue
    _sv="$(get_env "$_sk" "" 2>/dev/null)" || _sv=""   # guarded: never abort scrub under set -e
    [[ -z "$_sv" ]] && continue
    local _other
    for _other in "${_catlines[@]}"; do
      if [[ "$_sv" == "$_other" ]]; then
        set_env "$_sk" ""
        warn "cleared corrupted $_sk (leaked catalog text from an older setup bug)"
        break
      fi
    done
  done

  if [[ "${NO_PROMPT:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    note "Non-interactive (NO_PROMPT or no TTY): skipped the optional API-key prompts."
    note "A local-only / Claude-subscription setup needs nothing more — run 'doctor' next."
    note "Add keys anytime, interactively: mayssam-ai-stack.sh setup"
    : > "$SETUP_OFFERED_STAMP" 2>/dev/null || true
    return 0
  fi

  echo >&2
  note "Everything below is OPTIONAL and skippable (press Enter to skip each one)."
  note "Local gemma + Claude-subscription (-sub, incl. opus) models need NONE of these keys."

  # Read the catalog into an array FIRST, then iterate. The previous form piped
  # the catalog onto the loop's stdin (`while … < <(_setup_catalog)`), so the
  # per-key prompt's `read`/`secret_input` consumed the NEXT CATALOG LINE instead
  # of the user's keystroke — writing catalog text into .env. With an array, the
  # prompt loop's stdin stays the terminal, so reads get the user's input.
  local last_group="" entry group key sec desc
  local -a _catalog=()
  mapfile -t _catalog < <(_setup_catalog)
  for entry in "${_catalog[@]}"; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r group key sec desc <<<"$entry"
    [[ -z "$key" ]] && continue
    if [[ "$group" != "$last_group" ]]; then printf '\n— %s —\n' "$group" >&2; last_group="$group"; fi
    setup_prompt_one "$key" "$sec" "$desc"
  done

  # Non-secret operational preference: the global docker-context policy. Asked
  # here (the one interactive place) so install/doctor stay fully non-interactive.
  setup_docker_context

  echo >&2
  note "Claude subscription models (-sub, incl. opus): no API key needed — start the Meridian"
  note "daemon ('bin/start-meridian.sh') and run 'claude login'. See doc/models.md."
  ok "Setup complete. Next: mayssam-ai-stack.sh install all   (then: mayssam-ai-stack.sh doctor)"
  : > "$SETUP_OFFERED_STAMP" 2>/dev/null || true
}

# setup_maybe_offer — first-run, TTY-only, skippable offer to run setup, invoked
# from `cmd_install` (any target — `all` OR a single `install <phase>`). Stays
# silent under NO_PROMPT / --yes / non-TTY, once a cloud key is already set, or
# once already offered (stamp). Never blocks CI.
setup_maybe_offer() {
  [[ -t 0 ]] || return 0
  [[ "${NO_PROMPT:-0}" == "1" ]] && return 0
  [[ "${AI_STACK_ASSUME_YES:-0}" == "1" ]] && return 0
  [[ -f "$SETUP_OFFERED_STAMP" ]] && return 0
  # Ensure the stamp's dir exists — on a fresh clone a standalone `install <phase>`
  # may reach here before Phase 00 has created installer/state/, so the stamp write
  # below would silently fail and the offer would repeat. (Review finding.)
  mkdir -p "$(dirname "$SETUP_OFFERED_STAMP")" 2>/dev/null || true
  local k
  for k in "${_SETUP_CLOUD_KEYS[@]}"; do
    if [[ -n "$(get_env "$k" "")" ]]; then
      : > "$SETUP_OFFERED_STAMP" 2>/dev/null || true
      return 0
    fi
  done
  echo
  note "First run — you can set optional API keys now (all skippable; local + Claude-sub need none)."
  if confirm "Run interactive key setup now?" Y; then
    setup_run
  else
    : > "$SETUP_OFFERED_STAMP" 2>/dev/null || true
    note "Skipped. Add keys anytime with: mayssam-ai-stack.sh setup"
  fi
}
