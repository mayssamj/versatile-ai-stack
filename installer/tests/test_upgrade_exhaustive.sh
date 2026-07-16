#!/usr/bin/env bash
# test_upgrade_exhaustive.sh — `upgrade all` must be EXHAUSTIVE: every enabled
# service resolves to a REAL upgrade action, never the no-op "manual note" that
# up_manual_note used to print (operator directive 2026-07-01). Pure-STATIC check:
# mirrors upgrade.sh's dispatch (type → handler; manual-types → up_by_method →
# `upgrade:` block method, else phase-rerun if a phase exists) against services.yml.
# No docker/openshell/network — safe in CI. Also asserts the host-global coverage
# (meridian/claude-code/codex) and the declared `upgrade:` blocks parse to valid methods.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SVC="$ROOT/services.yml"
UPG="$ROOT/installer/lib/upgrade.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v yq >/dev/null 2>&1 || { echo "yq not on PATH — skipping (not a failure)"; exit 0; }

# Handler-backed types (docker/compose/brew/openshell) always do real work.
REAL_TYPES=" docker compose docker-compose brew-service openshell hermes-profiles sandbox-daemon "
# Manual-dispatch types: routed to up_by_method (upgrade-block method OR phase-rerun).
MANUAL_TYPES=" cli-only clone-only npm-global pip-package litellm-feature agent-pattern paperclip-plugin litellm-virtual-key python-bg node-bg "

echo "== every enabled service resolves to a NON-manual upgrade strategy =="
mapfile -t svcs < <(yq -r '.services | to_entries | .[] | select(.value.enabled == true) | .key' "$SVC")
gap=0
for s in "${svcs[@]}"; do
  t="$(yq -r ".services.\"$s\".type // \"unknown\"" "$SVC")"
  if [[ "$REAL_TYPES" == *" $t "* ]]; then continue; fi
  if [[ "$MANUAL_TYPES" == *" $t "* ]]; then
    has_up="$(yq -r ".services.\"$s\".upgrade // \"-\"" "$SVC")"
    phase="$(yq -r ".services.\"$s\".phase // \"-\"" "$SVC")"
    if [[ "$has_up" != "-" || "$phase" != "-" ]]; then continue; fi
    bad "$s ($t): no upgrade: block AND no phase → would hit the manual no-op"; gap=1
  else
    bad "$s: unknown type '$t' → upgrade would skip it"; gap=1
  fi
done
(( gap == 0 )) && ok "all ${#svcs[@]} enabled services map to a real upgrade action (method or phase-rerun)"

echo "== every sandbox-based service (openshell/hermes-profiles/sandbox-daemon) declares a 'sandbox:' =="
# up_openshell runs the in-sandbox pip bump via `openshell sandbox exec -n "$(svc_sandbox)"`.
# A missing sandbox: → svc_sandbox returns "-" → `exec -n "-"` → cryptic "sandbox not found"
# that misreads as a PyPI 403 (the hermes_fleet 0.16→0.18 upgrade bug). Assert it's present.
sb_gap=0
for s in "${svcs[@]}"; do
  t="$(yq -r ".services.\"$s\".type // \"unknown\"" "$SVC")"
  case "$t" in openshell|hermes-profiles|sandbox-daemon) ;; *) continue ;; esac
  sb="$(yq -r ".services.\"$s\".sandbox // \"-\"" "$SVC")"
  [[ -n "$sb" && "$sb" != "-" ]] || { bad "$s ($t): no 'sandbox:' → upgrade's in-sandbox exec fails 'sandbox not found'"; sb_gap=1; }
done
(( sb_gap == 0 )) && ok "all sandbox-based services declare a 'sandbox:' field"
# no two-sources-of-truth drift: 04f hardcodes SANDBOX=hermes-fleet-v1 while `upgrade` reads
# svc_sandbox(services.yml). They must agree, or install and upgrade target different sandboxes.
_svc_sb="$(yq -r '.services.hermes_fleet.sandbox // "-"' "$SVC")"
_04f_sb="$(sed -n 's/^SANDBOX=//p' "$ROOT/installer/phases/04f_hermes_fleet.sh" | head -1)"
[[ -n "$_svc_sb" && "$_svc_sb" != "-" && "$_svc_sb" == "$_04f_sb" ]] && ok "services.yml hermes_fleet.sandbox ($_svc_sb) == 04f SANDBOX literal — no drift" || bad "sandbox name drift: services.yml=[$_svc_sb] vs 04f SANDBOX=[$_04f_sb]"

echo "== every manual-typed service WITHOUT an upgrade: block has a RESOLVABLE phase script =="
# Guards the silent hole the first loop can't see: a `phase:` that points to a
# NON-existent installer/phases/<id>_*.sh → up_phase_rerun degrades to the no-op
# up_manual_note. (Static mirror of resolve_phase_script_inline's glob.)
presolve_gap=0
for s in "${svcs[@]}"; do
  t="$(yq -r ".services.\"$s\".type // \"unknown\"" "$SVC")"
  [[ "$MANUAL_TYPES" == *" $t "* ]] || continue
  [[ "$(yq -r ".services.\"$s\".upgrade // \"-\"" "$SVC")" != "-" ]] && continue  # has a direct method
  ph="$(yq -r ".services.\"$s\".phase // \"-\"" "$SVC")"
  [[ "$ph" == "-" ]] && continue  # no phase → caught by the first loop already
  m=( "$ROOT/installer/phases/${ph}_"*.sh )
  [[ -e "${m[0]}" ]] || { bad "$s: phase '$ph' resolves to NO installer/phases/${ph}_*.sh → phase-rerun would silent-no-op"; presolve_gap=1; }
done
(( presolve_gap == 0 )) && ok "every phase-rerun service resolves to exactly one phase script"

echo "== declared upgrade: blocks parse to a supported method =="
# v2 (2026-07-15 coverage broadening): uv-tool (mempalace/halo), sandbox-pip
# (hermes_fleet — oracle + delegate-to-up_openshell), none (config-only marker /
# pin-only holds), and '-' (a metadata-only block: deerflow carries compose
# check_env with NO method — the TYPE handler stays in charge by design).
# v3 (2026-07-16 follow-ups): uv-reqs (docs_mcp — requirements-scoped venv
# oracle+handler) and brew (blaxel_cli/openshell — formula-aware, openshell
# chains the phase-04 gateway re-assert).
VALID=" npm-global uv-venv git-pull rebuild phase-rerun uv-tool sandbox-pip uv-reqs brew none - "
mapfile -t withup < <(yq -r '.services | to_entries | .[] | select(.value.upgrade) | .key' "$SVC")
for s in "${withup[@]}"; do
  m="$(yq -r ".services.\"$s\".upgrade.method // \"-\"" "$SVC")"
  if [[ "$VALID" == *" $m "* ]]; then ok "$s → upgrade.method=$m (supported)"; else bad "$s → upgrade.method='$m' not supported"; fi
done
# The three we ship must be present + correct.
[[ "$(yq -r '.services.byterover_cli.upgrade.method' "$SVC")" == "npm-global" ]] && ok "byterover_cli → npm-global" || bad "byterover_cli upgrade block wrong"
[[ "$(yq -r '.services.remnic_hermes.upgrade.method' "$SVC")" == "uv-venv" ]] && ok "remnic_hermes → uv-venv" || bad "remnic_hermes upgrade block wrong"
[[ "$(yq -r '.services.autoreason.upgrade.method' "$SVC")" == "git-pull" ]] && ok "autoreason → git-pull" || bad "autoreason upgrade block wrong"

echo "== host npm globals (not services.yml) are covered by upgrade all =="
grep -q 'HOST_NPM_GLOBALS=(' "$UPG" && ok "HOST_NPM_GLOBALS defined in upgrade.sh" || bad "HOST_NPM_GLOBALS missing"
grep -q '@rynfar/meridian' "$UPG" && ok "meridian (@rynfar/meridian) covered" || bad "meridian not covered"
grep -q '@anthropic-ai/claude-code' "$UPG" && ok "claude-code (@anthropic-ai/claude-code) covered" || bad "claude-code not covered"
grep -qE 'hg_targets=\(meridian claude-code codex\)' "$UPG" && ok "bare 'upgrade all' includes host globals" || bad "'upgrade all' does not add host globals"

echo "== up_by_method dispatch + no silent manual fallthrough in upgrade_one =="
grep -q 'up_by_method' "$UPG" && ok "up_by_method present" || bad "up_by_method missing"
# The manual-type case arms must route to up_by_method (the case pattern + its
# body are on separate lines, so match the pattern line + the following line).
if grep -A1 -E 'cli-only\|clone-only\|npm-global\|pip-package' "$UPG" | grep -q 'up_by_method'; then
  ok "manual-type dispatch routes to up_by_method"
else bad "manual-type dispatch still routes to up_manual_note"; fi
# up_manual_note must survive ONLY as the last-resort fallback (called from up_phase_rerun).
if grep -q 'up_manual_note "\$svc"; return 0' "$UPG"; then
  ok "up_manual_note retained only as the phase-rerun last-resort fallback"
else bad "up_manual_note no longer reachable as a safe fallback"; fi

echo "== 'upgrade hermes' group alias + workspace phase-rerun routing =="
# collect_targets must expand the 'hermes' group DATA-DRIVEN from services.yml group:hermes tags.
grep -q 'select(.value.group == "hermes")' "$UPG" \
  && ok "collect_targets expands the 'hermes' group data-driven (group:hermes tag, no hardcoded list)" \
  || bad "collect_targets 'hermes' group is not data-driven"
# drift guard: all 4 surfaces carry the tag (add a hermes surface with group:hermes → it auto-joins).
_hg="$(yq -r '.services | to_entries | .[] | select(.value.group == "hermes") | .key' "$SVC" | tr '\n' ' ')"
[[ "$_hg" == *hermes_fleet* && "$_hg" == *hermes_workspace* && "$_hg" == *hermes_telegram* && "$_hg" == *hermes_slack* ]] \
  && ok "group:hermes tags cover all 4 surfaces ($_hg)" \
  || bad "group:hermes tags miss a surface (got: $_hg)"
# the mutate path must ALSO accept 'hermes' (not error 'Unknown service').
grep -q 'collect_targets targets hermes' "$UPG" \
  && ok "mutate path resolves the 'hermes' group (not 'Unknown service')" \
  || bad "mutate path would reject 'upgrade hermes' as Unknown service"
# hermes_workspace (compose) overrides its type default with a phase-rerun so `upgrade`
# re-resolves the LATEST agent image instead of blind-pulling the frozen pin.
[[ "$(yq -r '.services.hermes_workspace.upgrade.method // "-"' "$SVC")" == "phase-rerun" ]] \
  && ok "hermes_workspace declares upgrade.method=phase-rerun (re-resolve latest, not blind pull)" \
  || bad "hermes_workspace missing upgrade.method=phase-rerun → upgrade would blind-pull the frozen pin"
# upgrade_one must honor that override — v2: via dispatch_upgrade, whose real-method
# arm routes to up_by_method BEFORE the type case (metadata-only blocks fall through).
grep -q 'dispatch_upgrade "$svc" "$type" "$_method"' "$UPG" \
  && ok "upgrade_one routes through the method-aware dispatcher" \
  || bad "upgrade_one no longer calls dispatch_upgrade (explicit blocks may be ignored)"
grep -qE 'npm-global\|uv-venv\|git-pull\|uv-tool\|uv-reqs\|sandbox-pip\|brew\|rebuild\|phase-rerun\|none\)' "$UPG" \
  && ok "dispatcher's real-method arm covers phase-rerun (hermes_workspace stays overridden)" \
  || bad "dispatcher method list lost phase-rerun (hermes_workspace would hit up_compose)"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
