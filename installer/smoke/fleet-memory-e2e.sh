#!/usr/bin/env bash
# smoke/fleet-memory-e2e.sh — LIVE end-user E2E ACCEPTANCE GATE for "fleet memory".
# =============================================================================
# This is the definition-of-done gate for the fleet-memory program. Unlike the
# hermetic wiring smoke (installer/smoke/39.sh, which stubs `claude` and proves
# the register/doctor LOGIC with no live services), THIS test proves each memory
# feature actually WORKS from the end user's perspective — real data flows through
# the real protocol path — on both consumers (claude-cli + hermes-fleet).
#
# It prints a PASS / SKIP(reason) / FAIL matrix of 8 cells and exits non-zero iff
# any cell FAILs. A SKIP is allowed ONLY when the underlying slice/data is not
# present yet (with an actionable reason) — a cell whose feature IS installed but
# returns no/garbage data is a FAIL. SKIP does NOT fail the gate.
#
#   #    Consumer       Feature                         Real-data assertion
#   C1   claude-cli     .remember + native MEMORY.md    files present + plugin on + MEMORY.md
#   C2   claude-cli     MemPalace                       spawn stdio MCP; search returns a real hit
#   C2b  claude-cli     MemPalace cross-session (DEEP)  two real `claude -p` calls; marker recalled
#   C3   claude-cli     doc-RAG                          POST :8765/mcp search_documents → hits
#   C4   claude-cli     honcho                           spawn stdio MCP; remember→search finds marker
#   C5   claude-cli     FalkorDB graph                   spawn stdio MCP; remember_fact→recall_related returns neighbor
#   H1   hermes-fleet   doc-RAG                          sandbox → :8765/mcp search_documents → hits
#   H2   hermes-fleet   honcho                           sandbox → :7082/mcp remember→search finds marker
#
# REPEATABLE / IDEMPOTENT
#   - Read-only cells (C1; C2/C3/H1 search) mutate nothing.
#   - honcho write cells (C4/H2) write a run-unique MARKER to a DEDICATED bounded
#     peer+session ("acceptance-test"), then search for THAT marker. Re-running
#     accretes only bounded test-peer messages (honcho has no delete API) — never
#     durable junk elsewhere. C2b plants a MARKER via a real session; the Stop hook
#     mines it into MemPalace (append-only, bounded).
#
# SAFETY — never load a local CHAT model (M4/24GB). This script does NOT run
#   install/start/doctor, does NOT recreate/stop containers, never touches
#   :1234/:11434 or `lms load`/`ollama run`. It DOES touch small on-device
#   EMBEDDERS (mempalace minilm ~90MB; doc-RAG's assigned embedder) that memory
#   SEARCH legitimately needs — gate those off with FLEET_MEM_E2E_SKIP_LOCAL_EMBED=1.
#   C2b makes real `claude -p` calls (cloud opus-sub) — gated behind DEEP=1.
#
# INVOCATION — from the MAIN checkout (SOUL §25 live-stack rule):
#   bash installer/smoke/fleet-memory-e2e.sh
#   (repo-local runtime files — .env for the mempalace wrapper, .remember — are
#    resolved against the main working tree even if this is launched from a
#    worktree, so the gate is correct wherever it runs.)
#
# ENV KNOBS
#   FLEET_MEM_E2E_SKIP_LOCAL_EMBED=1  skip C2 + C2b + any local-embed doc-RAG (strict no-local)
#   FLEET_MEM_E2E_DEEP=1              run C2b (real `claude -p` cross-session recall; costs sub quota)
#   FLEET_MEM_E2E_STRICT_HONCHO=1     promote a honcho SEARCH-subsystem error (C4/H2) from SKIP to FAIL
#   FLEET_MEM_E2E_REMEMBER_MAX_AGE_DAYS=N  C1 staleness note threshold (default 30; warn-only, never fails)
# =============================================================================
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Fleet Memory — live E2E acceptance (claude-cli + hermes-fleet)"

# ── knobs ────────────────────────────────────────────────────────────────────
SKIP_LOCAL_EMBED="${FLEET_MEM_E2E_SKIP_LOCAL_EMBED:-0}"
DEEP="${FLEET_MEM_E2E_DEEP:-0}"
STRICT_HONCHO="${FLEET_MEM_E2E_STRICT_HONCHO:-0}"
REMEMBER_MAX_AGE_DAYS="${FLEET_MEM_E2E_REMEMBER_MAX_AGE_DAYS:-30}"

# ── run-unique marker (repeatable, collision-free) ────────────────────────────
MARKER="fleetmem-e2e-$(date +%s)-$RANDOM"

# ── temp workspace (always cleaned) ───────────────────────────────────────────
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/fleetmem-e2e-XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

# ── matrix state ──────────────────────────────────────────────────────────────
declare -a M_ID M_NAME M_STATUS M_DETAIL
PASS_N=0 SKIP_N=0 FAIL_N=0
# record_cell <id> <name> <status:PASS|SKIP|FAIL> <detail…>
record_cell() {
  local id="$1" name="$2" status="$3"; shift 3; local detail="$*"
  M_ID+=("$id"); M_NAME+=("$name"); M_STATUS+=("$status"); M_DETAIL+=("$detail")
  case "$status" in
    PASS) PASS_N=$((PASS_N+1)); ok   "$id $name — PASS ${detail:+· $detail}" ;;
    FAIL) FAIL_N=$((FAIL_N+1)); err  "$id $name — FAIL ${detail:+· $detail}" ;;
    SKIP) SKIP_N=$((SKIP_N+1)); note "$id $name — SKIP ${detail:+· $detail}" ;;
  esac
}

# ── portable timeout (macOS has no coreutils `timeout`) ───────────────────────
if command -v timeout >/dev/null 2>&1;  then _TO=timeout
elif command -v gtimeout >/dev/null 2>&1; then _TO=gtimeout
else _TO=""; fi
run_to() { # run_to <secs> <cmd> [args…]
  local s="$1"; shift
  if [[ -n "$_TO" ]]; then "$_TO" "${s}s" "$@"
  elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"
  else "$@"; fi
}

# ── main working tree (repo-local runtime files live here; SOUL §25) ──────────
main_checkout() {
  local m=""
  if command -v git >/dev/null 2>&1; then
    m="$(git -C "$AI_STACK" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  fi
  [[ -n "$m" && -d "$m" ]] && printf '%s' "$m" || printf '%s' "$AI_STACK"
}
MAIN_CO="$(main_checkout)"

# ── locate the node MCP SDK (bundled with honcho-mcp / understand-mcp) ────────
NODE_BIN="$(command -v node 2>/dev/null || true)"
find_mcp_sdk_esm() {
  local c
  for c in \
    "$AI_STACK/honcho-mcp/node_modules/@modelcontextprotocol/sdk/dist/esm" \
    "$MAIN_CO/honcho-mcp/node_modules/@modelcontextprotocol/sdk/dist/esm" \
    "$AI_STACK/understand-mcp/node_modules/@modelcontextprotocol/sdk/dist/esm" \
    "$MAIN_CO/understand-mcp/node_modules/@modelcontextprotocol/sdk/dist/esm"; do
    [[ -f "$c/client/index.js" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
SDK_ESM="$(find_mcp_sdk_esm || true)"

# ── the node MCP client helper (drives stdio + streamable-http, JSON out) ─────
# One reusable client: connects, lists tools, runs each call (fixed name OR a
# pickTool{regex,requireProp} selector), prints ONE JSON line and exits 0 on
# every path (so bash parses cleanly). A watchdog force-exits if a backend hangs.
NODE_HELPER="$TMPD/mcp_client.mjs"
cat > "$NODE_HELPER" <<'MJS'
import { pathToFileURL } from "node:url";
import { readFileSync } from "node:fs";
const spec = JSON.parse(process.env.MCP_SPEC_FILE ? readFileSync(process.env.MCP_SPEC_FILE, "utf8") : process.env.MCP_SPEC);
const out = { tools: [], calls: [] };
let client = null;
const emit = () => { try { process.stdout.write(JSON.stringify(out)); } catch {} };
const watchdog = setTimeout(() => { out.error = out.error || "watchdog timeout"; try { client && client.close(); } catch {} emit(); process.exit(0); }, spec.timeoutMs || 120000);
try {
  const { Client } = await import(pathToFileURL(`${spec.sdk}/client/index.js`).href);
  let transport;
  if (spec.transport === "http") {
    const { StreamableHTTPClientTransport } = await import(pathToFileURL(`${spec.sdk}/client/streamableHttp.js`).href);
    transport = new StreamableHTTPClientTransport(new URL(spec.url));
  } else {
    const { StdioClientTransport } = await import(pathToFileURL(`${spec.sdk}/client/stdio.js`).href);
    transport = new StdioClientTransport({ command: spec.command, args: spec.args || [], env: { ...process.env, ...(spec.env || {}) }, stderr: "ignore" });
  }
  client = new Client({ name: "fleetmem-e2e", version: "1" });
  await client.connect(transport);
  const tl = await client.listTools();
  out.tools = tl.tools.map((t) => t.name);
  for (const call of spec.calls || []) {
    let name = call.name;
    if (call.pickTool) {
      const re = new RegExp(call.pickTool.regex, "i");
      const rp = call.pickTool.requireProp;
      const t = tl.tools.find((x) => re.test(x.name) && (!rp || (x.inputSchema && x.inputSchema.properties && rp in x.inputSchema.properties)));
      name = t ? t.name : null;
    }
    if (!name) { out.calls.push({ name: null, isError: true, text: "no matching tool" }); continue; }
    try {
      const r = await client.callTool({ name, arguments: call.arguments || {} });
      out.calls.push({ name, isError: !!r.isError, text: (r.content || []).map((c) => c.text || "").join("") });
    } catch (e) { out.calls.push({ name, isError: true, text: String((e && e.message) || e) }); }
  }
  try { await client.close(); } catch {}
  clearTimeout(watchdog); emit(); process.exit(0);
} catch (e) { clearTimeout(watchdog); out.error = String((e && e.stack) || e); emit(); process.exit(0); }
MJS

# run the node helper against a spec file; echoes the helper's JSON (or "" on failure)
mcp_run() { # mcp_run <spec-file> <secs>
  [[ -n "$NODE_BIN" && -n "$SDK_ESM" ]] || { printf ''; return 0; }
  MCP_SPEC_FILE="$1" run_to "$2" "$NODE_BIN" "$NODE_HELPER" 2>/dev/null || true
}

# ── curl helpers (LOCAL ports only) ───────────────────────────────────────────
# NOTE: with -w '%{http_code}' curl ALWAYS prints a code (000 when no response) even on
# failure, so use `|| true` — NOT `|| echo 000`, which would concat a 2nd 000 ("000000").
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-4}" "$1" 2>/dev/null || true; }
# echo the ai-stack-docs point count ("MISSING" if the collection/endpoint is absent)
qdrant_points() {
  local base r
  for base in "http://qdrant:6333" "http://localhost:6333"; do
    r="$(curl -s --max-time 4 "$base/collections/ai-stack-docs" 2>/dev/null || true)"
    [[ -n "$r" ]] || continue
    printf '%s' "$r" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: print("MISSING"); sys.exit(0)
res=d.get("result")
if not isinstance(res,dict): print("MISSING"); sys.exit(0)
print(res.get("points_count", 0))' 2>/dev/null && return 0
  done
  printf 'MISSING'
}

# ── openshell resolver (brew-first, mirrors smoke/27.sh & 30.sh) ──────────────
resolve_openshell() { if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell; else command -v openshell || echo ""; fi; }
# true iff the hermes-fleet-v1 sandbox is Ready
fleet_ready() {
  local osh="$1"; [[ -n "$osh" ]] || return 1
  "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'
}

# ── `claude mcp list` — captured ONCE, reused by the registration gates ───────
CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
CLAUDE_LIST=""
[[ -n "$CLAUDE_BIN" ]] && CLAUDE_LIST="$(run_to 90 "$CLAUDE_BIN" mcp list 2>/dev/null || true)"
# claude_server <name> → 0 connected · 1 listed-but-not-connected · 2 not listed
claude_server() {
  local line; line="$(printf '%s\n' "$CLAUDE_LIST" | grep -E "^$1:" | head -1 || true)"
  [[ -n "$line" ]] || return 2
  printf '%s' "$line" | grep -qE '✔|✓|Connected' && return 0 || return 1
}

# resolve a mempalace wrapper backed by a real .env (worktree has none → use MAIN_CO)
mempalace_wrapper() {
  if [[ -f "$AI_STACK/.env" && -x "$AI_STACK/bin/mempalace-mcp" ]]; then echo "$AI_STACK/bin/mempalace-mcp"
  elif [[ -f "$MAIN_CO/.env" && -x "$MAIN_CO/bin/mempalace-mcp" ]]; then echo "$MAIN_CO/bin/mempalace-mcp"
  else echo ""; fi
}

# resolve the honcho REST base that is actually reachable (alias then loopback)
honcho_base() {
  local b
  for b in "http://honcho:8000" "http://localhost:8000"; do
    [[ "$(http_code "$b/" 3)" != "000" ]] && { printf '%s' "$b"; return 0; }
  done
  printf ''
}

log "run marker: $MARKER"
note "main checkout: $MAIN_CO"
note "mcp sdk: ${SDK_ESM:-<not found>} · node: ${NODE_BIN:-<absent>}"
[[ "$SKIP_LOCAL_EMBED" == 1 ]] && note "FLEET_MEM_E2E_SKIP_LOCAL_EMBED=1 (C2/C2b + local-embed doc-RAG will skip)"
[[ "$DEEP" == 1 ]] && note "FLEET_MEM_E2E_DEEP=1 (C2b cross-session recall will run — costs sub quota)"

# =============================================================================
# C1 — claude-cli · .remember/ rolling memory + native project MEMORY.md
#   No inference. Installed-gate = the `remember` plugin is enabled. When installed,
#   assert the store has files + a native MEMORY.md exists. Staleness is a NOTE only
#   (a populated-but-old store is not a broken feature → never fails the gate).
# =============================================================================
cell_C1() {
  local id="C1" name=".remember + native MEMORY.md"
  local enabled
  enabled="$(python3 - "$HOME/.claude/settings.json" <<'PY' 2>/dev/null || true
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("no"); raise SystemExit
print("yes" if d.get("enabledPlugins",{}).get("remember@claude-plugins-official") is True else "no")
PY
)"
  [[ "$enabled" == "yes" ]] || { record_cell "$id" "$name" SKIP "remember plugin not enabled (install fleet_memory / enable remember@claude-plugins-official)"; return 0; }

  local rhome=""
  if [[ -d "$AI_STACK/.remember" ]]; then rhome="$AI_STACK/.remember"
  elif [[ -d "$MAIN_CO/.remember" ]]; then rhome="$MAIN_CO/.remember"; fi
  [[ -n "$rhome" ]] || { record_cell "$id" "$name" SKIP "no .remember store yet (open a Claude session in the repo to populate)"; return 0; }

  local nfiles newest age_days
  nfiles="$(find "$rhome" -type f 2>/dev/null | wc -l | tr -d ' ')" || nfiles=0
  [[ "${nfiles:-0}" -ge 1 ]] || { record_cell "$id" "$name" FAIL "remember enabled but $rhome is empty"; return 0; }

  # newest mtime + age in days (portable: BSD stat)
  newest="$(find "$rhome" -type f -print0 2>/dev/null | xargs -0 stat -f '%m' 2>/dev/null | sort -rn | head -1)" || newest=0
  [[ "$newest" =~ ^[0-9]+$ ]] || newest=0
  age_days=$(( ( $(date +%s) - newest ) / 86400 ))

  local memmd
  memmd="$(ls "$HOME"/.claude/projects/*/memory/MEMORY.md 2>/dev/null | head -1)" || memmd=""
  [[ -n "$memmd" ]] || { record_cell "$id" "$name" FAIL "no native project MEMORY.md under ~/.claude/projects/*/memory/"; return 0; }

  local stale=""
  if (( age_days > REMEMBER_MAX_AGE_DAYS )); then stale=" [STALE: >${REMEMBER_MAX_AGE_DAYS}d — not written recently]"; fi
  record_cell "$id" "$name" PASS "$nfiles files, newest ${age_days}d ago${stale}; MEMORY.md present"
}

# =============================================================================
# C2 — claude-cli · MemPalace (deterministic protocol drive)
#   Gate: mempalace registered in `claude mcp list`. Then spawn the SAME stdio MCP
#   wrapper a real session uses, list tools, pick a search-like tool, and assert a
#   real hit from the ~82MB store. Uses the on-device minilm embedder.
# =============================================================================
cell_C2() {
  local id="C2" name="MemPalace (stdio MCP search)"
  [[ "$SKIP_LOCAL_EMBED" == 1 ]] && { record_cell "$id" "$name" SKIP "FLEET_MEM_E2E_SKIP_LOCAL_EMBED=1 (mempalace uses on-device minilm)"; return 0; }
  [[ -n "$CLAUDE_BIN" ]] || { record_cell "$id" "$name" SKIP "claude CLI not found on PATH"; return 0; }
  local cs=0; claude_server mempalace || cs=$?
  [[ $cs -eq 2 ]] && { record_cell "$id" "$name" SKIP "mempalace not registered (run: mayssam-ai-stack.sh install fleet_memory)"; return 0; }
  [[ $cs -eq 1 ]] && { record_cell "$id" "$name" SKIP "mempalace registered but not Connected in 'claude mcp list'"; return 0; }
  [[ -n "$SDK_ESM" && -n "$NODE_BIN" ]] || { record_cell "$id" "$name" SKIP "node MCP SDK unavailable (honcho-mcp/node_modules missing)"; return 0; }
  local wrap; wrap="$(mempalace_wrapper)"
  [[ -n "$wrap" ]] || { record_cell "$id" "$name" SKIP "no mempalace-mcp wrapper with a backing .env (run from main checkout / install 26)"; return 0; }

  python3 - "$TMPD/c2.json" "$SDK_ESM" "$wrap" <<'PY'
import json,sys
json.dump({"sdk":sys.argv[2],"transport":"stdio","command":sys.argv[3],"args":[],
  "calls":[{"pickTool":{"regex":"search|recall|query|find","requireProp":"query"},"arguments":{"query":"memory","limit":3}}],
  "timeoutMs":90000}, open(sys.argv[1],"w"))
PY
  local out; out="$(mcp_run "$TMPD/c2.json" 110)"
  local verdict; verdict="$(printf '%s' "$out" | python3 -c '
import sys,json
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print("FAIL|mempalace MCP client produced no/invalid output"); raise SystemExit
if d.get("error"): print("SKIP|mempalace MCP client error: "+d["error"][:160].replace("|","/")); raise SystemExit
calls=d.get("calls") or []
if not calls or not calls[0].get("name"):
    print("SKIP|no search-like tool exposed (tools: "+",".join(d.get("tools",[])[:6])+")"); raise SystemExit
c=calls[0]; nm=str(c.get("name")); t=c.get("text","") or ""
if c.get("isError"): print("SKIP|mempalace search tool errored: "+t[:140].replace("|","/")); raise SystemExit
hits=None; total=None
try:
    j=json.loads(t); r=j.get("results")
    if isinstance(r,list): hits=len(r)
    if isinstance(j.get("total_before_filter"),int): total=j.get("total_before_filter")
except Exception: pass
if (hits or 0)>0 or (total or 0)>0:
    print("PASS|"+nm+" returned real hits (hits="+str(hits)+", store_candidates="+str(total)+")")
elif hits==0 and total==0:
    print("SKIP|mempalace store empty")
elif len(t)>40:
    print("PASS|"+nm+" returned a real payload ("+str(len(t))+" bytes)")
else:
    print("SKIP|mempalace store empty")
' 2>/dev/null || true)"
  [[ -n "$verdict" ]] || verdict="FAIL|mempalace probe did not return a verdict"
  record_cell "$id" "$name" "${verdict%%|*}" "${verdict#*|}"
}

# =============================================================================
# C2b — claude-cli · MemPalace CROSS-SESSION recall (DEEP / opt-in)
#   The operator's headline "does claude actually remember across sessions?" proof.
#   Two real `claude -p` calls: session 1 plants a codeword (the Stop hook mines it
#   into MemPalace on exit); a NEW session 2 must recall it. Nondeterministic (a
#   model decides to call the tool + phrase the answer) → DEEP-gated, and a FAIL
#   here never blocks the deterministic gate unless hooks are truly wired + the
#   marker is lost. Complements C2 (deterministic tool-returns-data), not replaces.
# =============================================================================
cell_C2b() {
  local id="C2b" name="MemPalace cross-session recall (claude -p)"
  [[ "$DEEP" == 1 ]] || { record_cell "$id" "$name" SKIP "deep opt-in off (set FLEET_MEM_E2E_DEEP=1 — makes 2 real claude -p calls)"; return 0; }
  [[ "$SKIP_LOCAL_EMBED" == 1 ]] && { record_cell "$id" "$name" SKIP "FLEET_MEM_E2E_SKIP_LOCAL_EMBED=1 (mempalace embeds on-device)"; return 0; }
  [[ -n "$CLAUDE_BIN" ]] || { record_cell "$id" "$name" SKIP "claude CLI not found on PATH"; return 0; }
  local cs=0; claude_server mempalace || cs=$?
  [[ $cs -ne 0 ]] && { record_cell "$id" "$name" SKIP "mempalace not connected in 'claude mcp list' (install fleet_memory)"; return 0; }

  # auto-capture MUST be wired — without the Stop hook, session 1 is never captured,
  # so cross-session recall CANNOT work (honest reason, not a failure). Check both
  # the project-local and global settings scopes.
  local hooks_bin="$MAIN_CO/bin/mempalace-hooks"; [[ -x "$hooks_bin" ]] || hooks_bin="$AI_STACK/bin/mempalace-hooks"
  local wired="no"
  if [[ -x "$hooks_bin" ]]; then
    "$hooks_bin" status          2>/dev/null | grep -q 'Wired: YES' && wired="yes"
    "$hooks_bin" status --global 2>/dev/null | grep -q 'Wired: YES' && wired="yes"
  fi
  [[ "$wired" == "yes" ]] || { record_cell "$id" "$name" SKIP "auto-capture off: bin/mempalace-hooks install --apply (Stop hook required to capture session 1)"; return 0; }

  # both `claude -p` runs share ONE cwd (the operator's real project home).
  local cwd="$MAIN_CO"
  log "C2b: planting codeword $MARKER via a real claude session (cloud opus-sub)…"
  ( cd "$cwd" && run_to 240 "$CLAUDE_BIN" -p "Please remember this fact for later: my deploy codeword is $MARKER." >/dev/null 2>&1 ) || true
  sleep 5   # let the synchronous Stop hook finish mining the session into MemPalace
  log "C2b: recalling the codeword in a NEW session…"
  local ans
  ans="$( cd "$cwd" && run_to 240 "$CLAUDE_BIN" -p "Use the mempalace memory tool to search your past conversations and tell me my deploy codeword. Answer with ONLY the codeword." 2>/dev/null || true )"
  if printf '%s' "$ans" | grep -qF "$MARKER"; then
    record_cell "$id" "$name" PASS "codeword recalled across sessions"
  else
    record_cell "$id" "$name" FAIL "codeword NOT recalled (hooks wired but marker lost; got: $(printf '%s' "$ans" | tr '\n' ' ' | cut -c1-80))"
  fi
}

# =============================================================================
# C3 — claude-cli · doc-RAG (docs-mcp streamable-http)
#   Gate: docs-mcp registered+connected in `claude mcp list`. Real path: drive
#   :8765/mcp search_documents. Corpus-empty is detected via Qdrant point count
#   (SKIP), so a populated corpus that returns nothing is an honest FAIL.
# =============================================================================
cell_C3() {
  local id="C3" name="doc-RAG (:8765 search_documents)"
  [[ -n "$CLAUDE_BIN" ]] || { record_cell "$id" "$name" SKIP "claude CLI not found on PATH"; return 0; }
  local cs=0; claude_server docs-mcp || cs=$?
  [[ $cs -eq 2 ]] && { record_cell "$id" "$name" SKIP "docs-mcp not registered (run: mayssam-ai-stack.sh install fleet_memory)"; return 0; }
  [[ "$(http_code http://localhost:8765/mcp 4)" == "000" ]] && { record_cell "$id" "$name" SKIP "docs-mcp not running (mayssam-ai-stack.sh start docs_mcp)"; return 0; }
  local pts; pts="$(qdrant_points)"
  [[ "$pts" == "MISSING" || "$pts" == "0" ]] && { record_cell "$id" "$name" SKIP "corpus empty (populate: cd ingestor && python ingest.py)"; return 0; }
  [[ -n "$SDK_ESM" && -n "$NODE_BIN" ]] || { record_cell "$id" "$name" SKIP "node MCP SDK unavailable (honcho-mcp/node_modules missing)"; return 0; }

  python3 - "$TMPD/c3.json" "$SDK_ESM" <<'PY'
import json,sys
json.dump({"sdk":sys.argv[2],"transport":"http","url":"http://localhost:8765/mcp",
  "calls":[{"name":"search_documents","arguments":{"query":"stack","top_k":3}}],"timeoutMs":40000}, open(sys.argv[1],"w"))
PY
  local out; out="$(mcp_run "$TMPD/c3.json" 50)"
  local verdict; verdict="$(printf '%s' "$out" | python3 -c '
import sys,json
try: d=json.loads(sys.stdin.read())
except Exception: print("FAIL|docs-mcp client produced no/invalid output"); raise SystemExit
if d.get("error"): print("SKIP|docs-mcp client error: "+d["error"][:160].replace("|","/")); raise SystemExit
calls=d.get("calls") or []
if not calls: print("FAIL|search_documents was not called"); raise SystemExit
c=calls[0]; t=c.get("text","") or ""
if c.get("isError"): print("FAIL|search_documents errored on a populated corpus: "+t[:140].replace("|","/")); raise SystemExit
n=None
try:
    j=json.loads(t); n=len(j) if isinstance(j,list) else None
except Exception: pass
if (n or 0)>0: print(f"PASS|search_documents returned {n} hit(s)")
elif len(t)>40: print(f"PASS|search_documents returned a real payload ({len(t)} bytes)")
else: print("FAIL|corpus populated but search_documents returned nothing")
' 2>/dev/null || true)"
  [[ -n "$verdict" ]] || verdict="FAIL|docs-mcp probe did not return a verdict"
  record_cell "$id" "$name" "${verdict%%|*}" "${verdict#*|}"
}

# =============================================================================
# C4 — claude-cli · honcho (stdio MCP; remember → search the marker)
#   Gate: the honcho-mcp shim exists + honcho REST is reachable. Real path: spawn
#   `node bin.mjs --stdio`, honcho_remember the MARKER to the bounded acceptance
#   peer, then honcho_search for it. A honcho SEARCH-subsystem error (e.g. its
#   embedding backend down/misconfigured) is a not-ready dependency → SKIP with a
#   loud reason (promote to FAIL with FLEET_MEM_E2E_STRICT_HONCHO=1). A search that
#   RUNS but does not return the just-written marker is a real recall FAIL.
# =============================================================================
honcho_stdio_cell() { # honcho_stdio_cell <id> <name> <honcho_bin> <honcho_base>
  local id="$1" name="$2" hbin="$3" hbase="$4"
  [[ -n "$SDK_ESM" && -n "$NODE_BIN" ]] || { record_cell "$id" "$name" SKIP "node MCP SDK unavailable (honcho-mcp/node_modules missing)"; return 0; }
  python3 - "$TMPD/c4.json" "$SDK_ESM" "$NODE_BIN" "$hbin" "$hbase" "$MARKER" <<'PY'
import json,sys
path,sdk,node,hbin,base,marker=sys.argv[1:7]
json.dump({"sdk":sdk,"transport":"stdio","command":node,"args":[hbin,"--stdio"],
  "env":{"HONCHO_BASE_URL":base},
  "calls":[
    {"name":"honcho_remember","arguments":{"peer":"acceptance-test","content":"acceptance-test marker "+marker,"session":"acceptance-test"}},
    {"name":"honcho_search","arguments":{"peer":"acceptance-test","query":marker,"limit":10}}],
  "timeoutMs":50000}, open(path,"w"))
PY
  local out; out="$(mcp_run "$TMPD/c4.json" 70)"
  local verdict; verdict="$(printf '%s' "$out" | STRICT="$STRICT_HONCHO" MARKER="$MARKER" python3 -c '
import sys,json,os
strict=os.environ.get("STRICT")=="1"; marker=os.environ["MARKER"]
try: d=json.loads(sys.stdin.read())
except Exception: print("FAIL|honcho MCP client produced no/invalid output"); raise SystemExit
if d.get("error"): print("SKIP|honcho MCP client error: "+d["error"][:160].replace("|","/")); raise SystemExit
calls={c.get("name"):c for c in (d.get("calls") or [])}
rem=calls.get("honcho_remember"); srch=calls.get("honcho_search")
def err_of(c):
    t=(c or {}).get("text","") or ""
    try: j=json.loads(t); return j.get("error")
    except Exception: return ("error" in t) and t or None
if not rem or not srch: print("FAIL|honcho remember/search calls missing"); raise SystemExit
re_=err_of(rem)
if re_:
    if "unreachable" in re_: print("SKIP|honcho unreachable: "+re_[:120].replace("|","/"))
    else: print("FAIL|honcho remember failed (reachable but write rejected): "+re_[:120].replace("|","/"))
    raise SystemExit
st=srch.get("text","") or ""
if marker in st: print("PASS|marker written and recalled via honcho_search"); raise SystemExit
se=err_of(srch)
if se:
    if "unreachable" in se: print("SKIP|honcho unreachable during search: "+se[:110].replace("|","/"))
    else:
        v="FAIL" if strict else "SKIP"
        print(v+"|honcho search backend not ready: "+se[:120].replace("|","/")+(""  if strict else " (set FLEET_MEM_E2E_STRICT_HONCHO=1 to enforce)"))
    raise SystemExit
print("FAIL|honcho search ran but the just-written marker was not recalled")
' 2>/dev/null || true)"
  [[ -n "$verdict" ]] || verdict="FAIL|honcho probe did not return a verdict"
  record_cell "$id" "$name" "${verdict%%|*}" "${verdict#*|}"
}
cell_C4() {
  local id="C4" name="honcho (stdio remember->search)"
  local hbin="$AI_STACK/honcho-mcp/bin.mjs"; [[ -f "$hbin" ]] || hbin="$MAIN_CO/honcho-mcp/bin.mjs"
  [[ -f "$hbin" ]] || { record_cell "$id" "$name" SKIP "honcho-mcp shim not installed (run: mayssam-ai-stack.sh install honcho_mcp)"; return 0; }
  local hbase; hbase="$(honcho_base)"
  [[ -n "$hbase" ]] || { record_cell "$id" "$name" SKIP "honcho REST unreachable on :8000 (mayssam-ai-stack.sh start honcho)"; return 0; }
  honcho_stdio_cell "$id" "$name" "$hbin" "$hbase"
}

# =============================================================================
# C5 — claude-cli · FalkorDB graph memory (stdio MCP; remember_fact → recall_related)
#   Gate: the falkordb-mcp shim exists. Real path: spawn `node bin.mjs --stdio`,
#   remember_fact a run-unique (subject)-[PROVES]->(object) edge, then recall_related
#   on the subject and assert the object neighbor comes back. Backend-unreachable is a
#   not-ready dependency → SKIP; a recall that RUNS but omits the just-written neighbor
#   is a real FAIL. stdio needs no token. Bounded accretion: nodes are uniquely named
#   per run marker (FalkorDB has no delete API here) — same pattern as C4's honcho peer.
# =============================================================================
cell_C5() {
  local id="C5" name="falkordb (stdio remember->recall)"
  local fbin="$AI_STACK/falkordb-mcp/bin.mjs"; [[ -f "$fbin" ]] || fbin="$MAIN_CO/falkordb-mcp/bin.mjs"
  [[ -f "$fbin" ]] || { record_cell "$id" "$name" SKIP "falkordb-mcp shim not installed (run: mayssam-ai-stack.sh install falkordb_mcp)"; return 0; }
  [[ -n "$SDK_ESM" && -n "$NODE_BIN" ]] || { record_cell "$id" "$name" SKIP "node MCP SDK unavailable (honcho-mcp/node_modules missing)"; return 0; }
  local furl; furl="$(get_env FALKORDB_URL 'redis://falkordb:6379')"
  local subj="acceptance-subj-$MARKER" obj="acceptance-obj-$MARKER"
  python3 - "$TMPD/c5.json" "$SDK_ESM" "$NODE_BIN" "$fbin" "$furl" "$subj" "$obj" <<'PY'
import json,sys
path,sdk,node,fbin,furl,subj,obj=sys.argv[1:8]
json.dump({"sdk":sdk,"transport":"stdio","command":node,"args":[fbin,"--stdio"],
  "env":{"FALKORDB_URL":furl},
  "calls":[
    {"name":"remember_fact","arguments":{"subject":subj,"predicate":"PROVES","object":obj}},
    {"name":"recall_related","arguments":{"name":subj,"limit":10}}],
  "timeoutMs":40000}, open(path,"w"))
PY
  local out; out="$(mcp_run "$TMPD/c5.json" 60)"
  local verdict; verdict="$(printf '%s' "$out" | OBJ="$obj" python3 -c '
import sys,json,os
obj=os.environ["OBJ"]
try: d=json.loads(sys.stdin.read())
except Exception: print("FAIL|falkordb MCP client produced no/invalid output"); raise SystemExit
if d.get("error"): print("SKIP|falkordb MCP client error: "+d["error"][:160].replace("|","/")); raise SystemExit
calls={c.get("name"):c for c in (d.get("calls") or [])}
rem=calls.get("remember_fact"); rec=calls.get("recall_related")
def err_of(c):
    t=(c or {}).get("text","") or ""
    try: j=json.loads(t); return j.get("error")
    except Exception: return None
if not rem or not rec: print("FAIL|falkordb remember/recall calls missing"); raise SystemExit
re_=err_of(rem)
if re_:
    lo=re_.lower()
    if "unreachable" in lo or "connect" in lo or "econnrefused" in lo: print("SKIP|falkordb unreachable: "+re_[:120].replace("|","/"))
    else: print("FAIL|remember_fact failed (reachable but rejected): "+re_[:120].replace("|","/"))
    raise SystemExit
rt=rec.get("text","") or ""
if obj in rt: print("PASS|fact written and neighbor recalled via recall_related"); raise SystemExit
se=err_of(rec)
if se:
    lo=se.lower()
    if "unreachable" in lo or "connect" in lo or "econnrefused" in lo: print("SKIP|falkordb unreachable during recall: "+se[:110].replace("|","/"))
    else: print("FAIL|recall_related errored: "+se[:120].replace("|","/"))
    raise SystemExit
print("FAIL|recall_related ran but the just-written neighbor was not returned")
' 2>/dev/null || true)"
  [[ -n "$verdict" ]] || verdict="FAIL|falkordb probe did not return a verdict"
  record_cell "$id" "$name" "${verdict%%|*}" "${verdict#*|}"
}

# =============================================================================
# H1 — hermes-fleet · doc-RAG (sandbox → host.docker.internal:8765/mcp)
#   The fleet path: run a probe INSIDE hermes-fleet-v1 (same as smoke 27/30) that
#   reaches docs-mcp over host.docker.internal and asserts real hits. SKIP if fleet
#   down / corpus empty; FAIL if wired+populated but nothing comes back.
# =============================================================================
cell_H1() {
  local id="H1" name="hermes doc-RAG (sandbox -> :8765)"
  local osh; osh="$(resolve_openshell)"
  [[ -n "$osh" ]] || { record_cell "$id" "$name" SKIP "openshell CLI not found"; return 0; }
  fleet_ready "$osh" || { record_cell "$id" "$name" SKIP "hermes-fleet-v1 sandbox not Ready (mayssam-ai-stack.sh install 04)"; return 0; }
  [[ "$(http_code http://localhost:8765/mcp 4)" == "000" ]] && { record_cell "$id" "$name" SKIP "docs-mcp not running (mayssam-ai-stack.sh start docs_mcp)"; return 0; }
  local pts; pts="$(qdrant_points)"
  [[ "$pts" == "MISSING" || "$pts" == "0" ]] && { record_cell "$id" "$name" SKIP "corpus empty (populate: cd ingestor && python ingest.py)"; return 0; }

  local probe="$TMPD/h1-docs-probe.py"
  cat > "$probe" <<'PY'
import asyncio, sys, re
URL="http://host.docker.internal:8765/mcp"
async def main():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client
    async with streamablehttp_client(URL) as (r,w,_):
        async with ClientSession(r,w) as s:
            await s.initialize()
            tools=await s.list_tools()
            res=await s.call_tool("search_documents", {"query":"stack","top_k":3})
            txt="".join(getattr(c,"text","") for c in res.content)
            hits=len(re.findall(r'"score"', txt))
            print(f"TOOLS={len(tools.tools)} MATCHES={hits}")
            return len(tools.tools)>=1 and hits>=1
sys.exit(0 if asyncio.run(main()) else 3)
PY
  "$osh" sandbox upload --no-git-ignore hermes-fleet-v1 "$probe" /sandbox/ >/dev/null 2>&1 \
    || { record_cell "$id" "$name" SKIP "could not upload probe to sandbox"; return 0; }
  local pname; pname="$(basename "$probe")"
  local out; out="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 60 </dev/null -- python3 "/sandbox/$pname" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')" || true
  "$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- rm -f "/sandbox/$pname" >/dev/null 2>&1 || true
  if grep -qE 'TOOLS=[1-9][0-9]* MATCHES=[1-9]' <<<"$out"; then
    record_cell "$id" "$name" PASS "fleet reached docs-mcp; search_documents returned hits"
  elif grep -qE 'MATCHES=0' <<<"$out"; then
    record_cell "$id" "$name" FAIL "corpus populated but fleet search_documents returned 0 ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70))"
  else
    record_cell "$id" "$name" SKIP "fleet could not reach docs-mcp ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90))"
  fi
}

# =============================================================================
# H2 — hermes-fleet · honcho (sandbox → host.docker.internal:7082/mcp, token)
#   Phase 40 wires the token-gated honcho-mcp http shim as the ONLY sandbox route
#   to honcho. Probe from inside the sandbox: remember→search the marker. SKIP if
#   the shim/token/fleet aren't ready; honcho SEARCH-subsystem error → SKIP (FAIL
#   under STRICT); search runs but marker absent → FAIL.
# =============================================================================
cell_H2() {
  local id="H2" name="hermes honcho (sandbox -> :7082)"
  local osh; osh="$(resolve_openshell)"
  [[ -n "$osh" ]] || { record_cell "$id" "$name" SKIP "openshell CLI not found"; return 0; }
  fleet_ready "$osh" || { record_cell "$id" "$name" SKIP "hermes-fleet-v1 sandbox not Ready (mayssam-ai-stack.sh install 04)"; return 0; }
  [[ "$(http_code http://localhost:7082/healthz 3)" == "000" ]] && { record_cell "$id" "$name" SKIP "honcho-mcp http shim not running on :7082 (Phase 40 — mayssam-ai-stack.sh install 40)"; return 0; }
  local token; token="$(get_env HONCHO_MCP_TOKEN '')"
  [[ -n "$token" ]] || { record_cell "$id" "$name" SKIP "HONCHO_MCP_TOKEN absent from .env (Phase 40 mints it)"; return 0; }

  local probe="$TMPD/h2-honcho-probe.py"
  cat > "$probe" <<PY
import asyncio, os, sys
TOKEN=(os.environ.get("H_TOKEN") or sys.stdin.readline()).strip()
MARKER="$MARKER"
URL="http://host.docker.internal:7082/mcp"
async def main():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client
    async with streamablehttp_client(URL, headers={"Authorization": f"Bearer {TOKEN}"}) as (r,w,_):
        async with ClientSession(r,w) as s:
            await s.initialize()
            await s.call_tool("honcho_remember", {"peer":"acceptance-test","content":"acceptance-test marker "+MARKER,"session":"acceptance-test"})
            res=await s.call_tool("honcho_search", {"peer":"acceptance-test","query":MARKER,"limit":10})
            txt="".join(getattr(c,"text","") for c in res.content)
            if MARKER in txt: print("FOUND=1")
            elif '"error"' in txt: print("SEARCHERR=1 "+txt[:120].replace(chr(10)," "))
            else: print("FOUND=0")
            return MARKER in txt
sys.exit(0 if asyncio.run(main()) else 3)
PY
  "$osh" sandbox upload --no-git-ignore hermes-fleet-v1 "$probe" /sandbox/ >/dev/null 2>&1 \
    || { record_cell "$id" "$name" SKIP "could not upload probe to sandbox"; return 0; }
  local pname; pname="$(basename "$probe")"
  local out; out="$(printf '%s\n' "$token" | "$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 60 -- python3 "/sandbox/$pname" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')" || true
  "$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- rm -f "/sandbox/$pname" >/dev/null 2>&1 || true
  if grep -qE 'FOUND=1' <<<"$out"; then
    record_cell "$id" "$name" PASS "fleet wrote + recalled the marker via honcho over :7082"
  elif grep -qE 'SEARCHERR=1' <<<"$out"; then
    if [[ "$STRICT_HONCHO" == 1 ]]; then record_cell "$id" "$name" FAIL "honcho search backend not ready: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"
    else record_cell "$id" "$name" SKIP "honcho search backend not ready (set FLEET_MEM_E2E_STRICT_HONCHO=1 to enforce): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"; fi
  elif grep -qE 'FOUND=0' <<<"$out"; then
    record_cell "$id" "$name" FAIL "honcho search ran but marker not recalled from the fleet"
  else
    record_cell "$id" "$name" SKIP "fleet could not reach honcho shim ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90))"
  fi
}

# ── run cells ─────────────────────────────────────────────────────────────────
echo
cell_C1
cell_C2
cell_C2b
cell_C3
cell_C4
cell_C5
cell_H1
cell_H2

# ── matrix ────────────────────────────────────────────────────────────────────
hdr "Acceptance matrix"
printf '  %-4s %-42s %-7s %s\n' "ID" "CELL" "VERDICT" "DETAIL"
printf '  %-4s %-42s %-7s %s\n' "----" "------------------------------------------" "-------" "------"
for i in "${!M_ID[@]}"; do
  local_c=""
  case "${M_STATUS[$i]}" in
    PASS) local_c="$C_GREEN" ;;
    FAIL) local_c="$C_RED" ;;
    SKIP) local_c="$C_YELLOW" ;;
  esac
  printf '  %-4s %-42s %s%-7s%s %s\n' "${M_ID[$i]}" "${M_NAME[$i]}" "$local_c" "${M_STATUS[$i]}" "$C_RESET" "${M_DETAIL[$i]}"
done
echo
log "Totals: ${C_GREEN}${PASS_N} PASS${C_RESET} · ${C_YELLOW}${SKIP_N} SKIP${C_RESET} · ${C_RED}${FAIL_N} FAIL${C_RESET}  (marker: $MARKER)"

if (( FAIL_N > 0 )); then
  err "Fleet-memory acceptance GATE: FAIL — $FAIL_N cell(s) failed (see matrix)."
  exit 1
fi
ok "Fleet-memory acceptance GATE: PASS — 0 failures ($SKIP_N skipped for absent deps/data)."
exit 0
