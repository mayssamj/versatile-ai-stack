# Corporate TLS-interception readiness (Zscaler / SWG) — CA-1/CA-2.
#
# On an employer-managed Mac a Secure Web Gateway (Zscaler) MITMs outbound 443 with its own cert.
# Containers + node/python runtimes use their OWN bundled CA set and REJECT the MITM cert unless
# the stack injects the corporate root (installer/lib/corp-ca.sh). This check makes a silent
# cloud-tier break VISIBLE BEFORE it bites: it reports whether a corp root is DETECTED and whether
# the stack is configured to TRUST it. Read-only/static by default (no bundle generation, no
# network). An OPT-IN deep probe (AI_STACK_CORP_CA_DEEP_CHECK=1) does ONE benign TLS handshake to
# report whether interception is ACTIVE right now. Never touches the security agents.
CHECKS+=(corp_ca)
CHECK_TITLE[corp_ca]="Corporate TLS-interception readiness (Zscaler CA trust)"

corp_ca_diagnose() {
  [[ -f "$AI_STACK/installer/lib/corp-ca.sh" ]] && source "$AI_STACK/installer/lib/corp-ca.sh" 2>/dev/null
  declare -F corp_ca_detected >/dev/null 2>&1 || { echo "corp-ca.sh not present [skip]"; return 0; }
  local mode; mode="$(corp_ca_mode)"
  if [[ "$mode" == "off" ]]; then echo "  (AI_STACK_CORP_CA=off — corporate CA trust disabled by config)"; return 0; fi
  if ! corp_ca_detected; then
    echo "  (no corporate root CA in the System keychain — not a corporate-MITM box; nothing to inject)"
    return 0
  fi
  # A corp root IS present -> the stack MUST trust it or cloud HTTPS breaks under interception.
  # Read-only: check the bundle PATH (do not generate it during doctor).
  local bundle; bundle="$(_corp_ca_out)"
  if [[ ! -s "$bundle" ]]; then
    echo "Corporate root CA DETECTED but the trust bundle is NOT generated yet — cloud calls"
    echo "  (LiteLLM/Meridian/codex) will FAIL cert-verify once Zscaler interception is active."
    echo "  Generate + inject:  bash $AI_STACK/bin/start-litellm.sh --recreate"
    return 1
  fi
  # Bundle exists — is the live LiteLLM container actually using it?
  local injected="unknown" docker cid
  docker="$(command -v docker 2>/dev/null || echo)"
  if [[ -n "$docker" ]]; then
    cid="$("$docker" ps -q --filter "name=litellm" 2>/dev/null | head -1)"
    if [[ -n "$cid" ]]; then
      if "$docker" inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -q '^REQUESTS_CA_BUNDLE='; then
        injected="yes"
      else
        injected="NO (recreate litellm to pick up the CA)"
      fi
    fi
  fi
  echo "  Corporate root CA detected; trust bundle present ($(grep -c 'BEGIN CERTIFICATE' "$bundle" 2>/dev/null || echo '?') certs). litellm CA-injected: $injected"
  if [[ "${AI_STACK_CORP_CA_DEEP_CHECK:-0}" == "1" ]] && declare -F corp_ca_intercepted >/dev/null 2>&1; then
    local rc=0; corp_ca_intercepted >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) echo "  deep probe: TLS interception is ACTIVE now (cloud endpoint served by the corp CA) — the injected bundle is what keeps cloud calls working." ;;
      1) echo "  deep probe: TLS interception NOT active right now (real public CA served) — the bundle is harmless + ready for when it turns on." ;;
      *) echo "  deep probe: undetermined (no egress/openssl)." ;;
    esac
  fi
  [[ "$injected" == NO* ]] && return 1 || return 0
}

corp_ca_fix() {
  warn "A corporate root CA is present but the stack isn't trusting it — inject it so cloud HTTPS"
  warn "survives Zscaler TLS interception (opt-in/auto; no-op on a non-corporate box):"
  warn "    bash $AI_STACK/bin/start-litellm.sh --recreate"
  warn "    bash $AI_STACK/bin/start-meridian.sh install        # if Meridian (opus-sub) is enabled"
  warn "    bash $AI_STACK/bin/start-codex-bridge.sh install     # if the codex bridge (gpt-sub) is enabled"
  return 1
}
