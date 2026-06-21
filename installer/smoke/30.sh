#!/usr/bin/env bash
# smoke/30.sh — phase 30 (Understand-Anything) E2E: a REAL graph_search through the
# FLEET MCP path. This is the credibility artifact for "usable in Hermes" — it proves
# a hermes-fleet-v1 profile can query the committed ai-stack knowledge graph over HTTP
# MCP and get a recognizable node back (not "wired, trust me"). Mirrors smoke/27.sh.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 30 — Understand-Anything fleet MCP (real graph_search)"

PORT="$(get_env UNDERSTAND_MCP_PORT '7081')"
TOKEN="$(get_env UNDERSTAND_MCP_TOKEN '')"
[[ -n "$TOKEN" ]] || { err "UNDERSTAND_MCP_TOKEN absent from .env — run: vz-ai-stack.sh install understand"; exit 1; }
[[ -f "$AI_STACK/.understand-anything/knowledge-graph.json" ]] || { err "no committed graph — run '/understand .' from $AI_STACK and commit it"; exit 1; }

# 1. Ensure the host http daemon is up (start idempotently).
if ! curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/healthz" 2>/dev/null | grep -q '^200$'; then
  log "understand-mcp not up — starting…"
  bash "$AI_STACK/bin/start-understand.sh" >/dev/null 2>&1 || true
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST "http://localhost:$PORT/mcp" \
  -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')"
[[ "$code" == "200" ]] || { err "understand-mcp initialize returned HTTP $code (expected 200) — check $STATE_DIR/understand-mcp.log"; exit 1; }
ok "understand-mcp alive + token valid (HTTP 200)"

_osh() { if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell; else command -v openshell || echo ""; fi; }
OSH="$(_osh)"; [[ -n "$OSH" ]] || { err "openshell CLI not found"; exit 1; }

# 2. Sandbox Ready.
"$OSH" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
  | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}' \
  || { err "hermes-fleet-v1 sandbox not Ready — vz-ai-stack.sh install 04"; exit 1; }

# 3. REAL graph_search from INSIDE the sandbox, asserting a recognizable node.
probe="$(mktemp /tmp/und-smoke-XXXX.py)"; trap 'rm -f "$probe"' EXIT
cat > "$probe" <<PY
import asyncio, os, sys, re
TOKEN=(os.environ.get("UND_TOKEN") or sys.stdin.readline()).strip()
URL="http://host.docker.internal:${PORT}/mcp"
async def main():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client
    async with streamablehttp_client(URL, headers={"Authorization": f"token {TOKEN}"}) as (r,w,_):
        async with ClientSession(r,w) as s:
            await s.initialize()
            tools=await s.list_tools()
            res=await s.call_tool("graph_search", {"query":"litellm","limit":5})
            txt="".join(getattr(c,"text","") for c in res.content)
            ids=re.findall(r'"id":\s*"([^"]+)"', txt)
            print(f"TOOLS={len(tools.tools)} MATCHES={len(ids)}")
            return len(tools.tools) >= 1 and len(ids) >= 1
sys.exit(0 if asyncio.run(main()) else 3)
PY
"$OSH" sandbox upload --no-git-ignore hermes-fleet-v1 "$probe" /sandbox/ >/dev/null 2>&1 \
  || { err "could not upload smoke probe to sandbox"; exit 1; }
pname="$(basename "$probe")"
log "running real graph_search from inside hermes-fleet-v1…"
out="$(printf '%s\n' "$TOKEN" | "$OSH" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 60 -- python3 "/sandbox/$pname" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')" || true
"$OSH" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- rm -f "/sandbox/$pname" >/dev/null 2>&1 || true
echo "  $out"
if grep -qE 'TOOLS=[1-9][0-9]* MATCHES=[1-9]' <<<"$out"; then
  ok "Smoke 30 PASS — fleet reached understand-mcp and graph_search returned graph nodes"
else
  err "Smoke 30 FAIL — expected >=1 tool and >=1 match; got: $out"
  err "(If a connection error: ensure 'vz-ai-stack.sh start understand' and the fleet wiring — vz-ai-stack.sh install understand)"
  exit 1
fi
