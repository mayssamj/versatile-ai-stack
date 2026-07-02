#!/usr/bin/env bash
# test_scoped_key_catalog_reconcile.sh — regression guard for the scoped-LiteLLM-key
# CATALOG-DRIFT class. Commit ca08cc1 ("nemotron-only") REMOVED 6 local slugs
# (local-gemma4, local-gemma4-12b, local-lfm2, local-nemotron3-heavy,
# local-qwen-heavy-fast, local-qwen3). The scoped-key machinery was WIDEN-only
# (litellm_reconcile_key unions, ensure_key_widened was coverage-gated, doctor's
# key checks are subset checks) and the rendered consumer artifacts are write-once,
# so a catalog REMOVAL over an ALREADY-INSTALLED stack drifted live keys + doctor-
# invisible artifacts and could NOT self-heal. This test pins the post-fix contract:
#
#   (b0) OFFLINE: the scoped_key_registry has all 7 opt-in consumers, each with a
#        valid-JSON model list that includes 'local' (the model the sims call).
#   (b1) OFFLINE: no rendered artifact (deer-flow picker, bin/* launchers, opencode.json)
#        references a slug ca08cc1 removed (word-bounded denylist — a still-valid
#        neighbour like local-lfm2-mlx / local-nemotron3-nano-4b is never false-flagged).
#   (b2) LIVE: every local-family slug pinned in the deer-flow picker is routable.
#   (a)  LIVE, OOM-SAFE: mint a THROWAWAY scoped key whose allowlist carries an EXTRA
#        routable slug and is MISSING an intended one, run the reconcile primitive, and
#        assert GET /v1/models under the key converges to EXACTLY the intended set.
#        Control-plane ONLY (/key/generate + /key/update + /key/delete + metadata
#        /v1/models) — NEVER a chat completion, so NO local model is loaded (24GB OOM).
#
# The primitive under test defaults to litellm_reconcile_key_exact (the converge-to-
# exact fix); override with SCOPED_KEY_RECONCILE_FN. With the OLD widen-only
# litellm_reconcile_key, part (a) correctly FAILS (the stale extra is never dropped) —
# proving the test discriminates the bug from the fix.
#
# SKIP-CLEAN (exit 0, no FAIL) when LiteLLM :4000 is unreachable, the master key is
# unset, or the routable catalog has <3 models — the offline blocks (b0/b1) still run.
# Sources ONLY common.sh + env.sh (NOT models.sh, which runs main "$@" at source time).
# Uses t_ok/t_bad counters (does NOT redefine common.sh's ok/warn/log — the primitive
# calls them). All .env writes are isolated to a 0600 temp ENV_FILE.
#
# Run:  bash installer/tests/test_scoped_key_catalog_reconcile.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AI_STACK="$(cd "$HERE/../.." && pwd)"
LITELLM="${SCOPED_KEY_TEST_LITELLM:-http://127.0.0.1:4000}"
export LITELLM_BASE_URL="$LITELLM"
RECONCILE_FN="${SCOPED_KEY_RECONCILE_FN:-litellm_reconcile_key_exact}"

TPASS=0; TFAIL=0
t_ok(){  TPASS=$((TPASS+1)); echo "  ok   $1"; }
t_bad(){ TFAIL=$((TFAIL+1)); echo "  FAIL $1"; }
skip(){ echo "  [skip] $*"; echo; echo "RESULT: $TPASS passed, $TFAIL failed (live parts skipped)"; exit $(( TFAIL > 0 ? 1 : 0 )); }

command -v python3 >/dev/null 2>&1 || { echo "  [skip] python3 not on PATH — cannot run"; exit 0; }

# Source the two pure libs early (needed for b0's scoped_key_registry too). NOT models.sh.
# shellcheck disable=SC1090
source "$AI_STACK/installer/lib/env.sh"      # get_env/set_env (reads/writes $ENV_FILE)
# shellcheck disable=SC1090
source "$AI_STACK/installer/lib/common.sh"   # log/ok/warn/err + litellm_*_curl + the reconcile primitives + scoped_key_registry

# ---------------------------------------------------------------------------
# (b0) OFFLINE — the opt-in scoped-key registry is complete + sane.
# ---------------------------------------------------------------------------
echo "== (b0) scoped_key_registry: 7 consumers, each valid-JSON incl. 'local' (offline) =="
if declare -F scoped_key_registry >/dev/null 2>&1; then
  reg_rows="$(scoped_key_registry | grep -c '|')"
  [[ "$reg_rows" == "7" ]] && t_ok "registry has 7 rows" || t_bad "registry has $reg_rows rows (expected 7)"
  b0=0
  while IFS='|' read -r ke al ow mj; do
    [[ -z "$ke" ]] && continue
    if ! printf '%s' "$mj" | python3 -c 'import sys,json
try: m=json.load(sys.stdin)
except Exception: sys.exit(2)
sys.exit(0 if (isinstance(m,list) and "local" in m) else 1)' 2>/dev/null; then
      t_bad "registry row $ke has bad JSON or is missing 'local': $mj"; b0=1
    fi
  done < <(scoped_key_registry)
  (( b0 == 0 )) && t_ok "every registry row is valid JSON and includes 'local'"
else
  t_bad "scoped_key_registry is not defined (the item-2 registry did not land)"
fi

# ---------------------------------------------------------------------------
# (b0.x) OFFLINE — the load-bearing invariant: each registry MODELS_JSON EQUALS its
# phase's /key/generate mint list (as a set). If they diverge, `model sync` P3b (which
# converges the key EXACT to the registry) and `install <phase>` (which mints the phase
# list) would flip-flop the live key's allow-list every run — re-introducing the exact
# silent-drift class this PR kills, one layer up. Pure-offline (grep + json).
# ---------------------------------------------------------------------------
echo "== (b0.x) each registry row set-equals its phase's /key/generate mint list (offline) =="
declare -A PHASE_OF=(
  [METAGPT_LITELLM_KEY]="installer/phases/32_metagpt.sh"
  [AGENTSCOPE_LITELLM_KEY]="installer/phases/33_agentscope.sh"
  [OASIS_LITELLM_KEY]="installer/phases/34_oasis.sh"
  [CHATDEV_LITELLM_KEY]="installer/phases/35_chatdev.sh"
  [AITOWN_LITELLM_KEY]="installer/phases/36_aitown.sh"
  [CONCORDIA_LITELLM_KEY]="installer/phases/37_concordia.sh"
  [OPENWORK_LITELLM_KEY]="installer/phases/29_openwork.sh"
)
parity=0
for ke in METAGPT_LITELLM_KEY AGENTSCOPE_LITELLM_KEY OASIS_LITELLM_KEY CHATDEV_LITELLM_KEY AITOWN_LITELLM_KEY CONCORDIA_LITELLM_KEY OPENWORK_LITELLM_KEY; do
  reg="$(scoped_key_registry_models "$ke")"
  res="$(python3 - "$reg" "$AI_STACK/${PHASE_OF[$ke]}" <<'PY'
import json, os, re, sys
try:
    reg = set(json.loads(sys.argv[1]))
except Exception:
    print("BAD_REGISTRY_JSON"); sys.exit(0)
txt = open(sys.argv[2], encoding="utf-8").read()
# openwork declares OPENWORK_KEY_MODELS='[...]'; the other 6 use a "models":[...] literal
# in their /key/generate body (36_aitown builds it inside a python json.dumps, same shape).
m = re.search(r"OPENWORK_KEY_MODELS='(\[[^\]]*\])'", txt) or re.search(r'"models":\s*(\[[^\]]*\])', txt)
if not m:
    print("PARSE_FAIL"); sys.exit(0)
try:
    ph = set(json.loads(m.group(1)))
except Exception:
    print("BAD_PHASE_JSON"); sys.exit(0)
print("EQUAL" if ph == reg else "MISMATCH registry=%s phase=%s" % (sorted(reg), sorted(ph)))
PY
)"
  [[ "$res" == "EQUAL" ]] || { t_bad "registry($ke) != mint list (${PHASE_OF[$ke]}): $res"; parity=1; }
done
(( parity == 0 )) && t_ok "all 7 registry rows set-equal their phase's /key/generate mint list"

# ---------------------------------------------------------------------------
# (b1) OFFLINE denylist — removed slugs must not linger in any rendered artifact.
# Word-bounded so local-lfm2 does NOT match local-lfm2-mlx, and local-nemotron3-heavy
# does NOT match local-nemotron3-nano-4b.
# ---------------------------------------------------------------------------
REMOVED_RE='(^|:-|[^A-Za-z0-9_-])(local-gemma4|local-gemma4-12b|local-lfm2|local-nemotron3-heavy|local-qwen-heavy-fast|local-qwen3)([^A-Za-z0-9_-]|$)'
echo "== (b1) no rendered artifact references a ca08cc1-removed slug (offline) =="
arts=("$AI_STACK/deer-flow/config.yaml")
while IFS= read -r f; do [[ -n "$f" ]] && arts+=("$f"); done < <(find "$AI_STACK/bin" -maxdepth 1 -type f 2>/dev/null)
while IFS= read -r f; do [[ -n "$f" ]] && arts+=("$f"); done < <(find "$AI_STACK" -maxdepth 3 -name opencode.json 2>/dev/null | grep -vE '/\.git/|/node_modules/')
b1=0
for f in "${arts[@]:-}"; do
  [[ -f "$f" ]] || continue
  matches="$(grep -nE "$REMOVED_RE" "$f" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    b1=1
    while IFS= read -r ln; do t_bad "removed slug in ${f#$AI_STACK/}: ${ln}"; done <<< "$matches"
  fi
done
(( b1 == 0 )) && t_ok "no removed slug across ${#arts[@]} rendered artifact path(s)"

# ---------------------------------------------------------------------------
# Live setup — resolve master + routable catalog. Skip-clean if unavailable.
# ---------------------------------------------------------------------------
scoped_models(){ # $1=scoped key -> sorted CSV of ids from /v1/models under that key
  litellm_scoped_curl "$1" -s --max-time 5 "$LITELLM/v1/models" 2>/dev/null \
    | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(",".join(sorted(m.get("id") for m in d.get("data",[]) if m.get("id"))))' 2>/dev/null || true
}
wait_scoped(){ # $1=key $2=want_csv -> echo final got_csv, waiting up to ~5s for the key cache
  local key="$1" want="$2" got="" i
  for i in 1 2 3 4 5; do
    got="$(scoped_models "$key")"
    [[ "$got" == "$want" ]] && { printf '%s' "$got"; return 0; }
    sleep 1
  done
  printf '%s' "$got"
}

TMP=""; CLEAN_KEY=""
cleanup(){
  # Delete the throwaway key by value — key-bearing body via a 0600 temp file + --data @file
  # so the scoped key never lands in curl argv (mirrors litellm_reconcile_key_exact's discipline).
  if [[ -n "$CLEAN_KEY" ]]; then
    local _df; _df="$(mktemp 2>/dev/null)" || _df=""
    if [[ -n "$_df" ]]; then
      printf '{"keys":["%s"]}' "$CLEAN_KEY" > "$_df"
      litellm_master_curl -s --max-time 10 -H 'Content-Type: application/json' \
        -X POST "$LITELLM/key/delete" --data @"$_df" >/dev/null 2>&1 || true
      rm -f "$_df"
    fi
  fi
  [[ -n "$TMP" ]] && rm -rf "$TMP"
  return 0
}
trap cleanup EXIT INT TERM

MASTER="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$MASTER" ]] || skip "LITELLM_MASTER_KEY unset in .env — cannot exercise control-plane key ops"

models_json="$(litellm_master_curl -s --max-time 5 "$LITELLM/v1/models" 2>/dev/null || true)"
mapfile -t R < <(printf '%s' "$models_json" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(sorted({m.get("id") for m in d.get("data",[]) if m.get("id")})))' 2>/dev/null || true)
[[ ${#R[@]} -ge 1 ]] || skip "LiteLLM $LITELLM unreachable or served no models — live checks skipped"
[[ ${#R[@]} -ge 3 ]] || skip "routable catalog has only ${#R[@]} model(s); need >=3 to build an extra+missing key"

# ---------------------------------------------------------------------------
# (b2) LIVE — the deer-flow picker pins only routable local-family slugs.
# ---------------------------------------------------------------------------
echo "== (b2) deer-flow picker local-family slugs are all routable (live) =="
picker="$AI_STACK/deer-flow/config.yaml"
if [[ -f "$picker" ]]; then
  mapfile -t pslugs < <(python3 - "$picker" <<'PY'
import sys, re
txt = open(sys.argv[1], encoding="utf-8").read()
b = txt.find("ai-stack: local models via LiteLLM")   # first hit = BEGIN marker line
be = txt.find("BEGIN", b) if b >= 0 else -1
en = txt.find("END", be + 5) if be >= 0 else -1     # next "END" = the picker END marker
seg = txt[be:en] if (be >= 0 and en >= 0) else ""
out = []
for m in re.finditer(r'(?m)^\s*model:\s*(\S+)\s*$', seg):
    s = m.group(1).strip().strip('"').strip("'")
    if s.startswith("local"):
        out.append(s)
print("\n".join(sorted(set(out))))
PY
)
  miss=0
  for s in "${pslugs[@]:-}"; do
    [[ -z "$s" ]] && continue
    if printf '%s\n' "${R[@]}" | grep -qxF "$s"; then :; else
      t_bad "picker pins local slug '$s' ABSENT from routable /v1/models (catalog-removal drift)"; miss=1
    fi
  done
  (( miss == 0 )) && t_ok "all ${#pslugs[@]} local-family picker slug(s) are routable"
else
  echo "  [skip] $picker absent"
fi

# ---------------------------------------------------------------------------
# (a) LIVE, OOM-SAFE — reconcile converges a scoped key to EXACTLY the intended set.
# ---------------------------------------------------------------------------
echo "== (a) $RECONCILE_FN converges a scoped key to EXACTLY the intended set (live, OOM-safe) =="
A="${R[0]}"; B="${R[1]}"; C="${R[2]}"   # A,B = intended; C = stale EXTRA (all routable)

TMP="$(mktemp -d)"
export ENV_FILE="$TMP/.env"; : > "$ENV_FILE"; chmod 600 "$ENV_FILE"
set_env LITELLM_MASTER_KEY "$MASTER" >/dev/null 2>&1 || skip "could not stage temp env (set_env failed)"

gen="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
  -X POST "$LITELLM/key/generate" \
  -d "{\"models\":[\"$A\",\"$C\"],\"metadata\":{\"owner\":\"scoped-key-catalog-reconcile-test\",\"purpose\":\"regression-test\"}}" 2>/dev/null || true)"
CLEAN_KEY="$(printf '%s' "$gen" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("key",""))
except Exception: pass' 2>/dev/null || true)"
[[ -n "$CLEAN_KEY" ]] || skip "could not mint a throwaway key (LiteLLM virtual keys need DATABASE_URL) — live reconcile check skipped"
set_env SCOPED_KEY_RECONCILE_TEST_KEY "$CLEAN_KEY" >/dev/null 2>&1 || skip "could not stage throwaway key into temp env"

want0="$(printf '%s\n%s\n' "$A" "$C" | LC_ALL=C sort -u | paste -sd, -)"
got0="$(wait_scoped "$CLEAN_KEY" "$want0")"
[[ "$got0" == "$want0" ]] || skip "throwaway key initial /v1/models='$got0' != '$want0' (LiteLLM did not honor the mint allowlist) — env mismatch"
t_ok "throwaway key starts drifted: /v1/models='$got0' (has stale extra '$C', missing intended '$B')"

"$RECONCILE_FN" SCOPED_KEY_RECONCILE_TEST_KEY "$A" "$B" >/dev/null 2>&1 || true

want1="$(printf '%s\n%s\n' "$A" "$B" | LC_ALL=C sort -u | paste -sd, -)"
got1="$(wait_scoped "$CLEAN_KEY" "$want1")"
if [[ "$got1" == "$want1" ]]; then
  t_ok "reconcile converged the key to EXACTLY {$want1} (stale '$C' dropped, missing '$B' added)"
else
  t_bad "reconcile did NOT converge: /v1/models='$got1' (want '$want1') — a WIDEN-only key primitive leaves the stale extra '$C' in place, so a catalog REMOVAL never self-heals (the ca08cc1 drift)"
fi

echo
echo "RESULT: $TPASS passed, $TFAIL failed"
(( TFAIL == 0 ))
