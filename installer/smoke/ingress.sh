#!/usr/bin/env bash
# smoke/ingress.sh — bare-hostname host ingress.
#
# Slice 1 (this file): pure Caddyfile generator (AC-4) — zero-privilege, needs
# neither caddy nor the daemon. Later slices add live AC-1a/AC-2 probes (guarded
# on `command -v caddy`). Run on demand: `vz-ai-stack.sh test ingress`.
#
# AC-4: the Caddyfile is generated from aliases.tsv (via network.sh::aliases_load,
# NOT a second parser); two services sharing a native port produce two site
# blocks; NO site is emitted for a 127.0.0.1 alias (openwork/aionui excluded);
# appending an http row adds exactly one site; output is deterministic.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/ingress.sh"

hdr "Smoke ingress — Caddyfile generator (AC-4)"

fail=0
want()    { if grep -qF -- "$2" <<<"$1"; then ok "present: $2"; else err "MISSING: $2"; fail=1; fi; }
wantnot() { if grep -qF -- "$2" <<<"$1"; then err "UNEXPECTED: $2"; fail=1; else ok "absent:  $2"; fi; }

cfg="$(ingress_caddyfile_content)" || { err "generator returned non-zero"; exit 1; }

# AC-4a — litellm has both an http and an https site, proxying to its native port
want "$cfg" "http://litellm {"
want "$cfg" "https://litellm {"
want "$cfg" "reverse_proxy 127.0.10.1:4000"
want "$cfg" "tls internal"
want "$cfg" "bind 127.0.10.1"

# AC-4b — services sharing a native port are NOT deduped (one site block each)
want "$cfg" "http://falkordb-ui {"   # :3000 on 127.0.10.8
want "$cfg" "http://workspace {"     # :3000 on 127.0.10.10
want "$cfg" "http://honcho {"        # :8000 on 127.0.10.6
want "$cfg" "http://llm-guard {"     # :8000 on 127.0.10.12

# AC-4c — exclusions: 127.0.0.1 aliases + non-http protocols
wantnot "$cfg" "127.0.0.1"           # openwork/aionui must never appear
wantnot "$cfg" "http://openwork"
wantnot "$cfg" "http://aionui"
wantnot "$cfg" "http://falkordb {"   # redis (trailing brace distinguishes from falkordb-ui)
wantnot "$cfg" "http://phoenix-otlp"  # grpc

# AC-4 count — 13 qualifying http+127.0.10.x rows ⇒ 13 http:// site blocks
n_http=$(grep -c '^http://' <<<"$cfg" || true)
if [[ "$n_http" == "13" ]]; then ok "13 http sites"; else err "expected 13 http sites, got $n_http"; fail=1; fi

# AC-4e — deterministic / idempotent
a="$(ingress_caddyfile_content)"; b="$(ingress_caddyfile_content)"
if [[ "$a" == "$b" ]]; then ok "deterministic output"; else err "non-deterministic output"; fail=1; fi

# AC-4d — append a synthetic http row ⇒ exactly one new site
tmp="$(mktemp)"; cat "$AI_STACK/installer/lib/aliases.tsv" > "$tmp"
printf 'zztest\t127.0.10.99\thttp\t9999\t9999\t99\tzztest\n' >> "$tmp"
after=$(AI_STACK="$AI_STACK" AI_STACK_ALIASES_TSV="$tmp" bash -c \
  'source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/ingress.sh"; ingress_caddyfile_content' \
  | grep -c '^http://' || true)
rm -f "$tmp"
if [[ "$after" == "$((n_http+1))" ]]; then ok "append row -> +1 site ($n_http -> $after)"; else err "append: expected $((n_http+1)), got $after"; fail=1; fi

# --- Slice 2/3 — daemon plist diverges from one-shot; lo0-wait wrapper; idempotent writer ---
plist="$(ingress_plist_content)"
want "$plist" "<string>com.ai-stack.ingress</string>"
want "$plist" "<key>Crashed</key>"            # KeepAlive-on-crash (not a bare true, not the one-shot false)
want "$plist" "<key>ThrottleInterval</key>"
want "$plist" "<key>StandardOutPath</key>"
want "$plist" "<key>StandardErrorPath</key>"
want "$plist" "ingress-run.sh"                # ProgramArguments points at the wrapper
wantnot "$plist" "<false/>"                   # must NOT clone the loopback one-shot's KeepAlive=false

wrap="$(ingress_wrapper_content)"
want "$wrap" "ifconfig lo0"
want "$wrap" "127.0.10.1"
want "$wrap" "run --config"
want "$wrap" "Caddyfile.ai-stack"
if grep -q -- '-ge 120' <<<"$wrap"; then ok "wrapper: bounded lo0 wait"; else err "wrapper: unbounded wait"; fail=1; fi

wd="$(mktemp -d)"; dest="$wd/Caddyfile"
ingress_write_caddyfile "$dest" >/dev/null 2>&1 || { err "writer failed"; fail=1; }
if [[ -f "$dest" && "$(grep -c '^http://' "$dest")" == "13" ]]; then ok "writer: wrote 13 sites"; else err "writer: bad output"; fail=1; fi
w2="$(ingress_write_caddyfile "$dest" 2>&1)"
if grep -q "already current" <<<"$w2"; then ok "writer: idempotent (2nd run = no-op)"; else err "writer: not idempotent"; fail=1; fi
rm -rf "$wd"

echo
if [[ $fail -eq 0 ]]; then ok "ingress generator smoke PASSED"; exit 0; else err "ingress generator smoke FAILED"; exit 1; fi
