#!/usr/bin/env bash
# Hermetic smoke for the Model & Agent Console ONE-CLICK ROLLBACK (GET /api/backups +
# POST /api/restore in installer/lib/models_proxy.py). NO live stack, NO real docker:
# a stub `docker` is placed on PATH so the restore's `docker restart litellm` is a no-op.
# Everything runs against an ISOLATED sandbox MC_ROOT with a fabricated backup set.
# Pins the council-reviewed restore contract:
#   * GET /api/backups groups <basename>.<ts> files into restore sets (newest first).
#   * POST /api/restore WITHOUT confirm_restart -> 409 needs_confirm (fleet-restart gate).
#   * a bad / traversal 'ts' -> 400 (the _is_backup_ts guard).
#   * a cross-origin POST -> 403 (CSRF guard also covers the new route).
#   * --read-only -> 403 (restore is a write).
#   * WITH confirm_restart -> restores models.yml + config.yaml to live, snapshots the
#     CURRENT state first (reversible), and does NOT touch .env. Marker proves the swap.
# Run: bash installer/smoke/models-console-restore.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke — Model & Agent Console rollback (/api/backups + /api/restore, hermetic)"
pass=0; fail=0
yes_(){ pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_(){ fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
PROXY="$AI_STACK/installer/lib/models_proxy.py"
[[ -f "$PROXY" ]] || { no_ "models_proxy.py present"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable [skip]"; exit 0; }
command -v curl    >/dev/null 2>&1 || { echo "curl unavailable [skip]"; exit 0; }

TS=20260101-120000
tmp="$(mktemp -d)"
SBROOT="$tmp/root"
BK="$SBROOT/installer/state/model-console-backups"
mkdir -p "$BK" "$tmp"
# Live sandbox copies (what restore overwrites).
cp "$AI_STACK/installer/models.yml" "$tmp/models.yml"
cp "$AI_STACK/litellm/config.yaml"  "$tmp/config.yaml"
# Fabricated backup set carrying a recognizable marker so we can prove the swap happened.
sed 's/^default:.*/default: ROLLBACK-MARKER/' "$AI_STACK/installer/models.yml" > "$BK/models.yml.$TS"
cp "$AI_STACK/litellm/config.yaml" "$BK/config.yaml.$TS"

# Stub `docker` (via MC_DOCKER) so restore's `docker restart litellm` is a no-op AND we can
# PROVE the real daemon was never touched: the stub drops a sentinel when invoked.
stubdir="$tmp/stub"; mkdir -p "$stubdir"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$tmp/docker_called" > "$stubdir/docker"; chmod +x "$stubdir/docker"

PORT=8891; H='-H Host:127.0.0.1'
PROXY_PID=""
cleanup(){ [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

boot(){  # boot $1=readonly(0/1) ; MC_DOCKER stubs the litellm restart (never the real daemon)
  MODELS_YML="$tmp/models.yml" CONFIG="$tmp/config.yaml" \
  MC_PORT="$PORT" MC_LITELLM="http://127.0.0.1:1" MC_KEY_FILE="" MC_HTML="$AI_STACK/doc/MODELS.html" \
    MC_ROOT="$SBROOT" MC_MODELS_SH="$AI_STACK/installer/lib/models.sh" \
    MC_EMBED_SH="$AI_STACK/installer/lib/embeddings.sh" MC_START_LITELLM="$AI_STACK/bin/start-litellm.sh" \
    MC_MODELS_YML="$tmp/models.yml" MC_CONFIG="$tmp/config.yaml" MC_ENV_FILE="$tmp/.env" MC_READONLY="$1" \
    MC_DOCKER="$stubdir/docker" MC_RESTART_WAIT=0 \
    python3 "$PROXY" >"$tmp/proxy.log" 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 25); do curl -s $H -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}
stop(){ [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true; PROXY_PID=""; sleep 0.3; }

# ---- read/write instance ----
boot 0 && yes_ "proxy booted (read/write)" || { no_ "proxy did not boot"; cat "$tmp/proxy.log"; }

# 1. /api/backups lists the fabricated set.
curl -s $H "http://127.0.0.1:$PORT/api/backups" | python3 -c 'import sys,json
d=json.load(sys.stdin); b=d.get("backups",[])
assert any(x["ts"]=="'"$TS"'" and x["models"] and x["config"] for x in b), b
' 2>/dev/null && yes_ "/api/backups lists the restore set (models+config)" || no_ "/api/backups wrong"

# 2. restore WITHOUT confirm -> 409 needs_confirm.
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS"'"}' || true)"
[[ "$code" == "409" ]] && yes_ "restore without confirm -> 409 needs_confirm" || no_ "expected 409, got $code"

# 3. bad / traversal ts -> 400.
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"../../etc/x"}' || true)"
[[ "$code" == "400" ]] && yes_ "traversal ts -> 400 (validated)" || no_ "expected 400, got $code"

# 4. cross-origin POST -> 403 (CSRF guard covers the new route).
code="$(curl -s $H -H 'Origin: http://evil.example.com' -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS"'"}' || true)"
[[ "$code" == "403" ]] && yes_ "cross-origin restore -> 403 (CSRF guard)" || no_ "expected 403, got $code"

# 5. restore WITH confirm -> swaps files (marker present), backs up current state first, .env untouched.
before_env_exists=0; [[ -f "$tmp/.env" ]] && before_env_exists=1
curl -s $H -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS"'","confirm_restart":true}' | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert d.get("ok") is True, d
assert "models.yml" in d.get("restored",[]) and "config.yaml" in d.get("restored",[]), d
assert len(d.get("pre_restore_backup",[]))>=1, "current state not backed up before restore"
' 2>/dev/null && yes_ "restore+confirm -> ok, restored both files, pre-restore backup made" || no_ "restore+confirm failed: $(cat $tmp/proxy.log | tail -2)"
grep -q 'ROLLBACK-MARKER' "$tmp/models.yml" && yes_ "live models.yml now carries the restored marker (swap proven)" || no_ "restore did not swap models.yml"
[[ -f "$tmp/docker_called" ]] && yes_ "restore used the STUBBED docker (real daemon never touched)" || no_ "stub docker not invoked — restore may have hit the real daemon"
# .env must NOT have been created/restored by the operation (|| arm is no_, not a vacuous pass).
{ [[ "$before_env_exists" == "0" && ! -f "$tmp/.env" ]] || { [[ "$before_env_exists" == "1" ]] && [[ -f "$tmp/.env" ]]; }; } \
  && yes_ "restore did NOT create/clobber .env" || no_ ".env was touched by restore"

# 6. well-formed but NON-EXISTENT ts -> 404 (distinct from the 400 traversal case).
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"20200101-000000","confirm_restart":true}' || true)"
[[ "$code" == "404" ]] && yes_ "non-existent (valid-format) ts -> 404" || no_ "expected 404, got $code"

# 7. PARTIAL-COPY auto-revert: make the live config.yaml read-only so the config copy FAILS after
#    models.yml is written -> expect 500 + reverted:[models.yml] + live models.yml unchanged from
#    its pre-attempt content (no mismatched pair left on disk).
before_sha="$(shasum "$tmp/models.yml" | awk '{print $1}')"
chmod 0444 "$tmp/config.yaml"
curl -s $H -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS"'","confirm_restart":true}' > "$tmp/partial.json" 2>/dev/null || true
chmod 0644 "$tmp/config.yaml"
python3 -c 'import sys,json
d=json.load(open(sys.argv[1]))
assert d.get("ok") is False, d
assert "models.yml" in d.get("reverted",[]), ("models.yml not auto-reverted", d)
' "$tmp/partial.json" 2>/dev/null && yes_ "partial-copy failure -> 500 + models.yml auto-reverted" || no_ "partial-copy not handled: $(tail -c 300 $tmp/partial.json)"
after_sha="$(shasum "$tmp/models.yml" | awk '{print $1}')"
[[ "$before_sha" == "$after_sha" ]] && yes_ "live models.yml unchanged after the reverted partial restore (no mismatched pair)" || no_ "models.yml left in a partial state"

# 8. models-only restore point (config absent for that ts) -> restores models.yml only.
TS2=20200202-020202
cp "$AI_STACK/installer/models.yml" "$BK/models.yml.$TS2"   # NO config.yaml.$TS2
curl -s $H -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS2"'","confirm_restart":true}' | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert d.get("ok") is True, d
assert d.get("restored")==["models.yml"], ("should restore models.yml only", d)
' 2>/dev/null && yes_ "models-only restore point -> restores models.yml only (config optional)" || no_ "models-only restore failed"

# 9. SYMLINK backup entry -> rejected 400, never followed (adversarial F1: a planted
#    config.yaml.<ts> symlink to an outside file must not be copied over the live config).
TS3=20200303-030303
cp "$AI_STACK/installer/models.yml" "$BK/models.yml.$TS3"
ln -s /etc/hosts "$BK/config.yaml.$TS3"
cfg_before="$(shasum "$tmp/config.yaml" | awk '{print $1}')"
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS3"'","confirm_restart":true}' || true)"
cfg_after="$(shasum "$tmp/config.yaml" | awk '{print $1}')"
{ [[ "$code" == "400" ]] && [[ "$cfg_before" == "$cfg_after" ]]; } \
  && yes_ "symlink backup entry -> 400 (not followed; live config untouched)" || no_ "symlink not rejected (code=$code)"
stop

# ---- read-only instance: restore must refuse ----
boot 1 && {
  code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/restore" -d '{"ts":"'"$TS"'","confirm_restart":true}' || true)"
  [[ "$code" == "403" ]] && yes_ "--read-only -> restore 403 (no writes)" || no_ "read-only restore expected 403, got $code"
  stop
} || no_ "read-only proxy did not boot"

echo
if (( fail==0 )); then printf '✓ models-console-restore: %d checks passed\n' "$pass"; exit 0
else printf '✗ models-console-restore: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
