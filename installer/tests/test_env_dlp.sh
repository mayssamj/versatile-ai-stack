#!/usr/bin/env bash
# test_env_dlp.sh — offline test for CA-4: set_env must FAIL LOUD (not swallow) when the .env
# write is blocked, the way a Netwrix DLP quarantine would block a secret-bearing write. We
# simulate the block with an immutable target (chflags uchg) so mktemp succeeds but `mv` fails —
# exactly the awk/mv-failure branch the fix guards. NO network. Run: bash this.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; trap 'chflags nouchg "$TMP/.env" 2>/dev/null; rm -rf "$TMP"' EXIT

# Minimal stubs so env.sh::set_env runs hermetically (no common.sh / AI_STACK needed).
err(){ printf 'ERR: %s\n' "$*" >&2; }
warn(){ :; }; note(){ :; }
ENV_FILE="$TMP/.env"; export ENV_FILE
ensure_env_file(){ [[ -f "$ENV_FILE" ]] || : > "$ENV_FILE"; }
# Extract ONLY set_env's definition (env.sh has a top-level guard that would exit under set -u);
# it uses our err/ensure_env_file/ENV_FILE stubs above.
eval "$(sed -n '/^set_env()/,/^}/p' "$HERE/../lib/env.sh")"
declare -F set_env >/dev/null || { echo "  FAIL could not load set_env"; exit 1; }

PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== set_env normal path =="
: > "$ENV_FILE"; echo "EXISTING=1" >> "$ENV_FILE"
set_env NEWKEY hello >/dev/null 2>&1
{ (( $? == 0 )) && grep -qx 'NEWKEY=hello' "$ENV_FILE"; } && ok "normal set_env persists the key" || bad "normal set_env failed"

echo "== CA-4: a BLOCKED write fails LOUD, doesn't swallow =="
if chflags uchg "$ENV_FILE" 2>/dev/null; then
  out="$(set_env BLOCKED nope 2>&1)"; rc=$?
  chflags nouchg "$ENV_FILE" 2>/dev/null
  { (( rc != 0 )) && grep -qiE 'FAILED to persist|DLP' <<<"$out"; } \
    && ok "blocked write -> rc!=0 + loud (names the file + DLP), value NOT swallowed" \
    || bad "blocked write swallowed or quiet: rc=$rc out='$out'"
  grep -qx 'BLOCKED=nope' "$ENV_FILE" && bad "the blocked value leaked into .env" || ok "the blocked value did NOT land in .env"
  # the central CA-4 claim: the LOUD error must NEVER contain the secret value
  grep -q 'nope' <<<"$out" && bad "secret value LEAKED into the loud error message" || ok "loud error omits the secret value (DLP hygiene)"
  ls "$ENV_FILE".* >/dev/null 2>&1 && bad "a 0600 temp .env.XXXXXX was stranded (secret-on-disk)" || ok "no stranded temp after the blocked write"
else
  echo "  [skip] chflags uchg unavailable on this fs — can't simulate the block"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
