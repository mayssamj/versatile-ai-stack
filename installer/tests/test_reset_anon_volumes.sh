#!/usr/bin/env bash
# test_reset_anon_volumes.sh — anonymous-volume hygiene (§24 2026-07-20), OFFLINE.
# Drives the REAL docker_anon_orphans (docker.sh), _sweep_run_orphaned_anon_volumes
# (reset.sh) and _cleanup_anon_volumes (cleanup.sh) with a recording docker() stub —
# no live engine. Also statically pins `docker rm -fv` at every audited sink so the
# leak can't silently reopen.
set -uo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "FAIL: this suite needs bash >= 4 (got $BASH_VERSION)"; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DK="$HERE/../lib/docker.sh"; RS="$HERE/../lib/reset.sh"; GC="$HERE/../lib/gc.sh"
CU="$HERE/../lib/cleanup.sh"; AD="$HERE/../lib/adopt.sh"
CD="$HERE/../../bin/start-chatdev.sh"; AT="$HERE/../../bin/start-aitown.sh"
CK="$HERE/../doctor/checks/82_anon_volume_orphans.sh"
PASS=0; FAIL=0; t_ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; t_bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== static: every audited rm sink passes -fv; wiring present =="
grep -q 'docker rm -fv "\$c"' "$RS"        && t_ok "reset managed sweep uses -fv"          || t_bad "reset managed sweep lost -fv"
grep -q 'docker rm -fv \$ids' "$RS"        && t_ok "reset compose sweep uses -fv"          || t_bad "reset compose sweep lost -fv"
grep -q 'honcho hermes-workspace autofyn deer-flow aitown' "$RS" && t_ok "aitown in the compose teardown list" || t_bad "aitown missing from teardown list"
[[ "$(grep -c '^    _sweep_run_orphaned_anon_volumes$' "$RS")" -ge 2 ]] && t_ok "diff-scoped sweep wired in BOTH hard and nuke tiers" || t_bad "sweep not wired in both tiers"
grep -q '_ANON_SNAPSHOT_OK' "$RS"          && t_ok "fail-closed snapshot flag wired"       || t_bad "snapshot fail-closed flag missing"
grep -q 'docker rm -fv "\$name"' "$DK"     && t_ok "recreate_guard uses -fv"               || t_bad "recreate_guard lost -fv"
grep -q 'docker rm -fv "\$c"' "$GC"        && t_ok "gc reaper uses -fv"                    || t_bad "gc reaper lost -fv"
grep -q 'docker rm -fv "\$SVC"' "$AD"      && t_ok "adopt.sh foreign-container rm uses -fv" || t_bad "adopt.sh lost -fv"
[[ "$(grep -c 'docker rm -fv' "$CD")" -ge 2 ]] && t_ok "chatdev uninstall+recreate use -fv" || t_bad "chatdev rm sites lost -fv"
grep -q '_compose stop' "$AT" && grep -q '_compose down -v' "$AT" \
  && t_ok "aitown: stop keeps containers; down paths use -v (no strand)" || t_bad "aitown lifecycle regressed to stranding downs"
grep -q '_cleanup_anon_volumes delete' "$CU" && grep -q '_cleanup_anon_volumes dry' "$CU" \
  && t_ok "cleanup wires volume path in BOTH --yes and dry-run branches" || t_bad "cleanup volume path not in both branches"
grep -q 'cannot census volumes. \[skip\]"; return 0' "$CK" && t_ok "check 82 skip path returns 0 (docker-down)" || t_bad "check 82 skip-clean guard drifted"
grep -Eq 'anonymous volumes orphaned BY THIS RESET' "$RS" && t_ok "blast radius discloses the diff-scoped sweep" || t_bad "blast radius missing anon-volume disclosure"

echo "== behavioral: REAL functions under a recording docker() stub =="
TMP="$(mktemp -d)"; CALLS="$TMP/calls.log"; : > "$CALLS"
trap 'rm -rf "$TMP"' EXIT
# 64-hex fixture names (the shipped list-verb shape-guards on ^[0-9a-f]{64}$).
VA="$(printf 'a%.0s' {1..64})"; VB="$(printf 'b%.0s' {1..64})"
VC="$(printf 'c%.0s' {1..64})"; VD="$(printf 'd%.0s' {1..64})"
# Extract the shipped functions (no hand copies).
eval "$(sed -n '/^docker_anon_orphans() {/,/^}/p' "$DK")"
eval "$(sed -n '/^_sweep_run_orphaned_anon_volumes() {/,/^}/p' "$RS")"
eval "$(sed -n '/^_cleanup_anon_volumes() {/,/^}/p' "$CU")"
declare -F docker_anon_orphans >/dev/null || { t_bad "could not extract docker_anon_orphans"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; exit 1; }
declare -F _sweep_run_orphaned_anon_volumes >/dev/null || { t_bad "could not extract _sweep_run_orphaned_anon_volumes"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; exit 1; }
declare -F _cleanup_anon_volumes >/dev/null || { t_bad "could not extract _cleanup_anon_volumes"; echo "RESULT: $PASS passed, $((FAIL+1)) failed"; exit 1; }
ok(){ :; }; warn(){ :; }; log(){ :; }; note(){ :; }
AI_STACK="$TMP"; ROOT="$TMP"; RESET_TS="testts"
docker() {
  echo "docker $*" >> "$CALLS"
  case "${1:-} ${2:-}" in
    "volume ls")
      if [[ "${LS_RC:-0}" != "0" ]]; then return "$LS_RC"; fi
      local x; for x in ${LS_OUT:-}; do echo "$x"; done; return 0 ;;
    "volume rm")
      return "${RM_RC:-0}" ;;
    "volume inspect")
      echo "2026-07-03T14:19:00-07:00"; return 0 ;;
    "system df")
      printf 'VOLUME NAME  LINKS  SIZE\n'
      local x; for x in ${LS_OUT:-}; do printf '%s  0  1.5MB\n' "$x"; done
      printf '\n'; return 0 ;;
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

# (1) list: filtered passthrough + 64-hex shape guard drops a labeled NAMED volume
LS_OUT="$VA volNamedWithAnonLabel $VB"; got="$(docker_anon_orphans list | tr '\n' ' ')"
[[ "$got" == "$VA $VB " ]] && t_ok "list: passthrough + shape-guard drops non-hex names" || t_bad "list wrong: '${got:0:40}...'"
grep -q 'filter dangling=true' "$CALLS" && grep -q 'label=com.docker.volume.anonymous' "$CALLS" \
  && t_ok "list: uses BOTH dangling+anonymous filters" || t_bad "list: filters missing"

# (2) list: rc PROPAGATES on engine failure (the fail-closed snapshot contract)
LS_RC=7; docker_anon_orphans list >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && t_ok "list: docker failure propagates rc (snapshot can detect it)" || t_bad "list swallows engine failure (fail-open)"
LS_RC=0

# (3) remove: backup-first then rm; explicit names only
: > "$CALLS"; LS_OUT=""
docker_anon_orphans remove "$TMP/bak" "$VA" "$VB"; rc=$?
[[ $rc -eq 0 ]] && t_ok "remove: rc 0 when all backed up + removed" || t_bad "remove rc=$rc"
[[ "$(grep -c '^docker volume rm ' "$CALLS")" == "2" ]] && t_ok "remove: exactly the 2 named volumes removed" || t_bad "remove: wrong rm count"
[[ -s "$TMP/bak/$VA.tgz" && -s "$TMP/bak/$VB.tgz" ]] && t_ok "remove: tar backup exists per volume" || t_bad "remove: backups missing"
docker_anon_orphans remove "" "$VA" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && t_ok "remove: missing backup dir -> warn + rc 2 (no shell-kill)" || t_bad "remove: empty-dir guard broken (rc=$rc)"

# (4) fail-closed: backup failure KEEPS the volume (no rm), rc 1; FORCE_WIPE overrides
: > "$CALLS"; BACKUP_OK=0
docker_anon_orphans remove "$TMP/bak2" "$VC"; rc=$?
[[ $rc -eq 1 ]] && ! grep -q "^docker volume rm $VC" "$CALLS" \
  && t_ok "remove: backup failure -> volume KEPT (fail-closed, rc 1)" || t_bad "remove: fail-closed broken (rc=$rc)"
: > "$CALLS"
AI_STACK_FORCE_WIPE=1 docker_anon_orphans remove "$TMP/bak2" "$VC" >/dev/null 2>&1 || true
grep -q "^docker volume rm $VC" "$CALLS" && t_ok "remove: AI_STACK_FORCE_WIPE=1 overrides a failed backup" || t_bad "FORCE_WIPE override broken"
BACKUP_OK=1

# (5) diff-scope: removes ONLY volumes not in the entry snapshot
: > "$CALLS"; _ANON_SNAPSHOT_OK=1; _ANON_BEFORE="$VA $VB "; LS_OUT="$VA $VB $VC $VD"
_sweep_run_orphaned_anon_volumes
rms="$(awk '/^docker volume rm /{print $4}' "$CALLS" | sort | tr '\n' ' ')"
[[ "$rms" == "$VC $VD " ]] && t_ok "diff-scope: removed EXACTLY the run-orphaned set" || t_bad "diff-scope removed wrong set"
grep -q "^docker volume rm $VA" "$CALLS" && t_bad "diff-scope touched a PRE-EXISTING orphan" || t_ok "diff-scope: pre-existing orphans untouched"

# (6) diff-scope no-op: nothing new -> zero removals
: > "$CALLS"; _ANON_SNAPSHOT_OK=1; _ANON_BEFORE="$VA $VB "; LS_OUT="$VA $VB"
_sweep_run_orphaned_anon_volumes
grep -q '^docker volume rm ' "$CALLS" && t_bad "no-op sweep still removed something" || t_ok "diff-scope: no new orphans -> zero removals"

# (7) FAIL-CLOSED snapshot: unverified snapshot -> sweep SKIPS everything
: > "$CALLS"; _ANON_SNAPSHOT_OK=0; _ANON_BEFORE=""; LS_OUT="$VC $VD"
_sweep_run_orphaned_anon_volumes
grep -q '^docker volume rm ' "$CALLS" && t_bad "sweep removed despite UNVERIFIED snapshot (fail-open!)" || t_ok "diff-scope: unverified entry snapshot -> sweep SKIPPED (fail-closed)"

# (8) cleanup volume path: dry itemizes but never removes; delete removes exactly the set
: > "$CALLS"; LS_OUT="$VA $VB"
out="$(_cleanup_anon_volumes dry)"
grep -q '^docker volume rm ' "$CALLS" && t_bad "cleanup DRY-RUN removed a volume" || t_ok "cleanup dry: zero removals"
[[ "$out" == *"${VA:0:16}"* && "$out" == *"${VB:0:16}"* ]] && t_ok "cleanup dry: itemizes each volume (size+age line)" || t_bad "cleanup dry: itemization missing"
: > "$CALLS"
_cleanup_anon_volumes delete >/dev/null
rms="$(awk '/^docker volume rm /{print $4}' "$CALLS" | sort | tr '\n' ' ')"
[[ "$rms" == "$VA $VB " ]] && t_ok "cleanup delete: removed exactly the itemized set" || t_bad "cleanup delete: wrong set '$rms'"
ls "$TMP"/data/volume-backups/cleanup-*/"$VA.tgz" >/dev/null 2>&1 && t_ok "cleanup delete: tar backup landed under data/volume-backups/cleanup-<ts>/" || t_bad "cleanup delete: backup missing"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
