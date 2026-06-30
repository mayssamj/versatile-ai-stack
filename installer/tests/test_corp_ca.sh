#!/usr/bin/env bash
# test_corp_ca.sh — offline unit test for installer/lib/corp-ca.sh. A fake `security` makes
# detection/bundle deterministic (no dependency on the real keychain). NO network. Run:
# bash installer/tests/test_corp_ca.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/corp-ca.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Fake `security`: label mode (no -p) echoes $FAKE_LABELS; PEM mode (-p) echoes one fake cert.
cat > "$TMP/security" <<'EOF'
#!/usr/bin/env bash
_p=0; for a in "$@"; do [[ "$a" == "-p" ]] && _p=1; done
if (( _p )); then   # PEM mode — emit a DISTINCT marker per keychain so the union is testable
  case "$*" in
    *SystemRootCertificates*) printf -- '-----BEGIN CERTIFICATE-----\nPUBLICROOT\n-----END CERTIFICATE-----\n';;
    *System.keychain*)        printf -- '-----BEGIN CERTIFICATE-----\nCORPROOT\n-----END CERTIFICATE-----\n';;
  esac
  exit 0
fi
printf '%s\n' "${FAKE_LABELS:-labl \"DigiCert Global Root\"}"
EOF
# fake `openssl` for corp_ca_intercepted: s_client emits a cert blob; x509 emits $FAKE_ISSUER.
cat > "$TMP/openssl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  s_client) cat >/dev/null 2>&1; printf 'CERTBLOB\n';;
  x509)     printf '%s\n' "${FAKE_ISSUER:-}";;
esac
EOF
chmod +x "$TMP/openssl"
chmod +x "$TMP/security"
export PATH="$TMP:$PATH" AI_STACK="$TMP"
mkdir -p "$TMP/installer/state"

PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
# shellcheck disable=SC1090
source "$LIB"

echo "== corp_ca_mode =="
[[ "$(corp_ca_mode)" == "auto" ]] && ok "default mode = auto" || bad "default mode=$(corp_ca_mode)"
[[ "$(AI_STACK_CORP_CA=off corp_ca_mode)" == "off" ]] && ok "AI_STACK_CORP_CA=off honored" || bad "off mode wrong"

echo "== corp_ca_detected (+ pipefail safety — the SIGPIPE regression) =="
export FAKE_LABELS='labl "Zscaler Root CA"'
r=""; for i in 1 2 3 4 5; do corp_ca_detected && r="$r Y" || r="$r n"; done
[[ "$r" == " Y Y Y Y Y" ]] && ok "Zscaler label -> detected, STABLE under pipefail x5 ($r)" || bad "flaky/undetected: '$r'"
export FAKE_LABELS='labl "DigiCert Global Root"'
corp_ca_detected && bad "DigiCert wrongly detected as corp" || ok "non-corp label -> not detected"

echo "== corp_ca_bundle =="
export FAKE_LABELS='labl "Zscaler Root CA"'
b="$(corp_ca_bundle 2>/dev/null || true)"
{ [[ -n "$b" && -f "$b" ]] && grep -q 'BEGIN CERTIFICATE' "$b" && ! grep -q 'PRIVATE KEY' "$b"; } \
  && ok "auto + detected -> builds bundle (certs, no keys), perms $(stat -f %Lp "$b" 2>/dev/null)" || bad "bundle not built: '$b'"
{ grep -q PUBLICROOT "$b" && grep -q CORPROOT "$b"; } \
  && ok "bundle = public roots UNION corp roots (BOTH keychains present)" || bad "bundle missing a keychain's certs (not a union)"
[[ "$(stat -f %Lp "$b" 2>/dev/null)" == "644" ]] && ok "bundle is 0644 (no key, world-readable ok)" || bad "bundle perms wrong"
b2="$(corp_ca_bundle 2>/dev/null || true)"; [[ "$b2" == "$b" ]] && ok "idempotent (same path, no needless regen)" || bad "not idempotent"
export FAKE_LABELS='labl "DigiCert Global Root"'; rm -f "$b"
corp_ca_bundle >/dev/null 2>&1 && bad "auto + NOT detected still built a bundle" || ok "auto + not-detected -> no bundle (no-op on a non-corp box)"
AI_STACK_CORP_CA=off corp_ca_bundle >/dev/null 2>&1 && bad "off still built a bundle" || ok "off -> no bundle"
echo "fake-pem" > "$TMP/explicit.pem"
[[ "$(AI_STACK_CORP_CA="$TMP/explicit.pem" corp_ca_bundle)" == "$TMP/explicit.pem" ]] && ok "explicit path mode -> echoes that path" || bad "explicit path mode wrong"

echo "== corp_ca_intercepted (fake openssl): TLS-interception tri-state =="
export FAKE_ISSUER='issuer=C=US, O=Zscaler Inc., CN=Zscaler Root CA'
corp_ca_intercepted >/dev/null 2>&1; (( $? == 0 )) && ok "Zscaler issuer -> intercepted (rc0)" || bad "Zscaler issuer not rc0"
export FAKE_ISSUER='issuer=C=US, O=Google Trust Services LLC, CN=WE1'
corp_ca_intercepted >/dev/null 2>&1; (( $? == 1 )) && ok "public CA issuer -> NOT intercepted (rc1)" || bad "public issuer not rc1"
export FAKE_ISSUER=''
corp_ca_intercepted >/dev/null 2>&1; (( $? == 2 )) && ok "no issuer (no egress) -> undetermined (rc2)" || bad "empty issuer not rc2"
unset FAKE_ISSUER

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
