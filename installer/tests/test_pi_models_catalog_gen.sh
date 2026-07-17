#!/usr/bin/env bash
# test_pi_models_catalog_gen.sh — regression guard for Pi's model-catalog generator
# (phase 15). Pi's `openai` provider ships NO models[], so `pi --model <litellm route>`
# fails a CLIENT-SIDE lookup ("Model not found") until ~/.pi/agent/models.json lists the
# route. Phase 15 renders that catalog via common.sh::pi_render_models_json from the
# models.yml FLEET SUPERSET (`(["local","local-heavy"] + (.models | keys)) | unique`).
#
# WHY the superset and not the live pi-key allowlist: phase 15 runs BEFORE phase 04h widens
# the pi key, so at generate-time the key is still the narrow 2-model mint — a catalog built
# from it would OMIT the shipped default and Pi would break on a FRESH install (it only
# "worked" on a box whose .env carried a prior 04h-widened key). The superset is
# timing-independent + a strict superset of anything the key will ever allow. This test pins:
#
#   (o1) OFFLINE: N crafted ids -> valid JSON, exactly N {id,name} entries, provider `openai`,
#        correct baseUrl/api, and the literal "$PI_LITELLM_KEY" placeholder preserved.
#   (o2) OFFLINE: adversarial ids (empty / quote / space / leading tab) -> still valid JSON,
#        never aborts under `set -Eeuo pipefail`, no shell injection.
#   (o3) OFFLINE: the real models.yml superset -> includes the pi-assigned model (the exact
#        resolvability the phase-15 precheck now asserts), so a fresh install cannot ship a
#        catalog missing the default. Discriminates the bug: a key-allowlist source at
#        phase-15 time would be the narrow 2-model set and FAIL this.
#
# Sources ONLY common.sh + env.sh (NOT models.sh, which runs `main "$@"` at source time).
# No network, no sandbox, no chat completion -> no local model load (24GB OOM safe).
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export AI_STACK
# shellcheck disable=SC1091
source "$AI_STACK/installer/lib/common.sh"
MODELS_YML="$AI_STACK/installer/models.yml"
BASE="http://host.docker.internal:4000/v1"

pass=0; fail=0
t_ok()  { pass=$((pass+1)); echo "  ok   — $1"; }
t_bad() { fail=$((fail+1)); echo "  FAIL — $1"; }

# --- (o1) N crafted ids -> valid JSON, exactly N entries, correct shape ---------
echo "(o1) render N ids -> valid catalog"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "local" "claude-opus-sub-max" "openai-gpt-sub" \
  | pi_render_models_json "$TMP/o1.json" "$BASE"
if python3 - "$TMP/o1.json" "$BASE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); base = sys.argv[2]
p = d["providers"]["openai"]
assert list(d["providers"]) == ["openai"], "provider name"
assert p["baseUrl"] == base, "baseUrl"
assert p["api"] == "openai-completions", "api"
assert p["apiKey"] == "$PI_LITELLM_KEY", "apiKey placeholder preserved (bin/pi expands it)"
ids = [m["id"] for m in p["models"]]
assert ids == ["local", "claude-opus-sub-max", "openai-gpt-sub"], ids
assert all(set(m) == {"id", "name"} and m["id"] == m["name"] for m in p["models"]), "minimal {id,name}"
PY
then t_ok "3 ids -> 3 {id,name}, provider=openai, baseUrl/api/apiKey correct"
else t_bad "o1 structure assertion"; fi

# --- (o2) adversarial ids: valid JSON, no abort, no injection -------------------
echo "(o2) adversarial ids -> still valid JSON, no abort"
# empty input -> empty models[] (the phase guards this with a PI_DEFAULT floor; the renderer
# itself must still emit valid JSON, not crash).
if printf '' | pi_render_models_json "$TMP/o2empty.json" "$BASE" \
   && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["providers"]["openai"]["models"]==[]' "$TMP/o2empty.json"; then
  t_ok "empty input -> valid JSON, models: []"
else t_bad "o2 empty input"; fi
# id with a double-quote + space + leading tab -> json.dumps escapes; no shell injection.
if printf '%s\n' 'weird"id with space' $'\tleading-tab' 'local' \
     | pi_render_models_json "$TMP/o2meta.json" "$BASE" \
   && python3 - "$TMP/o2meta.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))  # parses => quote correctly escaped
ids = [m["id"] for m in d["providers"]["openai"]["models"]]
assert 'weird"id with space' in ids, ids       # quote/space survive as ONE id
assert 'leading-tab' in ids, ids               # x.strip() drops the leading tab
assert 'local' in ids, ids
PY
then t_ok "quote/space/tab ids -> valid escaped JSON, no injection"
else t_bad "o2 metachar ids"; fi

# --- (o3) real models.yml superset includes the pi-assigned model ---------------
echo "(o3) real superset -> pi's bound model resolvable"
if [[ -f "$MODELS_YML" ]] && command -v yq >/dev/null 2>&1; then
  want="$(yq -r '.assignments.pi // .default // "local"' "$MODELS_YML" 2>/dev/null || echo local)"
  [[ -n "$want" && "$want" != "null" ]] || want="local"
  yq -r '(["local","local-heavy"] + (.models | keys)) | unique | .[]' "$MODELS_YML" 2>/dev/null \
    | pi_render_models_json "$TMP/o3.json" "$BASE"
  if python3 - "$TMP/o3.json" "$want" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
ids = [m["id"] for m in d["providers"]["openai"]["models"]]
assert want in ids, "pi bound model %r absent from catalog: %r" % (want, ids)
assert "local" in ids, "local floor missing"
assert len(ids) >= 3, "superset unexpectedly small: %r" % ids
PY
  then t_ok "superset catalog contains pi's bound model '$want' (+ local, >=3 total)"
  else t_bad "o3 superset missing bound model"; fi
else
  echo "  skip — models.yml or yq unavailable"
fi

echo ""
echo "== pi_models_catalog_gen: $pass passed, $fail failed =="
[[ "$fail" -eq 0 ]]
