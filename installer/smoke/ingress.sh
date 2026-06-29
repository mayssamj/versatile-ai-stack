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

# Bypass the lo0 bind-guard for the STRUCTURAL assertions below so they're
# deterministic + machine-independent (they validate PURE generation, not whether
# prepare-sudo has bound the alias IPs on THIS host). The guard itself is exercised
# by the NEGATIVE test (M5) further down, which runs with this UNSET.
export INGRESS_TEST_NO_LO0_GUARD=1
aliases_load   # populate ALIASES_LIST/ALIAS_* in THIS shell (the $(...) calls run in subshells)

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
wantnot "$cfg" "bind 127.0.0.1"      # openwork/aionui (127.0.0.1 aliases) never get a site (loopback UPSTREAMs are fine)
wantnot "$cfg" "http://openwork"
wantnot "$cfg" "http://aionui"
wantnot "$cfg" "http://falkordb {"   # redis (trailing brace distinguishes from falkordb-ui)
wantnot "$cfg" "http://phoenix-otlp"  # grpc
# REGRESSION GUARD: the base aliases.tsv has NO http-loopback rows, so the standard `http`
# branch must NEVER emit a Host rewrite — catches a future edit that drops/inverts the
# `if [[ proto == http-loopback ]]` guard and silently rewrites Host on plain http rows.
wantnot "$cfg" "header_up"

# AC-4 count — DYNAMIC: #(in-scope http/http-loopback + 127.0.10.x rows) ⇒ that many
# http:// blocks. Derived from the generator's OWN scope filter (ingress_alias_in_scope)
# so it tracks aliases.tsv automatically and never re-arms the 13->17 drift bomb.
expected_sites=0
for _a in "${ALIASES_LIST[@]}"; do ingress_alias_in_scope "$_a" && expected_sites=$((expected_sites+1)); done
n_http=$(grep -c '^http://' <<<"$cfg" || true)
if [[ "$n_http" == "$expected_sites" ]]; then ok "$expected_sites http sites (dynamic count)"; else err "expected $expected_sites http sites, got $n_http"; fail=1; fi

# AC-4e — deterministic / idempotent
a="$(ingress_caddyfile_content)"; b="$(ingress_caddyfile_content)"
if [[ "$a" == "$b" ]]; then ok "deterministic output"; else err "non-deterministic output"; fail=1; fi

# AC-4d positive — append a synthetic http-loopback row ⇒ +1 site with the LOOPBACK shape
# (M4): binds the alias IP, proxies 127.0.0.1:PORT, rewrites Host on BOTH the http + https twins.
tmp="$(mktemp)"; cat "$AI_STACK/installer/lib/aliases.tsv" > "$tmp"
printf 'zzlb\t127.0.10.99\thttp-loopback\t9999\t9999\t99\tmanual\n' >> "$tmp"
lbcfg="$(AI_STACK="$AI_STACK" AI_STACK_ALIASES_TSV="$tmp" INGRESS_TEST_NO_LO0_GUARD=1 bash -c \
  'source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/ingress.sh"; ingress_caddyfile_content')"
rm -f "$tmp"
after=$(grep -c '^http://' <<<"$lbcfg" || true)
if [[ "$after" == "$((n_http+1))" ]]; then ok "append loopback row -> +1 site ($n_http -> $after)"; else err "append: expected $((n_http+1)), got $after"; fail=1; fi
want    "$lbcfg" "http://zzlb {"
want    "$lbcfg" "bind 127.0.10.99"                # binds the ALIAS IP (not 127.0.0.1)
want    "$lbcfg" "reverse_proxy 127.0.0.1:9999 {"  # upstream is loopback
want    "$lbcfg" "header_up Host 127.0.0.1:9999"   # Host rewrite (satisfies the upstream Host-pin)
wantnot "$lbcfg" "reverse_proxy 127.0.10.99:9999"  # must NOT proxy the alias IP
nhdr=$(grep -c 'header_up Host 127.0.0.1:9999' <<<"$lbcfg" || true)
if [[ "$nhdr" == "2" ]]; then ok "loopback: header_up on BOTH http+https twins"; else err "loopback: expected 2 header_up, got $nhdr"; fail=1; fi

# AC-4d NEGATIVE (M5) — the lo0 bind-guard: a row whose alias IP is NOT on lo0 is SKIPPED
# (no unbindable `bind` ⇒ no whole-daemon crash-loop), generation still exits 0, and warns on
# stderr. Runs with the test seam UNSET (empty) so the REAL guard fires; 127.0.10.99 is unbound.
tmp2="$(mktemp)"; cat "$AI_STACK/installer/lib/aliases.tsv" > "$tmp2"
printf 'zzskip\t127.0.10.99\thttp-loopback\t9998\t9998\t99\tmanual\n' >> "$tmp2"
neg_err="$(mktemp)"
neg_out="$(AI_STACK="$AI_STACK" AI_STACK_ALIASES_TSV="$tmp2" INGRESS_TEST_NO_LO0_GUARD= bash -c \
  'source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/ingress.sh"; ingress_caddyfile_content 2>"'"$neg_err"'"; echo "RC=$?"')"
neg_warn="$(cat "$neg_err" 2>/dev/null)"; rm -f "$tmp2" "$neg_err"
wantnot "$neg_out" "http://zzskip {"   # unbound-IP site must be skipped, not emitted
if grep -q 'RC=0' <<<"$neg_out"; then ok "negative: generator still exit 0 (no crash)"; else err "negative: generator non-zero exit"; fail=1; fi
if grep -qF 'not on lo0' <<<"$neg_warn"; then ok "negative: skip warned on stderr"; else err "negative: no lo0 warning on stderr"; fail=1; fi

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
if [[ -f "$dest" && "$(grep -c '^http://' "$dest")" == "$expected_sites" ]]; then ok "writer: wrote $expected_sites sites"; else err "writer: bad output"; fail=1; fi
w2="$(ingress_write_caddyfile "$dest" 2>&1)"
if grep -q "already current" <<<"$w2"; then ok "writer: idempotent (2nd run = no-op)"; else err "writer: not idempotent"; fail=1; fi
rm -rf "$wd"

# --- ingress add / remove / list / url round-trip (offline; isolated temp TSV) -----------
# Runs the CLI in a SUBSHELL with AI_STACK_ALIASES_TSV + INGRESS_CADDYFILE pointed at temps,
# so the tracked aliases.tsv is never touched. Guards are exercised via `&& fail || ok` so
# `set -e` never aborts on an intentionally-failing command.
sd="$(mktemp -d)"; stsv="$sd/aliases.tsv"
cat "$AI_STACK/installer/lib/aliases.tsv" > "$stsv"
ING() { AI_STACK_ALIASES_TSV="$stsv" INGRESS_CADDYFILE="$sd/Caddyfile" bash "$AI_STACK/installer/lib/ingress.sh" "$@"; }

if ING add zztest 12345 >/dev/null 2>&1; then ok "add: succeeded"; else err "add: failed"; fail=1; fi
# next-free IP must skip the commented .15 → .21 (current high-water is .20); http-loopback + manual key
if grep -qE "^zztest[[:space:]]+127\.0\.10\.21[[:space:]]+http-loopback[[:space:]]+12345[[:space:]]+12345[[:space:]]+manual" "$stsv"; then ok "add: row = .21 http-loopback (skips reserved .15)"; else err "add: row malformed"; grep zztest "$stsv" | sed 's/^/    /'; fail=1; fi
# list renders the name/ form; url renders http://name/ (port-free)
want "$(ING list 2>/dev/null)" "http://zztest/"
uout="$(AI_STACK_ALIASES_TSV="$stsv" bash "$AI_STACK/bin/url" zztest 2>/dev/null)"
if [[ "$uout" == "http://zztest/" ]]; then ok "url: zztest → http://zztest/"; else err "url: got '$uout'"; fail=1; fi
# url path-suffix must NOT double the slash (http://zztest/ + /v1 → http://zztest/v1)
upath="$(AI_STACK_ALIASES_TSV="$stsv" bash "$AI_STACK/bin/url" zztest /v1 2>/dev/null)"
if [[ "$upath" == "http://zztest/v1" ]]; then ok "url: path suffix no double-slash"; else err "url path: got '$upath'"; fail=1; fi
# guards — each MUST be rejected (non-zero), none may hang
ING add zztest 9 >/dev/null 2>&1 && { err "dup-name accepted"; fail=1; } || ok "guard: dup-name rejected"
ING add Bad_Name 80 >/dev/null 2>&1 && { err "invalid name accepted"; fail=1; } || ok "guard: invalid name rejected"
ING add okname 99999 >/dev/null 2>&1 && { err "bad port accepted"; fail=1; } || ok "guard: port>65535 rejected"
ING add okname 80 --ip 127.0.10.255 >/dev/null 2>&1 && { err ".255 accepted"; fail=1; } || ok "guard: --ip .255 rejected"
ING add okname 80 --ip >/dev/null 2>&1 && { err "--ip no-value accepted"; fail=1; } || ok "guard: --ip no-value rejected (no hang)"
ING remove litellm >/dev/null 2>&1 && { err "core alias removable"; fail=1; } || ok "guard: core alias remove refused"
# remove zztest → gone, TSV restored
if ING remove zztest >/dev/null 2>&1 && ! grep -q '^zztest' "$stsv"; then ok "remove: zztest removed"; else err "remove: zztest still present"; fail=1; fi
rm -rf "$sd"

echo
if [[ $fail -eq 0 ]]; then ok "ingress generator smoke PASSED"; exit 0; else err "ingress generator smoke FAILED"; exit 1; fi
