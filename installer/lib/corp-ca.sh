#!/usr/bin/env bash
# corp-ca.sh — corporate root-CA trust bootstrap for the stack's outbound-HTTPS callers.
#
# WHY THIS EXISTS
# On an employer-managed Mac a Secure Web Gateway (Zscaler / Netskope / …) intercepts outbound
# 443 with ITS OWN MITM cert. The HOST trusts the corporate root (it ships in the System
# keychain), but CONTAINERS and node/python runtimes use their OWN bundled CA set and REJECT the
# MITM cert — so every cloud HTTPS call (LiteLLM->Anthropic/OpenAI, Meridian, codex-bridge,
# brew/pip/npm/git) fails cert-verify the moment interception is active. This module detects the
# corporate root and produces a combined PEM bundle those callers can trust, so the cloud tier
# keeps WORKING under interception instead of safely-but-totally 503-ing.
#
# OPT-IN + SAFE (AI_STACK_CORP_CA): `auto` (default) injects ONLY when a corp root is actually
# detected — a no-op on a non-corporate box; `off` never injects; `<path>` uses a specific bundle.
# Read-only host observation via `security`; NEVER disables TLS verification (verify=False /
# NODE_TLS_REJECT_UNAUTHORIZED=0 would defeat the point AND trip DLP/EDR); NEVER touches the
# security agents. The generated bundle holds ONLY certificates (no private keys — `-a -p` does
# not emit keys; asserted below) at mode 0644.
#
# CONTRACT: functions only, no top-level side effects, bash-3.2-safe — safe to source anywhere.

[[ -n "${_CORP_CA_SH:-}" ]] && return 0 2>/dev/null || true
_CORP_CA_SH=1

# Substrings matched (case-insensitive) against keychain cert labels / a live cert issuer to
# recognize a corporate-MITM root. Zscaler is the confirmed one on this box; the rest make the
# detector portable across common SWG vendors.
_CORP_CA_VENDORS='Zscaler|Netskope|Forcepoint|Palo Alto|Cisco Umbrella|McAfee Web|Broadcom|Blue Coat|Symantec Web Gateway|Menlo|Lightspeed|Corporate Proxy'

# corp_ca_mode — echo the configured mode (a path | off | auto). Default auto.
corp_ca_mode() { printf '%s' "${AI_STACK_CORP_CA:-auto}"; }

# corp_ca_detected — rc 0 iff a corporate-MITM root CA is present in the macOS System keychain.
# CAPTURE-then-grep (NOT `security | grep -q`): under `set -o pipefail`, grep -q closes the pipe
# on the first match -> `security` gets SIGPIPE (141) -> the pipeline returns 141 -> a true match
# is misreported as "not detected" (racy/flaky). A herestring has no pipe, so no SIGPIPE.
corp_ca_detected() {
  command -v security >/dev/null 2>&1 || return 1
  local certs
  certs="$(security find-certificate -a /Library/Keychains/System.keychain 2>/dev/null || true)"
  grep -qiE "$_CORP_CA_VENDORS" <<<"$certs"
}

# _corp_ca_out — the generated bundle path (under installer/state, which is gitignored).
_corp_ca_out() { printf '%s' "${AI_STACK:-$HOME/ai-stack}/installer/state/corp-ca.pem"; }

# corp_ca_bundle — ensure + echo the path to a combined PEM bundle (public roots + the System-
# keychain corp roots) an outbound-HTTPS caller can trust under interception. Honors
# AI_STACK_CORP_CA. rc 1 when nothing should be injected (off / no corp root in auto / bad path).
# Idempotent: regenerate only when missing or older than the System keychain.
corp_ca_bundle() {
  local mode out tmp kc="/Library/Keychains/System.keychain"
  mode="$(corp_ca_mode)"
  case "$mode" in
    off)  return 1 ;;
    auto) corp_ca_detected || return 1 ;;
    *)    if [[ -f "$mode" ]]; then printf '%s' "$mode"; return 0; else return 1; fi ;;
  esac
  command -v security >/dev/null 2>&1 || return 1
  out="$(_corp_ca_out)"
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  if [[ -f "$out" && -s "$out" && ! "$kc" -nt "$out" ]]; then printf '%s' "$out"; return 0; fi
  tmp="$(mktemp "${out}.XXXXXX" 2>/dev/null)" || return 1
  {
    security find-certificate -a -p /System/Library/Keychains/SystemRootCertificates.keychain 2>/dev/null
    security find-certificate -a -p "$kc" 2>/dev/null
  } > "$tmp" 2>/dev/null
  # Defense: must hold certs and NO private key (a leaked key would be a 0644 secret-on-disk).
  if ! grep -q 'BEGIN CERTIFICATE' "$tmp" 2>/dev/null || grep -q 'PRIVATE KEY' "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null; return 1
  fi
  chmod 0644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s' "$out"
}

# corp_ca_intercepted [host] — rc 0 iff TLS to <host> (default api.anthropic.com) is CURRENTLY
# MITM'd (the served cert's issuer matches a corp vendor), rc 1 if it's a real public CA, rc 2 if
# undetermined (no openssl / no egress). ONE benign read-only handshake (no HTTP request, no
# quota). Bounded by the caller. Used by the doctor check's opt-in deep probe.
corp_ca_intercepted() {
  local host="${1:-api.anthropic.com}" issuer ossl
  ossl="$(command -v openssl 2>/dev/null || true)"; [[ -n "$ossl" ]] || return 2
  issuer="$(echo | "$ossl" s_client -connect "$host:443" -servername "$host" 2>/dev/null \
            | "$ossl" x509 -noout -issuer 2>/dev/null)"
  [[ -n "$issuer" ]] || return 2
  grep -qiE "$_CORP_CA_VENDORS" <<<"$issuer" && return 0 || return 1
}
