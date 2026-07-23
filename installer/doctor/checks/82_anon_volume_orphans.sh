# Dangling ANONYMOUS docker volume census (hygiene, ADVISORY).
#
# Anonymous volumes (engine label com.docker.volume.anonymous) are minted by
# single-path `-v /path` mask-guards (chatdev/ai-town node_modules), image VOLUME
# directives, and the OpenShell supervisor's sandbox homes (the gateway strips
# --label). Since §24 2026-07-20 every ai-stack rm sink passes `-v` and reset
# sweeps its own orphans (diff-scoped). KNOWN BENIGN growth sources remain — an
# opt-in OPENSHELL_FORCE_RECREATE sandbox recreate, a watchdog token-expiry
# recreate, another project's debris on this shared engine — so treat growth as
# a CADENCE signal (reclaim when it accretes), not proof of a new leak; a fast
# unexplained climb IS one. UNMARKED on purpose: the
# fix body prints guidance only; removal is non-recoverable and stays operator-
# gated behind `cleanup --docker` (itemized dry-run) → `--yes` (tar-backup first).
# Skip-clean when the docker engine isn't reachable (63_loopback_publish idiom):
# a stopped engine must not fail an advisory census. Read-only; no external calls.
CHECKS+=(anon_volume_orphans)
CHECK_TITLE[anon_volume_orphans]="docker: dangling anonymous volumes (census <=5)"

anon_volume_orphans_diagnose() {
  docker info >/dev/null 2>&1 || { echo "docker engine not reachable — cannot census volumes. [skip]"; return 0; }
  # awk (never `| grep -c`/-q — EPIPE-under-pipefail class) counts the dangling
  # anonymous set; threshold stays a LITERAL (a knob would need shape-validation
  # before any arithmetic — the check-72 crash class).
  local n
  n="$(docker volume ls -q --filter dangling=true --filter label=com.docker.volume.anonymous 2>/dev/null | awk 'END{print NR}')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n > 5 )); then
    echo "$n dangling anonymous volume(s) (threshold 5) — engine hygiene debt, not a service fault"
    return 1
  fi
  echo "  (dangling anonymous volumes: $n — within threshold 5)"
  return 0
}

anon_volume_orphans_fix() {
  warn "Dangling anonymous volumes have accreted (sandbox force-recreates, other projects' debris — or a new leak if climbing fast)."
  warn "Review + reclaim them explicitly — the list is HOST-WIDE (other projects' debris shows too):"
  warn "    mayssam-ai-stack.sh cleanup --docker          # itemized dry-run (size + age per volume)"
  warn "    mayssam-ai-stack.sh cleanup --docker --yes    # tar-backup each, then remove"
  return 1
}
