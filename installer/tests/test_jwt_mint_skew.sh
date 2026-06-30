#!/usr/bin/env bash
# test_jwt_mint_skew.sh — offline unit test for the R3 clock-skew backdate in
# bin/openshell-jwt-mint.py. Uses a THROWAWAY Ed25519 keypair (NOT the gateway key); no gateway,
# no network, no model. Skips cleanly if OpenSSL 3.x is unavailable. Run: bash this.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINT="$HERE/../../bin/openshell-jwt-mint.py"
OSSL=""
for c in /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/bin/openssl; do
  [[ -x "$c" ]] && ! "$c" version 2>/dev/null | grep -qi libressl && { OSSL="$c"; break; }
done
[[ -n "$OSSL" ]] || { echo "  [skip] no OpenSSL 3.x — R3 skew test skipped"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$OSSL" genpkey -algorithm ed25519 -out "$TMP/signing.pem" 2>/dev/null
"$OSSL" pkey -in "$TMP/signing.pem" -pubout -out "$TMP/public.pem" 2>/dev/null
b64url(){ python3 -c 'import sys,base64;print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).rstrip(b"=").decode())'; }
H="$(printf '{"alg":"EdDSA","typ":"JWT","kid":"x"}' | b64url)"
P="$(printf '{"sub":"s","iss":"i","aud":"a","sandbox_id":"sb","iat":1000,"exp":4600,"nbf":1000}' | b64url)"
printf '%s.%s.%s' "$H" "$P" "AAAA" > "$TMP/sandbox.jwt"

PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
_claim(){ python3 -c 'import sys,base64,json;t=open(sys.argv[1]).read().split(".")[1];print(json.loads(base64.urlsafe_b64decode(t+"="*(-len(t)%4)))[sys.argv[2]])' "$1" "$2"; }
_mint(){ OPENSSL_BIN="$OSSL" python3 "$MINT" --token "$TMP/sandbox.jwt" --signing-key "$TMP/signing.pem" --pubkey "$TMP/public.pem" --write "$@" >/dev/null 2>&1; }

echo "== R3: iat/nbf backdated by --skew, exp = now+ttl =="
_mint --now 100000 --skew 300 --ttl 3600
[[ "$(_claim "$TMP/sandbox.jwt" iat)" == "99700"  ]] && ok "iat = now-skew (99700)"      || bad "iat=$(_claim "$TMP/sandbox.jwt" iat) want 99700"
[[ "$(_claim "$TMP/sandbox.jwt" nbf)" == "99700"  ]] && ok "nbf = now-skew (99700)"      || bad "nbf=$(_claim "$TMP/sandbox.jwt" nbf) want 99700"
[[ "$(_claim "$TMP/sandbox.jwt" exp)" == "103600" ]] && ok "exp = now+ttl (103600, full life)" || bad "exp=$(_claim "$TMP/sandbox.jwt" exp) want 103600"

echo "== R3: skew clamped to [0, ttl-1] — never mints an already-expired token =="
_mint --now 100000 --skew 99999 --ttl 3600   # over-large skew clamps to ttl-1=3599
[[ "$(_claim "$TMP/sandbox.jwt" iat)" == "96401" ]] && ok "over-large skew clamped to ttl-1 (iat=now-3599)" || bad "iat=$(_claim "$TMP/sandbox.jwt" iat) want 96401"
_mint --now 100000 --skew -50 --ttl 3600      # negative skew clamps to 0
[[ "$(_claim "$TMP/sandbox.jwt" iat)" == "100000" ]] && ok "negative skew clamped to 0 (iat=now)" || bad "iat=$(_claim "$TMP/sandbox.jwt" iat) want 100000"

echo "== R3: --exp-only is unchanged (decodes, no skew, no signing) =="
expleft="$(OPENSSL_BIN="$OSSL" python3 "$MINT" --token "$TMP/sandbox.jwt" --signing-key "$TMP/signing.pem" --now 100000 --exp-only 2>/dev/null)"
# after the last mint, exp was 100000+3600=103600; --exp-only at now=100000 -> 3600
[[ "$expleft" == "3600" ]] && ok "--exp-only prints exp-now (3600), unaffected by skew" || bad "--exp-only=$expleft want 3600"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
