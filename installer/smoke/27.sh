#!/usr/bin/env bash
# smoke/27.sh — phase 27 (Sourcegraph) E2E: a REAL code search through the fleet
# MCP path. This is the deep proof doctor-49 deliberately does NOT do (doctor =
# fast health; smoke = real round-trip). It mirrors the install-time AC-1 proof:
# initialize the SG MCP server from INSIDE the hermes-fleet-v1 sandbox and run a
# keyword_search, asserting >=1 match from the indexed repo. NEVER uses
# `hermes mcp test` (verified buggy vs SG — bad Accept → 400).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 27 — Sourcegraph fleet MCP (real keyword_search)"

TOKEN_FILE="$HOME/.sourcegraph-local/sg-token"
[[ -s "$TOKEN_FILE" ]] || { err "no SG token at $TOKEN_FILE — run: vz-ai-stack.sh install sourcegraph"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx sourcegraph || { err "sourcegraph container not running — vz-ai-stack.sh start sourcegraph"; exit 1; }

_osh() { if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell; else command -v openshell || echo ""; fi; }
OSH="$(_osh)"; [[ -n "$OSH" ]] || { err "openshell CLI not found"; exit 1; }

# 1. Host-side SG MCP liveness + token validity.
log "SG MCP initialize (host, token auth)…"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST http://localhost:7080/.api/mcp \
  -H "Authorization: token $(cat "$TOKEN_FILE")" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')"
[[ "$code" == "200" ]] || { err "SG MCP initialize returned HTTP $code (expected 200)"; exit 1; }
ok "SG MCP alive + token valid (HTTP 200)"

# 2. Sandbox must be Ready.
"$OSH" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
  | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}' \
  || { err "hermes-fleet-v1 sandbox not Ready — vz-ai-stack.sh install 04"; exit 1; }

# 3. REAL keyword_search from INSIDE the sandbox (the fleet path), asserting a hit.
probe="$(mktemp /tmp/sg-smoke-XXXX.py)"; trap 'rm -f "$probe"' EXIT
cat > "$probe" <<'PY'
import asyncio, os, sys, re
TOKEN=(os.environ.get("SG_TOKEN") or sys.stdin.readline()).strip()
URL="http://host.docker.internal:7080/.api/mcp"
async def main():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client
    async with streamablehttp_client(URL, headers={"Authorization": f"token {TOKEN}"}) as (r,w,_):
        async with ClientSession(r,w) as s:
            await s.initialize()
            tools=await s.list_tools()
            res=await s.call_tool("keyword_search", {"query":"repo:versatile-ai-stack LiteLLM"})
            txt="".join(getattr(c,"text","") for c in res.content)
            files=re.findall(r'"file":"([^"]+)"', txt)
            print(f"TOOLS={len(tools.tools)} MATCHES={len(files)}")
            return len(tools.tools) >= 1 and len(files) >= 1
# Exit OUTSIDE the async context so a SystemExit never propagates through the MCP
# client's anyio task group (which would print a spurious traceback on success).
sys.exit(0 if asyncio.run(main()) else 3)
PY
"$OSH" sandbox upload --no-git-ignore hermes-fleet-v1 "$probe" /sandbox/ >/dev/null 2>&1 \
  || { err "could not upload smoke probe to sandbox"; exit 1; }
pname="$(basename "$probe")"
log "running real keyword_search from inside hermes-fleet-v1…"
# NB: `|| true` — under `set -Eeuo pipefail` a non-zero probe exit (the no-match
# `else 3` path, or a transient relay error) would otherwise abort here BEFORE the
# grep check below, hiding the diagnostic. We want the check to run regardless.
out="$(printf '%s\n' "$(cat "$TOKEN_FILE")" | "$OSH" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 60 -- python3 "/sandbox/$pname" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')" || true
"$OSH" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- rm -f "/sandbox/$pname" >/dev/null 2>&1 || true
echo "  $out"
if grep -qE 'TOOLS=1[0-9] MATCHES=[1-9]' <<<"$out"; then
  ok "Smoke 27 PASS — fleet reached SG MCP and keyword_search returned matches"
else
  err "Smoke 27 FAIL — expected >=12 tools and >=1 match; got: $out"
  err "(If 'policy_denied': re-apply the sourcegraph_mcp policy — vz-ai-stack.sh install 04)"
  exit 1
fi
