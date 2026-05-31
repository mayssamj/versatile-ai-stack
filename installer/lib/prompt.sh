# prompt.sh — interactive prompts (yes/no, choose-one, secret).
# Sourced after common.sh. Falls back to defaults under NO_PROMPT=1.

[[ -z "${AI_STACK:-}" ]] && { echo "prompt.sh: AI_STACK unset" >&2; exit 2; }

# confirm "question text?" [default Y|N]
# Returns 0 for yes, 1 for no.
confirm() {
  local q="$1" def="${2:-Y}"
  local hint
  [[ "$def" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
  # Explicit non-interactive "assume yes" (e.g. `reset --confirm hard --yes`).
  # Distinct from NO_PROMPT, which only applies the *default* — and destructive
  # prompts default to N, so NO_PROMPT would silently ABORT them. AI_STACK_ASSUME_YES
  # means "the operator already confirmed out-of-band; proceed". The question is
  # still echoed for audit-log visibility. Strong typed gates (e.g. nuke's
  # "type 'nuke ai-stack'") do NOT use confirm() and are intentionally unaffected.
  if [[ "${AI_STACK_ASSUME_YES:-0}" == "1" ]]; then
    printf '%s %s y  (auto-yes via AI_STACK_ASSUME_YES)\n' "$q" "$hint"
    return 0
  fi
  if [[ "${NO_PROMPT:-0}" == "1" ]]; then
    [[ "$def" == "Y" ]] && return 0 || return 1
  fi
  local ans
  printf '%s %s ' "$q" "$hint"
  if ! read -r ans; then
    ans=""
  fi
  ans="${ans:-$def}"
  case "${ans^^}" in
    Y|YES) return 0 ;;
    *)     return 1 ;;
  esac
}

# choose "Prompt" opt1 opt2 ...
# Echoes the chosen value.
choose() {
  local prompt="$1"; shift
  if [[ "${NO_PROMPT:-0}" == "1" ]]; then
    printf '%s' "$1"
    return 0
  fi
  local i=1
  printf '%s\n' "$prompt" >&2
  for o in "$@"; do
    printf '  [%d] %s\n' "$i" "$o" >&2
    i=$((i+1))
  done
  local choice
  printf '> ' >&2
  read -r choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > $# )); then
    err "Invalid selection: $choice"
    return 2
  fi
  printf '%s' "${!choice}"
}

# secret_input "Prompt"  — reads with -s (no echo).
#
# Scrubs non-printable + browser-paste cruft so a hidden U+00A0 (NBSP) or
# zero-width char in a pasted secret doesn't silently corrupt downstream auth
# (Reviewer Y-11). Specifically strips:
#   - ASCII control chars (tab, CR, LF, etc.)
#   - U+00A0  NBSP            (most common browser-paste hazard)
#   - U+200B  ZERO-WIDTH SPACE
#   - U+200C  ZERO-WIDTH NON-JOINER
#   - U+200D  ZERO-WIDTH JOINER
#   - U+FEFF  BOM
#   - Leading + trailing ASCII whitespace
secret_input() {
  local q="$1"
  if [[ "${NO_PROMPT:-0}" == "1" ]]; then
    err "secret_input: cannot prompt under NO_PROMPT=1"
    return 2
  fi
  printf '%s ' "$q" >&2
  local val
  read -rs val
  printf '\n' >&2
  # Strip ASCII control characters.
  val="$(printf '%s' "$val" | LC_ALL=C tr -d '[:cntrl:]')"
  # Strip common invisible-but-printable Unicode (UTF-8 byte sequences).
  val="${val//$'\xc2\xa0'/}"      # NBSP
  val="${val//$'\xe2\x80\x8b'/}"  # ZWSP
  val="${val//$'\xe2\x80\x8c'/}"  # ZWNJ
  val="${val//$'\xe2\x80\x8d'/}"  # ZWJ
  val="${val//$'\xef\xbb\xbf'/}"  # BOM
  # Trim leading/trailing ASCII whitespace.
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}
