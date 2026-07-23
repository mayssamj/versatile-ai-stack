#!/usr/bin/env bash
# ============================================================
# EXPERIMENTAL — NOT AUTO-WIRED — OPERATOR INTERVENTION REQUIRED
# ============================================================
# openshell-token-refresh.sh — host-side re-mint of a sandbox's 1h bootstrap
# JWT for an EXISTING sandbox (does not create a new sandbox record).
#
# PURPOSE / HYPOTHESIS
# This is an experimental path to heal an expired-token storm WITHOUT recreating
# the sandbox (which loses in-sandbox state).  The gateway mints these JWTs using
# Ed25519/EdDSA with a signing key it controls.  IF the gateway also accepts an
# externally-minted token that mirrors all original claims (sub/iss/aud/sandbox_id)
# with a refreshed iat/exp, the sandbox relay will reconnect without a destroy.
#
# KNOWN UNKNOWN: the gateway MAY reject externally-minted tokens (e.g. token-id
# allowlist, nonce tracking, or key pinning per sandbox_id).  That is the
# experiment.  If the relay does NOT reconnect after 'docker restart', the gateway
# rejects external mints — fall back to the standard checkpoint+recreate path.
#
# SAFETY RAILS (non-negotiable even in the opt-in path):
#   • Writes to a TEMP file first, then atomic rename — original never clobbered.
#   • ALWAYS keeps sandbox.jwt.bak alongside the replacement.
#   • Requires AI_STACK_CONFIRM_REMINT=1 to ACTUALLY mint; without it, prints the
#     plan only (dry-run by default).
#   • Does NOT delete the sandbox or any container.
#   • If neither openssl nor python3 can perform EdDSA signing, exits clearly with
#     'cannot re-mint on this host' — never silently corrupts the existing token.
#
# Usage:
#   openshell-token-refresh.sh <sandbox-name>
#     → dry-run: inspect existing JWT, print plan, exit 0
#   AI_STACK_CONFIRM_REMINT=1 openshell-token-refresh.sh <sandbox-name>
#     → actually mint, write, restart container
#
# Environment tunables:
#   AI_STACK_CONFIRM_REMINT=1     enable minting (default: dry-run)
#   AI_STACK_TOKEN_TTL=3600       new token TTL in seconds (default: 3600 = 1h)
#   AI_STACK                      repo root (auto-detected from script location)
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
EVENT_LOG="$AI_STACK/installer/state/fleet-lifecycle.jsonl"
CONFIRM="${AI_STACK_CONFIRM_REMINT:-0}"
TOKEN_TTL="${AI_STACK_TOKEN_TTL:-3600}"

# Gateway state paths (host-side, read-only in this script).
GATEWAY_STATE="$HOME/.local/state/openshell/gateway"            # gateway sqlite DB lives here
# Signing material is NOT under gateway/ — it's at openshell/homebrew/tls/jwt (verified path,
# matches bin/openshell-identity-backup.sh; the earlier '$GATEWAY_STATE/homebrew/...' was wrong).
JWT_SIGN_DIR="$HOME/.local/state/openshell/homebrew/tls/jwt"
SIGNING_PEM="$JWT_SIGN_DIR/signing.pem"   # Ed25519 private key (PEM)
KID_FILE="$JWT_SIGN_DIR/kid"              # key-id string
TOKEN_BASE="$HOME/.local/state/openshell/docker-sandbox-tokens/default"

# ---------------------------------------------------------------------------
# Tool resolution (launchd-safe: check fixed paths before $PATH).
# ---------------------------------------------------------------------------
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
DOCKER="$(_find /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker)"

# Engine-aware: do NOT assume OrbStack. Prefer the gateway.env DOCKER_HOST (the
# gateway's own source of truth); fall back to the registry from AI_STACK_DOCKER_ENGINE.
if [[ -z "${DOCKER_HOST:-}" ]]; then
  _gw_dh="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -n "${_gw_dh:-}" ]]; then
    export DOCKER_HOST="$_gw_dh"
  elif [[ -n "${AI_STACK:-}" && -f "$AI_STACK/installer/lib/docker-engine.sh" ]]; then
    # shellcheck disable=SC1090
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"
    _eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
    if [[ -n "${_eng:-}" ]] && _engine_valid "$_eng" 2>/dev/null; then
      _dh="$(engine_socket "$_eng" 2>/dev/null || true)"; [[ -n "${_dh:-}" ]] && export DOCKER_HOST="$_dh"
    fi
  fi
  unset _gw_dh _eng _dh 2>/dev/null || true
fi
OPENSSL="$(_find /opt/homebrew/bin/openssl /usr/bin/openssl /usr/local/bin/openssl)"
PYTHON3="$(_find /opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3)"

_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------------------------------------------------------------------------
# _event <event> <sandbox> [k=v ...]
# ---------------------------------------------------------------------------
_esc() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }  # JSON-escape (audit 2026-06-08)
_event() {
  local ev="$1" sandbox="$2"; shift 2 || true
  local extra="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    extra="$extra,\"$(_esc "$k")\":\"$(_esc "$v")\""
  done
  mkdir -p "$(dirname "$EVENT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","component":"token-refresh","event":"%s","sandbox":"%s"%s}\n' \
    "$(_iso)" "$(_esc "$ev")" "$(_esc "$sandbox")" "$extra" >> "$EVENT_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _resolve_cid <name>
# ---------------------------------------------------------------------------
_resolve_cid() {
  local name="$1"
  [[ -n "$DOCKER" ]] && "$DOCKER" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1 || echo ""
}

# ---------------------------------------------------------------------------
# _b64url_decode_payload <jwt>
# Print the payload JSON of a JWT (base64url decode, no verification).
# ---------------------------------------------------------------------------
_b64url_decode_payload() {
  local jwt="$1"
  local payload_b64; payload_b64="$(printf '%s' "$jwt" | cut -d. -f2)"
  # base64url → base64: replace - with +, _ with /, add padding
  local padded len mod
  len="${#payload_b64}"
  mod=$(( len % 4 ))
  if (( mod == 2 )); then padded="${payload_b64}==";
  elif (( mod == 3 )); then padded="${payload_b64}=";
  else padded="$payload_b64"; fi
  printf '%s' "$padded" | tr '-_' '+/' | base64 -d 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _inspect_jwt <jwt-file>
# Print a human-readable summary of an existing JWT.
# ---------------------------------------------------------------------------
_inspect_jwt() {
  local file="$1"
  [[ -f "$file" ]] || { echo "  (file not found: $file)"; return 0; }
  local jwt; jwt="$(cat "$file")"
  local payload; payload="$(_b64url_decode_payload "$jwt")"
  echo "  JWT file : $file"
  if command -v python3 >/dev/null 2>&1 || [[ -n "$PYTHON3" ]]; then
    local py="${PYTHON3:-python3}"
    # SECURITY (audit 2026-06-08): pass the UNTRUSTED payload via STDIN to a FIXED -c
    # program — never interpolate it into the Python source (the old heredoc
    # json.loads("""$payload""") allowed code execution via a crafted token claim).
    printf '%s' "$payload" | "$py" -c '
import json, sys, datetime
try:
    p = json.loads(sys.stdin.read())
except Exception:
    print("  (payload not valid JSON)"); sys.exit(0)
for k, v in p.items():
    if k in ("iat", "exp", "nbf"):
        try:
            dt = datetime.datetime.utcfromtimestamp(int(v)).strftime("%Y-%m-%dT%H:%M:%SZ")
            print(f"  {str(k):15s}: {v}  ({dt})")
        except Exception:
            print(f"  {str(k):15s}: {v}")
    else:
        print(f"  {str(k):15s}: {v}")
now = int(datetime.datetime.utcnow().timestamp())
try:
    remaining = int(p.get("exp", 0)) - now
    print(f"  -- token expires in {remaining}s ({remaining//60} min) --" if remaining > 0
          else f"  -- token EXPIRED {-remaining}s ago --")
except Exception:
    pass
' 2>/dev/null || echo "  (python decode failed)"
  else
    echo "  payload  : (python3 not available to decode; raw payload omitted for safety)"
  fi
}

# ---------------------------------------------------------------------------
# _check_eddsa_capability
# Returns 0 if this host can sign with Ed25519, 1 otherwise.
# Sets SIGN_METHOD="openssl" or "python3".
# ---------------------------------------------------------------------------
SIGN_METHOD=""
_check_eddsa_capability() {
  # Try openssl EdDSA: openssl 3.x supports 'openssl pkeyutl -sign' with Ed25519.
  if [[ -n "$OPENSSL" ]]; then
    local ver; ver="$("$OPENSSL" version 2>/dev/null | head -1 || echo "")"
    # openssl 3.x supports Ed25519 pkeyutl signing.
    if echo "$ver" | grep -qE 'OpenSSL 3\.'; then
      SIGN_METHOD="openssl"
      return 0
    fi
  fi
  # Try python3 with cryptography or PyNaCl.
  if [[ -n "$PYTHON3" ]] || command -v python3 >/dev/null 2>&1; then
    local py="${PYTHON3:-python3}"
    if "$py" -c "from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey" 2>/dev/null; then
      SIGN_METHOD="python3-cryptography"
      return 0
    fi
    if "$py" -c "import nacl.signing" 2>/dev/null; then
      SIGN_METHOD="python3-nacl"
      return 0
    fi
  fi
  SIGN_METHOD=""
  return 1
}

# ---------------------------------------------------------------------------
# _b64url_encode <bytes-on-stdin>
# ---------------------------------------------------------------------------
_b64url_encode() {
  base64 | tr '+/' '-_' | tr -d '='
}

# ---------------------------------------------------------------------------
# _mint_jwt <sub> <iss> <aud> <sandbox_id> <kid> <signing_pem> <ttl>
# Outputs the signed JWT string to stdout.
# ---------------------------------------------------------------------------
_mint_jwt() {
  local sub="$1" iss="$2" aud="$3" sandbox_id="$4" kid="$5" pem="$6" ttl="$7"
  local now exp
  now="$(date +%s)"
  exp=$(( now + ttl ))

  # Build header and payload.
  local hdr_json="{\"alg\":\"EdDSA\",\"typ\":\"JWT\",\"kid\":\"$kid\"}"
  local pay_json="{\"sub\":\"$sub\",\"iss\":\"$iss\",\"aud\":\"$aud\",\"sandbox_id\":\"$sandbox_id\",\"iat\":$now,\"exp\":$exp}"

  local hdr_b64; hdr_b64="$(printf '%s' "$hdr_json" | _b64url_encode)"
  local pay_b64; pay_b64="$(printf '%s' "$pay_json" | _b64url_encode)"
  local signing_input="${hdr_b64}.${pay_b64}"

  local sig_b64
  case "$SIGN_METHOD" in
    openssl)
      # openssl 3.x pkeyutl with Ed25519 private key.
      sig_b64="$(printf '%s' "$signing_input" \
        | "$OPENSSL" pkeyutl -sign -inkey "$pem" \
        | _b64url_encode)"
      ;;
    python3-cryptography)
      local py="${PYTHON3:-python3}"
      sig_b64="$("$py" - "$pem" "$signing_input" <<'PYEOF'
import sys, base64
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

pem_path = sys.argv[1]
msg = sys.argv[2].encode()
with open(pem_path, 'rb') as f:
    key = load_pem_private_key(f.read(), password=None)
sig = key.sign(msg)
# base64url encode, no padding
print(base64.urlsafe_b64encode(sig).rstrip(b'=').decode())
PYEOF
)"
      ;;
    python3-nacl)
      local py="${PYTHON3:-python3}"
      sig_b64="$("$py" - "$pem" "$signing_input" <<'PYEOF'
import sys, base64
import nacl.signing, nacl.encoding

# nacl expects raw 32-byte seed; extract from PEM via cryptography or fall back
# to parsing the PKCS8 DER manually.
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PrivateFormat, NoEncryption
pem_path = sys.argv[1]
msg = sys.argv[2].encode()
with open(pem_path, 'rb') as f:
    key = load_pem_private_key(f.read(), password=None)
raw_seed = key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
sk = nacl.signing.SigningKey(raw_seed)
signed = sk.sign(msg)
sig = signed.signature
print(base64.urlsafe_b64encode(sig).rstrip(b'=').decode())
PYEOF
)"
      ;;
    *)
      echo "✗ cannot re-mint on this host: no supported Ed25519 signing backend found" >&2
      echo "  Checked: openssl 3.x, python3 cryptography library, python3 PyNaCl" >&2
      return 2
      ;;
  esac

  printf '%s.%s.%s\n' "$hdr_b64" "$pay_b64" "$sig_b64"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local name="${1:?usage: openshell-token-refresh.sh <sandbox-name>}"

  echo ""
  echo "================================================================"
  echo "  EXPERIMENTAL: host-side JWT re-mint for sandbox '$name'"
  echo "  This is NOT auto-wired.  Operator must set AI_STACK_CONFIRM_REMINT=1"
  echo "  to actually mint.  Without it this is a DRY RUN."
  echo "================================================================"
  echo ""

  # Locate sandbox token directory (tokens are stored per UUID sub-directory).
  local token_dir="" jwt_file=""
  if [[ -d "$TOKEN_BASE" ]]; then
    # Find the first sandbox.jwt that appears to belong to this sandbox.
    # The directories are UUID-named; we check if the JWT sub claim or
    # a parent dir matches.  In practice there may be only one.
    while IFS= read -r -d '' f; do
      # Inspect each JWT to find one whose sandbox_id matches.
      local pl; pl="$(_b64url_decode_payload "$(cat "$f")" 2>/dev/null || echo "")"
      if echo "$pl" | grep -q "\"$name\"" 2>/dev/null; then
        jwt_file="$f"
        token_dir="$(dirname "$f")"
        break
      fi
    done < <(find "$TOKEN_BASE" -name 'sandbox.jwt' -print0 2>/dev/null)
    # Fallback: if only one token dir exists, use it.
    if [[ -z "$jwt_file" ]]; then
      local first; first="$(find "$TOKEN_BASE" -name 'sandbox.jwt' 2>/dev/null | head -1)"
      if [[ -n "$first" ]]; then
        jwt_file="$first"
        token_dir="$(dirname "$first")"
        echo "  (note: could not match sandbox_id='$name' in token payload; using first found JWT)" >&2
      fi
    fi
  fi

  if [[ -z "$jwt_file" ]]; then
    echo "✗ no sandbox.jwt found under $TOKEN_BASE for sandbox '$name'" >&2
    echo "  Token directory structure may differ — inspect manually:" >&2
    echo "    ls $TOKEN_BASE" >&2
    _event "remint_failed" "$name" "cause=no-token-file"
    return 2
  fi

  echo "--- Existing token ---"
  _inspect_jwt "$jwt_file"
  echo ""

  # Decode claims from the existing JWT to mirror them.
  local existing_jwt; existing_jwt="$(cat "$jwt_file")"
  local payload_json; payload_json="$(_b64url_decode_payload "$existing_jwt")"

  # Extract claims (portable: use python3 if available, else grep+sed).
  local sub iss aud sandbox_id_claim
  if [[ -n "$PYTHON3" ]] || command -v python3 >/dev/null 2>&1; then
    local py="${PYTHON3:-python3}"
    sub="$("$py" -c "import json,sys; p=json.loads(sys.stdin.read()); print(p.get('sub',''))" <<<"$payload_json" 2>/dev/null || echo "")"
    iss="$("$py" -c "import json,sys; p=json.loads(sys.stdin.read()); print(p.get('iss',''))" <<<"$payload_json" 2>/dev/null || echo "")"
    aud="$("$py" -c "import json,sys; p=json.loads(sys.stdin.read()); print(p.get('aud',''))" <<<"$payload_json" 2>/dev/null || echo "")"
    sandbox_id_claim="$("$py" -c "import json,sys; p=json.loads(sys.stdin.read()); print(p.get('sandbox_id',''))" <<<"$payload_json" 2>/dev/null || echo "")"
  else
    # Minimal fallback: extract via sed (handles simple non-nested JSON values).
    sub="$(echo "$payload_json" | sed -n 's/.*"sub"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    iss="$(echo "$payload_json" | sed -n 's/.*"iss"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    aud="$(echo "$payload_json" | sed -n 's/.*"aud"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    sandbox_id_claim="$(echo "$payload_json" | sed -n 's/.*"sandbox_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi

  echo "--- Claims to mirror ---"
  echo "  sub        : $sub"
  echo "  iss        : $iss"
  echo "  aud        : $aud"
  echo "  sandbox_id : $sandbox_id_claim"
  echo "  new TTL    : ${TOKEN_TTL}s ($(( TOKEN_TTL / 60 )) min)"
  echo ""

  # Validate we have the signing material.
  if [[ ! -f "$SIGNING_PEM" ]]; then
    echo "✗ signing.pem not found at $SIGNING_PEM" >&2
    echo "  Cannot re-mint: gateway signing key is missing from expected location." >&2
    _event "remint_failed" "$name" "cause=no-signing-pem"
    return 2
  fi
  local kid=""
  [[ -f "$KID_FILE" ]] && kid="$(cat "$KID_FILE")" || { echo "⚠  kid file not found at $KID_FILE — using empty kid" >&2; kid=""; }

  # Check EdDSA capability.
  if ! _check_eddsa_capability; then
    echo "✗ cannot re-mint on this host: no supported Ed25519 signing backend found." >&2
    echo "  Checked: openssl 3.x, python3 cryptography library, python3 PyNaCl." >&2
    echo "  Install one of: 'pip3 install cryptography' or 'pip3 install PyNaCl'." >&2
    _event "remint_failed" "$name" "cause=no-eddsa-backend"
    return 2
  fi
  echo "  signing backend : $SIGN_METHOD"
  echo ""

  # Resolve container.
  local cid=""
  [[ -n "$DOCKER" ]] && cid="$(_resolve_cid "$name")" || cid=""

  echo "--- Plan ---"
  echo "  1. Back up $jwt_file → ${jwt_file}.bak"
  echo "  2. Mint new JWT (EdDSA, kid=$kid, TTL=${TOKEN_TTL}s) to temp file"
  echo "  3. Atomic rename temp → $jwt_file"
  echo "  4. docker restart ${cid:+(cid ${cid:0:12})}${cid:-(container not found yet)}"
  echo "  5. Observe: does the relay reconnect? (gateway may reject external mints)"
  echo ""

  if [[ "$CONFIRM" != "1" ]]; then
    echo "DRY RUN — set AI_STACK_CONFIRM_REMINT=1 to execute."
    _event "remint_dryrun" "$name" "signing_method=$SIGN_METHOD" "kid=$kid"
    return 0
  fi

  # ⚠ SECURITY GATE (audit 2026-06-08): the live mint path below interpolated untrusted
  # JWT payload/claims into a Python heredoc + JSON string (code + claim injection) while
  # holding the gateway Ed25519 signing key. It is DISABLED in this release pending a
  # security review + rewrite (decode/sign in ONE hardened python program; ZERO shell
  # interpolation of token data). The dry-run plan above is unaffected. Do NOT remove this
  # gate or run the code below until that rewrite lands. See the spec doc → residual risks.
  echo "✗ live re-mint is DISABLED pending security review (audit 2026-06-08: injection in the mint path)." >&2
  echo "  The dry-run plan above is safe; host-side re-mint is a tracked, security-gated follow-up." >&2
  echo "  doc/specs/2026-06-08-fleet-durability-hardening.md → residual risks." >&2
  _event "remint_blocked" "$name" "cause=pending-security-review"
  return 2

  # ------------------------------------------------------------------
  # CONFIRMED — actually mint the token.   [UNREACHABLE — gated above; do not re-enable
  #   without the injection-safe rewrite. Kept only to document the intended sequence.]
  # ------------------------------------------------------------------
  echo "AI_STACK_CONFIRM_REMINT=1 — proceeding with re-mint ..."
  echo ""

  # Validate required claims.
  if [[ -z "$sub" ]] || [[ -z "$iss" ]] || [[ -z "$aud" ]] || [[ -z "$sandbox_id_claim" ]]; then
    echo "✗ re-mint aborted: one or more required claims are empty (sub/iss/aud/sandbox_id)" >&2
    echo "  sub='$sub'  iss='$iss'  aud='$aud'  sandbox_id='$sandbox_id_claim'" >&2
    _event "remint_failed" "$name" "cause=missing-claims"
    return 2
  fi

  # Step 1: Backup.
  cp -f "$jwt_file" "${jwt_file}.bak"
  echo "✓ backup: ${jwt_file}.bak"

  # Step 2: Mint to temp file.
  local tmp_jwt; tmp_jwt="$(mktemp "${jwt_file}.XXXXXX")"
  # Ensure the temp file is removed on any unexpected exit (best-effort).
  trap 'rm -f "$tmp_jwt" 2>/dev/null || true' EXIT

  local new_jwt
  if ! new_jwt="$(_mint_jwt "$sub" "$iss" "$aud" "$sandbox_id_claim" "$kid" "$SIGNING_PEM" "$TOKEN_TTL")"; then
    echo "✗ minting FAILED — original token is untouched (backup: ${jwt_file}.bak)" >&2
    rm -f "$tmp_jwt" || true
    _event "remint_failed" "$name" "cause=mint-failed" "signing_method=$SIGN_METHOD"
    return 2
  fi
  printf '%s\n' "$new_jwt" > "$tmp_jwt"
  echo "✓ minted new JWT (${#new_jwt} chars) to temp file"

  # Quick sanity: new JWT should have 3 dot-separated parts.
  local dot_count; dot_count="$(printf '%s' "$new_jwt" | tr -cd '.' | wc -c | tr -d ' ')"
  if (( dot_count != 2 )); then
    echo "✗ sanity check FAILED: minted token does not look like a JWT (expected 3 parts, got $((dot_count+1)))" >&2
    rm -f "$tmp_jwt" || true
    _event "remint_failed" "$name" "cause=malformed-jwt"
    return 2
  fi

  # Step 3: Atomic rename.
  mv -f "$tmp_jwt" "$jwt_file"
  # Clear the trap since we've renamed successfully.
  trap '' EXIT
  echo "✓ atomic rename: $jwt_file updated"

  echo ""
  echo "--- New token inspection ---"
  _inspect_jwt "$jwt_file"
  echo ""

  _event "remint_ok" "$name" "signing_method=$SIGN_METHOD" "kid=$kid" "ttl=$TOKEN_TTL"

  # Step 4: docker restart.
  if [[ -z "$DOCKER" ]]; then
    echo "⚠  docker not found — skipping container restart." >&2
    echo "   Restart the container manually to load the new token." >&2
    return 0
  fi
  if [[ -z "$cid" ]]; then
    echo "⚠  container openshell-${name}-* not found — token written but container not restarted." >&2
    echo "   Start the sandbox; it will pick up the new token on boot." >&2
    return 0
  fi

  echo "· docker restart ${cid:0:12} ..."
  "$DOCKER" restart "$cid"
  echo "✓ container restarted"
  echo ""

  # Step 5: Observation guidance.
  cat <<OBSERVE
=== OBSERVATION REQUIRED ===
The container has been restarted with the re-minted token.

Watch the container logs to determine whether the gateway accepts the token:

  docker logs -f openshell-${name}-* 2>&1 | head -40

EXPECTED (gateway accepts external mint):
  - Relay connects, no 'ExpiredSignature' lines.
  - 'openshell sandbox list' shows '$name' as Ready within ~30s.

REJECTION (gateway does NOT accept external mint):
  - Continued 'ExpiredSignature' or 'invalid token' errors in the log.
  - Sandbox stays in a non-Ready state.
  - In this case: fall back to checkpoint + recreate:
      bash $AI_STACK/bin/openshell-checkpoint.sh $name manual
      mayssam-ai-stack.sh install <phases>
  - Original token backup is at: ${jwt_file}.bak

This experiment documents whether the platform's 'never lose state' goal can be
achieved via token re-mint alone — results should be captured in fleet docs.
============================
OBSERVE
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  ""|-h|--help)
    cat >&2 <<'USAGE'
usage: openshell-token-refresh.sh <sandbox-name>

EXPERIMENTAL — NOT AUTO-WIRED.
Re-mints a sandbox's 1h bootstrap JWT on the host using the gateway's Ed25519
signing key, then restarts the container so the relay can reconnect.

Set AI_STACK_CONFIRM_REMINT=1 to actually mint (default: dry-run / plan only).
Set AI_STACK_TOKEN_TTL=<seconds> to control new token lifetime (default: 3600).

Requires one of: openssl 3.x, python3 cryptography, or python3 PyNaCl.
If none is available, exits with 'cannot re-mint on this host'.
USAGE
    exit 2 ;;
  *) main "$1" ;;
esac
