#!/usr/bin/env bash
# doctor.sh — diagnose & offer fixes.
#
# Discovers every checks/*.sh, sources them all, runs each <name>_diagnose,
# offers <name>_fix on failure if interactive. Reports a summary.
#
# Each check file must:
#   - Define <name>_diagnose : exits 0 on PASS, non-zero on FAIL.
#   - Define <name>_fix      : applies the fix (may prompt). Returns 0 on success.
#   - Append its name to the CHECKS array.
#   - Set CHECK_TITLE[<name>] to a short description.
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/prompt.sh"
source "$AI_STACK/installer/lib/litellm.sh"
source "$AI_STACK/installer/lib/worktree.sh"

declare -ag CHECKS=()
declare -Ag CHECK_TITLE=()
# Checks may set AUTOHEAL[<name>]=1 to mark a SAFE, idempotent fix that doctor
# applies automatically (no Y/n prompt). Used for self-healing the LiteLLM
# key-store (05a). Still skipped under NO_PROMPT (report-only stays read-only).
declare -Ag AUTOHEAL=()
# Checks may set FIX_CAPABLE[<name>]=1 to declare that <name>_fix actually MUTATES
# state (installs, restarts, rewrites config, queues a restart) — i.e. answering "y"
# to the auto-fix prompt DOES something. Deliberately opt-in: 54 of the 75 _fix
# bodies only PRINT guidance (the house convention), but the prompt used to gate on
# the fix function's mere EXISTENCE (`declare -F`), so doctor offered "Auto-fix
# available. Apply?" for them — the operator answered y, nothing ran, and doctor
# reported "fix ran but the check still fails" (the 74/76 incident, 2026-07-16).
# An UNMARKED check is treated as ADVISORY: doctor never OFFERS to apply its fix, so it
# cannot over-promise a fix it can't perform. Read the contract precisely — the marker
# gates the PROMPT, not execution:
#   UNMARKED ⇒ the _fix body MUST be print-only. It is still RUN — in EVERY mode,
#   INCLUDING NO_PROMPT=1 — so its guidance reaches the operator (see :113 below).
#   The marker does NOT sandbox it: an unmarked body that MUTATES will mutate under
#   NO_PROMPT, silently breaking doc/DOCTOR.md's "report-only" promise.
# So this is a CONVENTION enforced by the check census (21 marked mutating / 54 verified
# print-only, 2026-07-16), not by the runner. A new check with a mutating _fix must mark
# FIX_CAPABLE — and the check template in doc/AGENT-ONBOARDING.md says so.
# AUTOHEAL implies capable (its heal is a real, applied mutation).
declare -Ag FIX_CAPABLE=()

# Source every check file. Each must append to CHECKS + set CHECK_TITLE.
# DOCTOR_CHECKS_DIR overrides the checks directory (defaults to the shipped one) —
# used by the hermetic doctor tests to run this real runner against synthetic checks.
for f in "${DOCTOR_CHECKS_DIR:-$AI_STACK/installer/doctor/checks}"/*.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

if (( ${#CHECKS[@]} == 0 )); then
  warn "no doctor checks found in ${DOCTOR_CHECKS_DIR:-$AI_STACK/installer/doctor/checks}/"
  exit 0
fi

FILTER="${1:-}"
# `--all` is NOT a name filter: it means "run every check, INCLUDING the deep/negative
# probes that gate on DOCTOR_ALL" (checks 25/49 document `doctor --all` as their trigger).
# The old code treated `--all` as a substring filter — no check name contains "--all", so
# every check was skipped and the run became a silent "0 checks, 0 passed" no-op that exited
# 0 where a full audit was intended. Map it to the env flag + an empty filter. (2026-07-05.)
if [[ "$FILTER" == "--all" ]]; then
  export DOCTOR_ALL=1
  FILTER=""
fi
hdr "Running doctor checks${FILTER:+ (filter: $FILTER)}"

# _doctor_apply_and_verify <check> — run the check's fix, then RE-DIAGNOSE to confirm it
# actually resolved the problem. Returns 0 IFF the check now passes. The old code counted
# a check "fixed" purely on the fix function's EXIT CODE, which was wrong in BOTH directions:
#   - a fix that HEALED but returned non-zero (e.g. lumen/claw3d _fix `return 1` after a
#     good model-pull / restart) was falsely reported "fix attempt failed"; and
#   - a fix that only QUEUED a restart (didn't resolve now) returned 0 and was falsely
#     counted "fixed", so doctor exited 0 on a still-broken stack.
# Verifying by re-diagnosis makes the accounting honest. The fix's own messages still print;
# only the verification diagnose is silenced. (Adds one diagnose re-run per fixed check —
# a bounded cost paid only on checks that both failed AND had a fix applied.) 2026-07-05.
_doctor_apply_and_verify() {
  local chk="$1"
  ( "${chk}_fix" </dev/null ) || true                # run the fix (its messages show); rc is advisory
  ( "${chk}_diagnose" ) </dev/null >/dev/null 2>&1   # re-diagnose: did the fix actually resolve it?
}

# Use a deliberately uncommon loop variable so check functions can't shadow it.
# (A function that does `for name in ...` without declaring `local name` would
# otherwise clobber the outer iteration.)
passed=0; failed=0; fixed=0; skipped=0
for __check in "${CHECKS[@]}"; do
  __title="${CHECK_TITLE[$__check]:-$__check}"
  if [[ -n "$FILTER" && "$__check" != *"$FILTER"* ]]; then
    skipped=$((skipped+1))
    continue
  fi
  printf '  %-60s ' "$__title"
  # Detach diagnose/fix from the doctor's stdin. Checks that run
  # `openshell sandbox exec …` stream their stdin INTO the sandbox, so an
  # inherited prompt stdin (an interactive tty, or a `yes |` pipe used to
  # auto-answer the fix prompts) leaks into the probe and corrupts it —
  # producing false failures (seen on checks 25/30/33). The confirm prompt
  # below still reads the real stdin, so auto-fix answers keep working.
  # Run each check in a SUBSHELL ( … ) so nothing it does — a stray `exit`, an
  # errexit abort, a failing command-substitution — can kill the doctor LOOP.
  # Before this, one misbehaving check (e.g. when LiteLLM was down) aborted the
  # whole run mid-way, leaving most checks unrun. Now the loop always completes.
  if ( "${__check}_diagnose" ) </dev/null >/dev/null 2>&1; then
    printf '%s\n' "${C_GREEN}✓${C_RESET}"
    passed=$((passed+1))
  else
    printf '%s\n' "${C_RED}✗${C_RESET}"
    failed=$((failed+1))
    # Re-run to show the user the actual failure detail (also subshell-isolated).
    ( "${__check}_diagnose" ) </dev/null 2>&1 | sed 's/^/      /' || true
    if declare -F "${__check}_fix" >/dev/null; then
      if [[ "${FIX_CAPABLE[$__check]:-0}" != "1" && "${AUTOHEAL[$__check]:-0}" != "1" ]]; then
        # ADVICE-ONLY fix (the DEFAULT — an unmarked check lands here). Never OFFER to
        # "apply" it: there is nothing to apply, and promising a fix we can't perform
        # is what sent the operator in circles.
        # ⚠ This branch RUNS the body anyway (stdin detached) so the guidance reaches the
        # operator in EVERY mode, including NO_PROMPT / non-interactive, where a human most
        # needs the steps. It is NOT a sandbox: an unmarked body that MUTATES would mutate
        # right here, under NO_PROMPT, violating doc/DOCTOR.md's "report-only" contract.
        # Being unmarked is therefore an ASSERTION by the check author that the body is
        # print-only — mark FIX_CAPABLE on any _fix that mutates.
        # Its rc is irrelevant here (these bodies `return 1` by convention).
        note "    Manual step required:"
        ( "${__check}_fix" </dev/null ) 2>&1 | sed 's/^/      /' || true
      elif [[ "${NO_PROMPT:-0}" == "1" ]]; then
        note "    (auto-fix available; NO_PROMPT=1 so skipping)"
      elif [[ "${AUTOHEAL[$__check]:-0}" == "1" ]]; then
        # SAFE, idempotent self-heal (e.g. the LiteLLM key-store): apply
        # AUTOMATICALLY — no prompt. This failure class is meant to resolve
        # itself, and the recovery is non-destructive + worktree-guarded.
        note "    auto-healing (safe, idempotent — no prompt)…"
        if _doctor_apply_and_verify "$__check"; then
          ok   "    auto-healed (verified)."
          fixed=$((fixed+1))
        else
          err "    auto-heal ran but the check still fails (may need a restart or manual step)."
        fi
      elif ! [[ -t 0 ]]; then
        # Non-interactive shell (piped / </dev/null / cron / spawned as a subprocess): NEVER
        # auto-apply a PROMPTED fix here. `confirm … Y` reads its answer from stdin and, on EOF,
        # returns the DEFAULT (yes) — so a headless `doctor` would silently run a heavy or
        # destructive fix. That bit us: a piped run auto-triggered check 08's `ollama pull`
        # (now `nemotron-3-nano:4b` ~2.8 GB) — violating the no-local-model policy. AUTOHEAL
        # fixes (checked above) are the ONLY ones safe to run headless; everything else waits for
        # a human in a real terminal. Report + skip.
        note "    (auto-fix available; non-interactive shell — skipping; re-run \`doctor\` in a terminal to apply)"
      elif confirm "    Auto-fix available. Apply?" Y; then
        if _doctor_apply_and_verify "$__check"; then
          ok   "    fixed (verified)."
          fixed=$((fixed+1))
        else
          err "    fix ran but the check still fails — see the detail above; a queued restart (mayssam-ai-stack.sh apply-restarts) or a manual step may be needed."
        fi
      fi
    fi
  fi
done

# A non-empty filter that matched ZERO checks is almost always a typo (e.g. `doctor
# pheonix`). The old code silently reported "0 checks" and exited 0 — so a mistyped
# filter in a CI/pre-push gate passed green forever. Fail loud + non-zero instead.
# (2026-07-05 takeover fix.)
if [[ -n "$FILTER" ]] && (( passed + failed == 0 )); then
  err "doctor: filter '$FILTER' matched no checks (skipped all $skipped). Check the name, or run 'mayssam-ai-stack.sh doctor' with no filter."
  exit 2
fi

printf '\nDoctor done: %d checks, %d passed, %d fixed, %d remaining failed, %d skipped.\n' \
  "$((passed+failed))" "$passed" "$fixed" "$((failed-fixed))" "$skipped"

declare -F print_inference_hint >/dev/null 2>&1 || source "$AI_STACK/installer/lib/lmstudio.sh"
print_inference_hint

# Point a stuck user at the agent repair prompt — but ONLY when something is actually
# red. Nothing in the installer used to name a recovery doc, so a failing user's next
# move was a web search. This is the moment of frustration; make the pointer reachable
# here rather than hoping they browse doc/. Green runs stay quiet (no nag).
#
# UNFILTERED runs only. `doctor <check>` is a targeted probe, not the "I'm stuck"
# moment — and `cmd_verify` shells out to this script FOUR times with single-check
# filters, on precisely the broken-host state it exists to detect, so an ungated hint
# printed four copies of itself and buried verify's own verdict.
if [[ -z "$FILTER" ]] && (( failed - fixed > 0 )); then
  print_repair_hint
fi
(( failed - fixed > 0 )) && exit 1 || exit 0
