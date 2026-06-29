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
# Pin the STRUCTURAL assertions to NO local overrides (/dev/null), so they're hermetic even
# on a host that has a real installer/lib/aliases.local.tsv (otherwise its http-loopback rows
# would, e.g., make `wantnot header_up` below go RED). The local-FILE tests further down
# override this with their own temp file.
export AI_STACK_ALIASES_LOCAL_TSV=/dev/null
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

# --- ingress add / remove / list / url round-trip — LOCAL-file model (offline; temps) ----
# CLI runs in a SUBSHELL with the tracked AI_STACK_ALIASES_TSV, the personal
# AI_STACK_ALIASES_LOCAL_TSV, and INGRESS_CADDYFILE all pointed at temps — real files
# untouched. Guards use `&& fail || ok` so `set -e` never aborts on an expected failure.
sd="$(mktemp -d)"; stsv="$sd/aliases.tsv"; slocal="$sd/aliases.local.tsv"
cat "$AI_STACK/installer/lib/aliases.tsv" > "$stsv"
ING()  { AI_STACK_ALIASES_TSV="$stsv" AI_STACK_ALIASES_LOCAL_TSV="$slocal" INGRESS_CADDYFILE="$sd/Caddyfile" bash "$AI_STACK/installer/lib/ingress.sh" "$@"; }
URLC() { AI_STACK_ALIASES_TSV="$stsv" AI_STACK_ALIASES_LOCAL_TSV="$slocal" bash "$AI_STACK/bin/url" "$@"; }
stsv_before="$(cat "$stsv")"

if ING add zztest 12345 >/dev/null 2>&1; then ok "add: succeeded"; else err "add: failed"; fail=1; fi
# the row lands in the LOCAL file (.21 — skips reserved .15), with the http-loopback/manual shape
if grep -qE "^zztest[[:space:]]+127\.0\.10\.21[[:space:]]+http-loopback[[:space:]]+12345[[:space:]]+12345[[:space:]]+manual" "$slocal"; then ok "add: row → LOCAL file (.21 http-loopback, skips .15)"; else err "add: local row malformed"; cat "$slocal" 2>/dev/null | sed 's/^/    /'; fail=1; fi
# the TRACKED file is byte-for-byte UNTOUCHED — personal hostnames never dirty the public repo
if [[ "$(cat "$stsv")" == "$stsv_before" ]]; then ok "add: tracked aliases.tsv UNTOUCHED"; else err "add: tracked file was modified!"; fail=1; fi
# aliases_load MERGES the local row → list + url + generator all see it
want "$(ING list 2>/dev/null)" "http://zztest/"
# the GENERATOR (the path that actually builds Caddy sites) emits the LOCAL row, right shape
genout="$(AI_STACK="$AI_STACK" AI_STACK_ALIASES_TSV="$stsv" AI_STACK_ALIASES_LOCAL_TSV="$slocal" INGRESS_TEST_NO_LO0_GUARD=1 bash -c 'source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/ingress.sh"; ingress_caddyfile_content' 2>/dev/null)"
want    "$genout" "http://zztest {"                  # local row produces a site
want    "$genout" "bind 127.0.10.21"                 # binds its alias IP
want    "$genout" "reverse_proxy 127.0.0.1:12345 {"  # upstream is loopback
want    "$genout" "header_up Host 127.0.0.1:12345"   # Host rewrite present
wantnot "$genout" "reverse_proxy 127.0.10.21:12345"  # must NOT proxy the alias IP
uout="$(URLC zztest 2>/dev/null)"
if [[ "$uout" == "http://zztest/" ]]; then ok "url: zztest (local) → http://zztest/"; else err "url: got '$uout'"; fail=1; fi
upath="$(URLC zztest /v1 2>/dev/null)"
if [[ "$upath" == "http://zztest/v1" ]]; then ok "url: path suffix no double-slash"; else err "url path: got '$upath'"; fail=1; fi
# guards — each MUST be rejected (non-zero), none may hang
ING add zztest 9 >/dev/null 2>&1 && { err "dup-name accepted"; fail=1; } || ok "guard: dup-name rejected (merged check)"
ING add Bad_Name 80 >/dev/null 2>&1 && { err "invalid name accepted"; fail=1; } || ok "guard: invalid name rejected"
ING add okname 99999 >/dev/null 2>&1 && { err "bad port accepted"; fail=1; } || ok "guard: port>65535 rejected"
ING add okname 80 --ip 127.0.10.255 >/dev/null 2>&1 && { err ".255 accepted"; fail=1; } || ok "guard: --ip .255 rejected"
ING add okname 80 --ip >/dev/null 2>&1 && { err "--ip no-value accepted"; fail=1; } || ok "guard: --ip no-value rejected (no hang)"
ING add okname 80 --ip 127.0.10.1 >/dev/null 2>&1 && { err "tracked IP .1 reused"; fail=1; } || ok "guard: --ip collision across BOTH files rejected"
ING remove litellm >/dev/null 2>&1 && { err "core alias removable"; fail=1; } || ok "guard: core (tracked) alias remove refused"
# remove zztest → gone from the LOCAL file
if ING remove zztest >/dev/null 2>&1 && ! grep -q '^zztest' "$slocal"; then ok "remove: zztest removed from local file"; else err "remove: zztest still present"; fail=1; fi

# local-WINS override + dedup: a local row reusing a tracked name (litellm) repoints its
# fields, and litellm must still appear EXACTLY ONCE in ALIASES_LIST (no double-count).
printf 'litellm\t127.0.10.99\thttp-loopback\t4000\t4000\tmanual\tlitellm\n' > "$slocal"
ovr="$(AI_STACK="$AI_STACK" AI_STACK_ALIASES_TSV="$stsv" AI_STACK_ALIASES_LOCAL_TSV="$slocal" bash -c '
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/network.sh"
  aliases_load
  n=0; for a in "${ALIASES_LIST[@]}"; do [[ "$a" == litellm ]] && n=$((n+1)); done
  echo "${ALIAS_IP[litellm]}|${ALIAS_PROTOCOL[litellm]}|$n"')"
if [[ "$ovr" == "127.0.10.99|http-loopback|1" ]]; then ok "merge: local row OVERRIDES tracked (litellm→.99) + dedup (once)"; else err "merge override: got '$ovr' (want 127.0.10.99|http-loopback|1)"; fail=1; fi
# bin/url's OWN two-file awk must honor the override too (litellm now renders port-free)
ovr_url="$(URLC litellm 2>/dev/null)"
if [[ "$ovr_url" == "http://litellm/" ]]; then ok "merge: bin/url honors local override (litellm → http://litellm/)"; else err "url override: got '$ovr_url' (want http://litellm/)"; fail=1; fi
rm -rf "$sd"

echo
if [[ $fail -eq 0 ]]; then ok "ingress generator smoke PASSED"; exit 0; else err "ingress generator smoke FAILED"; exit 1; fi
