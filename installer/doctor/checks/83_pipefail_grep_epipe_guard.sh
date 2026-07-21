# Pipefail-EPIPE static guard (repo hygiene, ADVISORY).
#
# `producer | grep -q` under `set -o pipefail` is a RACE whenever the producer
# can still be writing when grep -q exits at its first match: the producer takes
# SIGPIPE (rc 141), pipefail poisons the pipeline, and a TRUE condition reads
# FALSE. Line-flushing producers (yq, docker logs) and any awk sitting mid-pipe
# are the proven-fatal classes — this bit LIVE twice: openshell phase wiring
# (checks 78/80 era) and doctor check 06 red on a GREEN fresh install
# (litellm_has_callback, reproduced rc=141 ~40% of runs, 2026-07-21).
# Remedies (pick per site): capture-then-grep on a variable (fleet.sh idiom),
# fold the match into awk END with NO early exit, or count with `grep -c`
# (which consumes all input). Buffered single-write producers (`docker ps`
# tabwriter tables, printf builtins, a trailing curl -w code) cannot EPIPE and
# are deliberately NOT flagged.
# Heuristic is SINGLE-LINE (a pipeline split across continuation lines is not
# seen) — the offline suite pins the known multi-line sites; this check stops
# NEW single-line regressions. Inner `sh -c`/`bash -c` strings run without
# pipefail and are excluded. UNMARKED on purpose: the fix body prints guidance
# only (conversion is per-site judgment, never a blind sed). Read-only.
CHECKS+=(pipefail_grep_epipe_guard)
CHECK_TITLE[pipefail_grep_epipe_guard]="repo: no racy 'producer | grep -q' pipelines (pipefail-EPIPE guard)"

pipefail_grep_epipe_guard_diagnose() {
  local bad
  # Producer classes guarded: yq …|grep -q · docker logs …|grep -q · |awk …|grep -q.
  # Excludes: this check itself, comment lines, inner sh -c / bash -c shells.
  bad="$(grep -rnE 'yq [^|]*\|[[:space:]]*grep -[A-Za-z]*q|docker logs [^|]*\|[[:space:]]*grep -[A-Za-z]*q|\| *awk [^|]*\| *grep -[A-Za-z]*q' \
           "$AI_STACK/installer/lib" "$AI_STACK/installer/phases" "$AI_STACK/installer/doctor/checks" "$AI_STACK/bin" 2>/dev/null \
         | grep -vF '83_pipefail_grep_epipe_guard' \
         | grep -vE ':[0-9]+:[[:space:]]*#' \
         | grep -vE 'sh -c|bash -c')" || bad=""
  if [[ -n "$bad" ]]; then
    echo "racy 'producer | grep -q' pipeline(s) under pipefail — flaky false-negatives (EPIPE class):"
    printf '%s\n' "$bad" | sed 's/^/      /'
    return 1
  fi
  echo "  (no racy yq/docker-logs/awk-mid-pipe '| grep -q' pipelines in lib/phases/checks/bin)"
  return 0
}

pipefail_grep_epipe_guard_fix() {
  warn "Convert each flagged site by hand (semantics differ per site — never a blind sed):"
  warn "  capture-then-grep:   out=\"\$(producer)\" || out=\"\"; grep -qxF \"\$needle\" <<<\"\$out\""
  warn "  fold into awk END:   producer | awk -v m=\"\$needle\" '\$1==m{f=1} END{exit f?0:1}'   (NO early exit)"
  warn "  count, then judge:   n=\"\$(producer | grep -c pattern)\" || n=0; (( n > 0 ))"
  return 1
}
