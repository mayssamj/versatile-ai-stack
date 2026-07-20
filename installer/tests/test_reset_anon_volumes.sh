#!/usr/bin/env bash
# test_reset_anon_volumes.sh — anonymous-volume hygiene (§24 2026-07-20), OFFLINE.
# Drives the REAL docker_anon_orphans (docker.sh) + _sweep_run_orphaned_anon_volumes
# (reset.sh) with a recording docker() stub — no live engine. Also statically pins
# `docker rm -fv` at every audited sink so the leak can't silently reopen.
set -uo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "FAIL: this suite needs bash >= 4 (got $BASH_VERSION)"; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DK="$HERE/../lib/docker.sh"; RS="$HERE/../lib/reset.sh"; GC="$HERE/../lib/gc.sh"
CU="$HERE/../lib/cleanup.sh"; CD="$HERE/../../bin/start-chatdev.sh"
CK="$HERE/../doctor/checks/82_anon_volume_orphans.sh"
PASS=0; FAIL=0; t_ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; t_bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== static: every audited rm sink passes -fv; wiring present =="
grep -q 'docker rm -fv "\$c"' "$RS"        && t_ok "reset managed sweep uses -fv"          || t_bad "reset managed sweep lost -fv"
grep -q 'docker rm -fv \$ids' "$RS"        && t_ok "reset compose sweep uses -fv"          || t_bad "reset compose sweep lost -fv"
grep -q 'honcho hermes-workspace autofyn deer-flow aitown' "$RS" && t_ok "aitown in the compose teardown list" || t_bad "aitown missing from teardown list"
grep -q '_sweep_run_orphaned_anon_volumes' "$RS" && t_ok "diff-scoped sweep wired in reset" || t_bad "diff-scoped sweep not wired"
grep -c '_sweep_run_orphaned_anon_volumes$' "$RS" >/dev/null || true
grep -q 'docker rm -fv "\$name"' "$DK"     && t_ok "recreate_guard uses -fv"               || t_bad "recreate_guard lost -fv"
grep -q 'docker rm -fv "\$c"' "$GC"        && t_ok "gc reaper uses -fv"                    || t_bad "gc reaper lost -fv"
[[ "$(grep -c 'docker rm -fv' "$CD")" -ge 2 ]] && t_ok "chatdev uninstall+recreate use -fv" || t_bad "chatdev rm sites lost -fv"
grep -q '_cleanup_anon_volumes delete' "$CU" && grep -q '_cleanup_anon_volumes dry' "$CU" \
  && t_ok "cleanup wires volume path in BOTH --yes and dry-run branches" || t_bad "cleanup volume path not in both branches"
grep -q '\[skip\]' "$CK" && grep -q 'return 0' "$CK" && t_ok "check 82 skip-cleans on docker-down" || t_bad "check 82 missing docker-down skip"
grep -Eq 'anonymous volumes orphaned BY THIS RESET' "$RS" && t_ok "blast radius discloses the diff-scoped sweep" || t_bad "blast radius missing anon-volume disclosure"

echo "== behavioral: REAL functions under a recording docker() stub =="
TMP="$(mktemp -d)"; CALLS="$TMP/calls.log"; : > "$CALLS"
trap 'rm -rf "$TMP"' EXIT
# Extract the shipped functions (no hand copies).
eval "$(sed -n '/^docker_anon_orphans() {/,/^}/p' "$DK")"
eval "$(sed -n '/^_sweep_run_orphaned_anon_volumes() {/,/^}/p' "$RS")"
declare -F docker_anon_orphans >/dev/null || { t_bad "could not extract docker_anon_orphans"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; exit 1; }
declare -F _sweep_run_orphaned_anon_volumes >/dev/null || { t_bad "could not extract _sweep_run_orphaned_anon_volumes"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; exit 1; }
ok(){ :; }; warn(){ :; }; log(){ :; }; note(){ :; }
AI_STACK="$TMP"; RESET_TS="testts"
docker() {
  echo "docker $*" >> "$CALLS"
  case "${1:-} ${2:-}" in
    "volume ls")
      local x; for x in ${LS_OUT:-}; do echo "$x"; done; return 0 ;;
    "volume rm")
      return "${RM_RC:-0}" ;;
    "run --rm")
      # the backup leg: honor BACKUP_OK; on success create the tgz the verb -s tests
      if [[ "${BACKUP_OK:-1}" == "1" ]]; then
        local a host="" tgz=""
        for a in "$@"; do
          [[ "$a" == *:/out ]] && host="${a%:/out}"
          [[ "$a" == /out/*.tgz ]] && tgz="${a##*/}"
        done
        [[ -n "$host" && -n "$tgz" ]] && { mkdir -p "$host"; echo backup > "$host/$tgz"; }
        return 0
      fi
      return 1 ;;
    *) return 0 ;;
  esac
}

# (1) list passes the filtered enumeration through untouched
LS_OUT="volA volB"; got="$(docker_anon_orphans list | tr '\n' ' ')"
[[ "$got" == "volA volB " ]] && t_ok "list: passthrough of the dangling-anon enumeration" || t_bad "list wrong: '$got'"
grep -q 'filter dangling=true' "$CALLS" && grep -q 'label=com.docker.volume.anonymous' "$CALLS" \
  && t_ok "list: uses BOTH dangling+anonymous filters" || t_bad "list: filters missing"

# (2) remove: backup-first then rm; explicit names only
: > "$CALLS"; LS_OUT=""
docker_anon_orphans remove "$TMP/bak" volA volB; rc=$?
[[ $rc -eq 0 ]] && t_ok "remove: rc 0 when all backed up + removed" || t_bad "remove rc=$rc"
[[ "$(grep -c '^docker volume rm ' "$CALLS")" == "2" ]] && t_ok "remove: exactly the 2 named volumes removed" || t_bad "remove: wrong rm count"
[[ -s "$TMP/bak/volA.tgz" && -s "$TMP/bak/volB.tgz" ]] && t_ok "remove: tar backup exists per volume" || t_bad "remove: backups missing"

# (3) fail-closed: backup failure KEEPS the volume (no rm), rc 1; FORCE_WIPE overrides
: > "$CALLS"; BACKUP_OK=0
docker_anon_orphans remove "$TMP/bak2" volC; rc=$?
[[ $rc -eq 1 ]] && ! grep -q '^docker volume rm volC' "$CALLS" \
  && t_ok "remove: backup failure -> volume KEPT (fail-closed, rc 1)" || t_bad "remove: fail-closed broken (rc=$rc)"
: > "$CALLS"
AI_STACK_FORCE_WIPE=1 docker_anon_orphans remove "$TMP/bak2" volC >/dev/null 2>&1 || true
grep -q '^docker volume rm volC' "$CALLS" && t_ok "remove: AI_STACK_FORCE_WIPE=1 overrides a failed backup" || t_bad "FORCE_WIPE override broken"
BACKUP_OK=1

# (4) diff-scope: removes ONLY volumes not in the entry snapshot
: > "$CALLS"; _ANON_BEFORE="volA volB "; LS_OUT="volA volB volC volD"
_sweep_run_orphaned_anon_volumes
rms="$(awk '/^docker volume rm /{print $4}' "$CALLS" | sort | tr '\n' ' ')"
[[ "$rms" == "volC volD " ]] && t_ok "diff-scope: removed EXACTLY the run-orphaned set (volC volD)" || t_bad "diff-scope removed: '$rms'"
grep -q '^docker volume rm volA' "$CALLS" && t_bad "diff-scope touched a PRE-EXISTING orphan" || t_ok "diff-scope: pre-existing orphans untouched"

# (5) diff-scope no-op: nothing new -> zero removals
: > "$CALLS"; _ANON_BEFORE="volA volB "; LS_OUT="volA volB"
_sweep_run_orphaned_anon_volumes
grep -q '^docker volume rm ' "$CALLS" && t_bad "no-op sweep still removed something" || t_ok "diff-scope: no new orphans -> zero removals"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
