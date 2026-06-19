#!/usr/bin/env python3
"""
openshell-jwt-mint.py — host-side, in-place re-mint of an OpenShell sandbox JWT.

Mints a fresh-`exp` token that MIRRORS the existing token's claims exactly
(iss/aud/sub/sandbox_id + header kid/alg), re-signing with the gateway's
on-disk Ed25519 signing key. Purpose: refresh a sandbox's 1h bootstrap token
WITHOUT recreating the sandbox (which destroys /sandbox state).

SECURITY (the hardened rewrite the 2026-06-08 audit required):
  • Single self-contained program. Token + key material are handled ONLY as
    Python bytes/objects — NEVER interpolated into a shell, heredoc, or log line.
  • Never prints the token, signature, or private key. Only prints claim
    metadata (exp/iat/kid/sandbox_id) needed for operability.
  • Writes to a temp file in the same dir, fsync, atomic os.replace; ALWAYS
    keeps <token>.bak. Original is never clobbered in place.
  • --dry-run (default unless --write) makes no changes.

This does NOT restart any container — the caller decides when to `docker restart`
(the relay re-reads sandbox.jwt on connect). Exit: 0 ok / 2 usage / 3 crypto/io.
"""
import argparse, base64, json, os, subprocess, sys, tempfile, time

# The gateway's signing key is PKCS#8-v2 Ed25519, which macOS system LibreSSL may
# not sign via `pkeyutl -rawin`; resolve a capable OpenSSL 3.x (env override lets
# launchd's minimal PATH point at brew's openssl explicitly).
OPENSSL = os.environ.get("OPENSSL_BIN", "openssl")

def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def b64url_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")

def die(msg: str, code: int = 3):
    print(f"✗ {msg}", file=sys.stderr); sys.exit(code)

def _ed25519_sign(signing_key: str, message: bytes) -> bytes:
    """Raw Ed25519 sign via openssl pkeyutl. The gateway's PKCS#8-v2 key isn't
    loadable by cryptography 48 ('extra data'), but openssl signs it natively.
    SECURITY: message goes through a temp FILE passed as fixed argv — never a
    shell string; no token/claim bytes ever reach a shell or a log line."""
    md = sd = None
    try:
        fd, md = tempfile.mkstemp(prefix=".jwtmsg."); os.write(fd, message); os.close(fd)
        sfd, sd = tempfile.mkstemp(prefix=".jwtsig."); os.close(sfd)
        try:
            r = subprocess.run([OPENSSL, "pkeyutl", "-sign", "-inkey", signing_key,
                                "-rawin", "-in", md, "-out", sd],
                               capture_output=True, text=True)
        except (FileNotFoundError, PermissionError) as e:
            die(f"openssl not runnable ({OPENSSL!r}): {e} — need OpenSSL 3.x (set OPENSSL_BIN)", 3)
        if r.returncode != 0:
            die(f"openssl signing failed (need OpenSSL 3.x, not LibreSSL): {r.stderr.strip()[:300]}")
        sig = open(sd, "rb").read()
        if len(sig) != 64:
            die(f"unexpected Ed25519 signature length {len(sig)} (want 64)")
        return sig
    finally:
        for p in (md, sd):
            if p and os.path.exists(p):
                os.unlink(p)

def _ed25519_verify(pubkey: str, message: bytes, sig: bytes) -> bool:
    """Best-effort self-verify via openssl (used in dry-run / sanity)."""
    if not (pubkey and os.path.isfile(pubkey)):
        return False
    md = sd = None
    try:
        fd, md = tempfile.mkstemp(prefix=".jwtvm."); os.write(fd, message); os.close(fd)
        sfd, sd = tempfile.mkstemp(prefix=".jwtvs."); os.write(sfd, sig); os.close(sfd)
        r = subprocess.run([OPENSSL, "pkeyutl", "-verify", "-pubin", "-inkey", pubkey,
                            "-rawin", "-in", md, "-sigfile", sd],
                           capture_output=True, text=True)
        return r.returncode == 0
    finally:
        for p in (md, sd):
            if p and os.path.exists(p):
                os.unlink(p)

def main() -> int:
    ap = argparse.ArgumentParser(description="In-place re-mint of an OpenShell sandbox JWT (mirrors claims, fresh exp).")
    ap.add_argument("--token", required=True, help="path to sandbox.jwt")
    ap.add_argument("--signing-key", default=os.path.expanduser(
        "~/.local/state/openshell/homebrew/tls/jwt/signing.pem"), help="Ed25519 signing key (PEM)")
    ap.add_argument("--pubkey", default=os.path.expanduser(
        "~/.local/state/openshell/homebrew/tls/jwt/public.pem"), help="Ed25519 public key (PEM) for self-verify")
    ap.add_argument("--ttl", type=int, default=3600, help="new token TTL in seconds (default 3600)")
    ap.add_argument("--now", type=int, default=None, help="override 'now' epoch (testing only)")
    ap.add_argument("--exp-only", action="store_true",
                    help="print seconds-until-expiry (exp - now) of the EXISTING token and exit (no mint)")
    ap.add_argument("--write", action="store_true", help="actually write (default: dry-run, no changes)")
    args = ap.parse_args()

    if not os.path.isfile(args.token):
        die(f"token not found: {args.token}", 2)
    if not os.path.isfile(args.signing_key):
        die(f"signing key not found: {args.signing_key}", 2)

    try:
        with open(args.token) as f:
            raw = f.read().strip()
        parts = raw.split(".")
        if len(parts) != 3:
            die(f"not a 3-part JWS ({len(parts)} parts)")
        header = json.loads(b64url_decode(parts[0]))
        payload = json.loads(b64url_decode(parts[1]))
    except Exception as e:
        die(f"cannot parse existing token: {e}")

    if header.get("alg") != "EdDSA":
        die(f"unexpected alg {header.get('alg')!r} (only EdDSA supported)")

    now = args.now if args.now is not None else int(time.time())
    if args.exp_only:                      # proactive-check helper for the watchdog
        print(int(payload.get("exp", 0)) - now)
        return 0
    new_payload = dict(payload)              # mirror ALL claims verbatim
    new_payload["iat"] = now
    new_payload["exp"] = now + args.ttl
    if "nbf" in new_payload:
        new_payload["nbf"] = now

    signing_input = (b64url_encode(json.dumps(header, separators=(",", ":")).encode())
                     + "." + b64url_encode(json.dumps(new_payload, separators=(",", ":")).encode()))
    sig = _ed25519_sign(args.signing_key, signing_input.encode("ascii"))
    new_token = signing_input + "." + b64url_encode(sig)

    # Refuse to write a token we can't self-verify against the gateway's PUBLIC key:
    # catches a stale/rotated signing key (kid mismatch) before the gateway would
    # reject it — otherwise the watchdog "heals" while the sandbox keeps storming.
    if os.path.isfile(args.pubkey) and not _ed25519_verify(args.pubkey, signing_input.encode("ascii"), sig):
        die("minted signature FAILED self-verify vs public.pem (stale/rotated signing key?) — refusing to write", 3)

    print(f"  sandbox_id : {new_payload.get('sandbox_id')}")
    print(f"  kid        : {header.get('kid')}")
    print(f"  old exp    : {payload.get('exp')}  new exp: {new_payload['exp']}  (+{args.ttl}s from now={now})")

    if not args.write:
        print("DRY RUN — re-mint computed; pass --write to apply.")
        if _ed25519_verify(args.pubkey, signing_input.encode("ascii"), sig):
            print("  self-verify (openssl, vs public.pem): signature valid ✓")
        else:
            print("  self-verify: SKIPPED/failed (public.pem absent or mismatch) — informational only")
        return 0

    # atomic write; .bak ALWAYS holds the token we are about to displace (true 1-deep
    # rollback — not just the first-ever token), written + fsync'd BEFORE the replace.
    bak = args.token + ".bak"
    try:
        with open(bak, "w") as f:
            f.write(raw); f.flush(); os.fsync(f.fileno())
        d = os.path.dirname(args.token)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".jwt.", suffix=".tmp")
        with os.fdopen(fd, "w") as f:
            f.write(new_token); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, args.token)
    except Exception as e:
        die(f"write failed (original untouched): {e}")
    print(f"✓ re-minted {args.token} (backup at {os.path.basename(bak)}); `docker restart` the sandbox to apply.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
