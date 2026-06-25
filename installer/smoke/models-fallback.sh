#!/usr/bin/env bash
# Hermetic smoke for the FALLBACK EDITOR (model fallback CLI + POST /api/fallback).
# NO live stack, NO real docker: the CLI edits a SANDBOX config.yaml; the proxy tier stubs
# `docker` via MC_DOCKER (sentinel proves the real daemon is never touched) + MC_RESTART_WAIT=0.
# Pins the §24-reviewed contract:
#   CLI: comment-preserving line-surgical set/replace/insert + remove; substring-safety;
#        local-tier metered guard (+ --allow-non-local); self-ref/unknown refusal; round-trip
#        validation (parse + count + duplicate-key); CRLF/duplicate/block-style aborts; dry-run.
#   Proxy: 409 needs_confirm gate; 400 bad-arg; 403 cross-origin (CSRF) + read-only; argv-smuggle
#        400; confirm -> 200 (stub docker, sentinel); pre-edit backup; /api/state reflects the edit.
# Run: bash installer/smoke/models-fallback.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke — Fallback editor (model fallback CLI + /api/fallback, hermetic)"
pass=0; fail=0
yes_(){ pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_(){ fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
MS="$AI_STACK/installer/lib/models.sh"
PROXY="$AI_STACK/installer/lib/models_proxy.py"
command -v yq   >/dev/null 2>&1 || { echo "yq unavailable [skip]"; exit 0; }
command -v awk  >/dev/null 2>&1 || { echo "awk unavailable [skip]"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; [[ -n "${PROXY_PID:-}" ]] && kill "$PROXY_PID" 2>/dev/null || true' EXIT INT TERM
SB="$tmp/config.yaml"; cp "$AI_STACK/litellm/config.yaml" "$SB"
ORIG="$tmp/config.orig.yaml"; cp "$SB" "$ORIG"
# tgt helpers operate on whichever CONFIG is exported
tgt(){ MN="$1" yq -r '[.litellm_settings.fallbacks // [] | .[] | select(has(strenv(MN)))][0][strenv(MN)] // [] | join(",")' "$2"; }
cnt(){ MN="$1" yq -r '[.litellm_settings.fallbacks // [] | .[] | select(has(strenv(MN)))] | length' "$2"; }
comments(){ grep '^[[:space:]]*#' "$1" || true; }
run(){ CONFIG="$SB" LOCK_FORCE=1 bash "$MS" fallback "$@"; }
rc_of(){ local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }

echo "── CLI tier (sandbox config, no docker) ──"
bash -n "$MS" && yes_ "models.sh syntax OK" || no_ "models.sh syntax error"

# C1 list --json valid
run list --json | python3 -c 'import sys,json; d=json.load(sys.stdin); assert isinstance(d,list) and d' \
  && yes_ "C1 list --json returns a non-empty JSON array" || no_ "C1 list --json invalid"

# C2 set replace -> entry updated
run set claude-opus-sub-max local-gemma4 >/dev/null 2>&1
[[ "$(tgt claude-opus-sub-max "$SB")" == "local-gemma4" ]] && yes_ "C2 set replace updates the chain" || no_ "C2 set failed"

# C3 comments preserved byte-for-byte (content+order; line numbers may shift on insert)
diff <(comments "$ORIG") <(comments "$SB") >/dev/null && yes_ "C3 all comment lines preserved byte-for-byte" || no_ "C3 comments mutated"

# C4 unknown model -> exit 2
[[ "$(rc_of run set no-such-model local-qwen3)" == "2" ]] && yes_ "C4 unknown model -> exit 2" || no_ "C4 wrong rc"

# C5 non-local (metered/sub) target without --allow-non-local -> exit 2
[[ "$(rc_of run set sakana-fugu claude-opus-sub-high)" == "2" ]] && yes_ "C5 non-local target refused (no flag) -> exit 2" || no_ "C5 wrong rc"

# C5b non-local allowed WITH --allow-non-local
run set sakana-fugu claude-opus-sub-high --allow-non-local >/dev/null 2>&1
[[ "$(tgt sakana-fugu "$SB")" == "claude-opus-sub-high" ]] && yes_ "C5b --allow-non-local permits a non-local target" || no_ "C5b override failed"

# C6 self-reference -> exit 2
[[ "$(rc_of run set openai-gpt openai-gpt)" == "2" ]] && yes_ "C6 self-reference -> exit 2" || no_ "C6 wrong rc"

# C7 remove -> gone + comments still preserved
run remove sakana-fugu >/dev/null 2>&1
[[ "$(cnt sakana-fugu "$SB")" == "0" ]] && yes_ "C7 remove deletes the entry" || no_ "C7 remove failed"
diff <(comments "$ORIG") <(comments "$SB") >/dev/null && yes_ "C7b comments preserved after remove" || no_ "C7b comments mutated on remove"

# C8 remove non-existent -> graceful exit 0
[[ "$(rc_of run remove no-such-model)" == "0" ]] && yes_ "C8 remove non-existent -> graceful exit 0" || no_ "C8 wrong rc"

# C9 substring safety: set openai-gpt; openai-gpt-pro/-sub untouched
run set openai-gpt local-qwen3 >/dev/null 2>&1
{ [[ "$(cnt openai-gpt-pro "$SB")" == "1" ]] && [[ "$(cnt openai-gpt-sub "$SB")" == "1" ]] && [[ "$(cnt openai-gpt-pro-sub "$SB")" == "1" ]]; } \
  && yes_ "C9 substring-named siblings untouched by set openai-gpt" || no_ "C9 substring collision"

# C10 multi-target set
run set sakana-fugu-ultra local-qwen3 local-gemma4 >/dev/null 2>&1
[[ "$(tgt sakana-fugu-ultra "$SB")" == "local-qwen3,local-gemma4" ]] && yes_ "C10 multi-target chain set" || no_ "C10 multi-target failed"

# C11 dry-run does not mutate
sha0=$(shasum "$SB" | awk '{print $1}')
run set openai-gpt-pro local-gemma4 --dry-run >/dev/null 2>&1
[[ "$sha0" == "$(shasum "$SB" | awk '{print $1}')" ]] && yes_ "C11 dry-run leaves config.yaml byte-identical" || no_ "C11 dry-run mutated"

# C12 still parses
yq -e '.' "$SB" >/dev/null 2>&1 && yes_ "C12 edited config.yaml still parses" || no_ "C12 parse fail"

# C13 CRLF in the fallbacks block -> exit 2 (no silent whole-file rewrite)
crlf="$tmp/crlf.yaml"; awk '{sub(/\r$/,""); printf "%s\r\n",$0}' "$ORIG" > "$crlf"
[[ "$(rc_of env CONFIG="$crlf" LOCK_FORCE=1 bash "$MS" fallback set openai-gpt local-qwen3)" == "2" ]] \
  && yes_ "C13 CRLF fallbacks block -> exit 2" || no_ "C13 CRLF not refused"

# C14 DUPLICATE entry -> abort exit 2 (don't guess which line)
dup="$tmp/dup.yaml"; awk '/^    - sakana-fugu: /{print; print; next} {print}' "$ORIG" > "$dup"
[[ "$(rc_of env CONFIG="$dup" LOCK_FORCE=1 bash "$MS" fallback set sakana-fugu local-gemma4)" == "2" ]] \
  && yes_ "C14 duplicate entry -> abort exit 2" || no_ "C14 duplicate not aborted"

# C15 fallbacks key ABSENT -> set aborts with guidance (exit 2; never a risky yq -i on the live file)
absent="$tmp/absent.yaml"; cp "$ORIG" "$absent"; yq -i 'del(.litellm_settings.fallbacks)' "$absent"
[[ "$(rc_of env CONFIG="$absent" LOCK_FORCE=1 bash "$MS" fallback set openai-gpt local-qwen3)" == "2" ]] \
  && yes_ "C15 absent fallbacks key -> safe abort exit 2" || no_ "C15 absent-key not handled"

# C16 bare-empty 'fallbacks:' (the post-remove-all state) -> set CREATES the first entry
bare="$tmp/bare.yaml"
cat > "$bare" <<'YAML'
model_list:
  - model_name: local-gemma4
    litellm_params: {model: ollama/gemma}
  - model_name: local-qwen3
    litellm_params: {model: ollama/qwen}
litellm_settings:
  drop_params: true
  fallbacks:
guardrails: []
YAML
CONFIG="$bare" LOCK_FORCE=1 bash "$MS" fallback set local-gemma4 local-qwen3 >/dev/null 2>&1
[[ "$(tgt local-gemma4 "$bare")" == "local-qwen3" ]] && yes_ "C16 bare-empty fallbacks: -> first entry created" || no_ "C16 bare-empty create failed"

# C17 write into a read-only location fails SAFE: non-zero exit + CONFIG byte-identical (no partial write)
mkdir -p "$tmp/ro"; roc="$tmp/ro/config.yaml"; cp "$ORIG" "$roc"; ro_sha="$(shasum "$roc"|awk '{print $1}')"; chmod 555 "$tmp/ro"
rc=0; CONFIG="$roc" LOCK_FORCE=1 bash "$MS" fallback set openai-gpt local-qwen3 >/dev/null 2>&1 || rc=$?
chmod 755 "$tmp/ro"
{ [[ "$rc" != "0" ]] && [[ "$ro_sha" == "$(shasum "$roc"|awk '{print $1}')" ]]; } \
  && yes_ "C17 write to read-only dir fails safe (non-zero exit, config byte-identical)" || no_ "C17 unsafe on write failure (rc=$rc)"

echo "── proxy tier (stub docker, MC_RESTART_WAIT=0) ──"
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "python3/curl unavailable — proxy tier [skip]"
else
  cp "$ORIG" "$SB"   # fresh sandbox for the proxy tier
  cp "$AI_STACK/installer/models.yml" "$tmp/models.yml"
  SBROOT="$tmp/root"; BK="$SBROOT/installer/state/model-console-backups"; mkdir -p "$BK"
  stubdir="$tmp/stub"; mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$tmp/docker_called" > "$stubdir/docker"; chmod +x "$stubdir/docker"
  PORT=8893; H='-H Host:127.0.0.1'; PROXY_PID=""
  boot(){  # $1 = readonly(0/1)
    MODELS_YML="$tmp/models.yml" CONFIG="$SB" LOCK_FORCE=1 \
    MC_PORT="$PORT" MC_LITELLM="${BOOT_LITELLM:-http://127.0.0.1:1}" MC_KEY_FILE="" MC_HTML="$AI_STACK/doc/MODELS.html" \
      MC_ROOT="$SBROOT" MC_MODELS_SH="$MS" MC_EMBED_SH="$AI_STACK/installer/lib/embeddings.sh" \
      MC_START_LITELLM="$AI_STACK/bin/start-litellm.sh" MC_MODELS_YML="$tmp/models.yml" MC_CONFIG="$SB" \
      MC_ENV_FILE="$tmp/.env" MC_READONLY="$1" MC_DOCKER="$stubdir/docker" MC_RESTART_WAIT="${BOOT_WAIT:-0}" \
      python3 "$PROXY" >"$tmp/proxy.log" 2>&1 &
    PROXY_PID=$!
    for _ in $(seq 1 25); do curl -s $H -o /dev/null "http://127.0.0.1:$PORT/api/health" 2>/dev/null && return 0; sleep 0.2; done
    return 1
  }
  stop(){ [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true; PROXY_PID=""; sleep 0.3; }

  boot 0 && yes_ "P0 proxy booted (read/write)" || { no_ "P0 proxy did not boot"; cat "$tmp/proxy.log"; }

  # P1 no confirm -> 409 needs_confirm
  code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"sakana-fugu","targets":["local-gemma4"]}' || true)"
  [[ "$code" == "409" ]] && yes_ "P1 no confirm -> 409 needs_confirm" || no_ "P1 expected 409, got $code"

  # P2 bad model (not in model_list) -> 400
  code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"no-such","targets":["local-qwen3"],"confirm_restart":true}' || true)"
  [[ "$code" == "400" ]] && yes_ "P2 unknown model -> 400" || no_ "P2 expected 400, got $code"

  # P3 cross-origin -> 403 (CSRF)
  code="$(curl -s $H -H 'Origin: http://evil.example.com' -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"sakana-fugu","targets":["local-gemma4"]}' || true)"
  [[ "$code" == "403" ]] && yes_ "P3 cross-origin -> 403 (CSRF)" || no_ "P3 expected 403, got $code"

  # P4 argv-smuggle: model starts with '-' -> 400 (_posarg guard)
  code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"--dry-run","targets":["local-qwen3"],"confirm_restart":true}' || true)"
  [[ "$code" == "400" ]] && yes_ "P4 argv-smuggle model='--dry-run' -> 400" || no_ "P4 expected 400, got $code"

  # P5 confirm set -> 200, stub docker called, sandbox config edited, pre-edit backup made
  curl -s $H -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"sakana-fugu","targets":["local-gemma4"],"confirm_restart":true}' | python3 -c 'import sys,json
d=json.load(sys.stdin); assert d.get("ok") is True, d; assert d.get("op")=="set" and d.get("model")=="sakana-fugu", d' \
    2>/dev/null && yes_ "P5 confirm set -> 200 ok" || no_ "P5 set failed: $(tail -2 "$tmp/proxy.log")"
  [[ "$(tgt sakana-fugu "$SB")" == "local-gemma4" ]] && yes_ "P5b live (sandbox) config.yaml carries the edit" || no_ "P5b edit not applied"
  [[ -f "$tmp/docker_called" ]] && yes_ "P5c restart used the STUBBED docker (real daemon untouched)" || no_ "P5c stub docker not invoked"
  ls "$BK"/config.yaml.* >/dev/null 2>&1 && yes_ "P5d pre-edit config.yaml backup written to backup dir" || no_ "P5d no pre-edit backup"

  # P6 GET /api/state reflects the edit
  curl -s $H "http://127.0.0.1:$PORT/api/state" | python3 -c 'import sys,json
d=json.load(sys.stdin); fb=d.get("fallbacks",[])
assert any(isinstance(e,dict) and e.get("sakana-fugu")==["local-gemma4"] for e in fb), fb' \
    2>/dev/null && yes_ "P6 /api/state reflects the new chain" || no_ "P6 state stale"

  # P7 op=remove confirm -> 200 + entry gone
  curl -s $H -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"remove","model":"sakana-fugu","confirm_restart":true}' | python3 -c 'import sys,json
d=json.load(sys.stdin); assert d.get("ok") is True, d' 2>/dev/null \
    && [[ "$(cnt sakana-fugu "$SB")" == "0" ]] && yes_ "P7 remove -> 200 + entry gone" || no_ "P7 remove failed"
  stop

  # P8 read-only -> 403
  boot 1 && : || { no_ "P8 proxy (read-only) did not boot"; }
  code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"openai-gpt","targets":["local-qwen3"],"confirm_restart":true}' || true)"
  [[ "$code" == "403" ]] && yes_ "P8 read-only mode -> 403" || no_ "P8 expected 403, got $code"
  stop

  # P9 chain_verified=true coverage: a stub /health/readiness (200) + MC_RESTART_WAIT>0 so
  # _litellm_ready returns True and the proxy re-reads config to confirm the edit is live.
  HPORT=8897
  python3 - "$HPORT" <<'PY' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  HEALTH_PID=$!
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$HPORT/health/readiness" 2>/dev/null && break; sleep 0.2; done
  cp "$ORIG" "$SB"
  BOOT_WAIT=3 BOOT_LITELLM="http://127.0.0.1:$HPORT" boot 0 && : || no_ "P9 proxy (with wait) did not boot"
  curl -s $H -X POST "http://127.0.0.1:$PORT/api/fallback" -d '{"fb_op":"set","model":"openai-gpt","targets":["local-gemma4"],"confirm_restart":true}' | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert d.get("ok") is True, d
assert d.get("ready") is True, ("ready should be True", d)
assert d.get("chain_verified") is True, ("chain_verified should be True", d)' \
    2>/dev/null && yes_ "P9 chain_verified=true after a ready restart (stub /health)" || no_ "P9 chain_verified path failed: $(tail -2 "$tmp/proxy.log")"
  stop
  kill "$HEALTH_PID" 2>/dev/null || true
fi

echo
hdr "Fallback smoke: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
