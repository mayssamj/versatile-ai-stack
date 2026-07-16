# 79_fix_capable_integrity.sh — mechanical integrity of the doctor FIX_CAPABLE marker.
#
# WHY THIS EXISTS (the hole the 2026-07-16 council PROVED is still open):
#   doctor.sh's auto-fix prompt gates on the FIX_CAPABLE[<name>] marker (see the contract
#   at installer/doctor/doctor.sh:30-48). But the marker only gates the PROMPT — it does
#   NOT sandbox the body. An UNMARKED check's _fix is STILL RUN, in EVERY mode INCLUDING
#   NO_PROMPT=1 (doctor.sh:132-133), because that branch prints the body's "manual step"
#   guidance. The whole design is safe ONLY BECAUSE the 54 unmarked bodies are print-only.
#   The council replayed doctor.sh with a check written straight from AGENT-ONBOARDING's
#   template (a mutating _fix, no marker) and, under NO_PROMPT=1, watched its body RESTART
#   a service and CREATE a sentinel — silently breaking doc/DOCTOR.md's "report-only"
#   promise. Their remedy was a doc-template note: a CONVENTION enforced by nothing but a
#   one-time hand census. This check makes it MECHANICAL — every `doctor` run re-asserts it.
#
# WHAT IT ASSERTS:
#   (1) No orphan markers      — every FIX_CAPABLE[<name>]=1 maps to a registered check that
#                                actually defines <name>_fix.
#   (2) AUTOHEAL ⊆ FIX_CAPABLE — every AUTOHEAL[<name>]=1 also carries FIX_CAPABLE[<name>]=1
#                                (AUTOHEAL implies capable; doctor treats it as such).
#   (3) No unmarked mutation   — every _fix that is NEITHER FIX_CAPABLE NOR AUTOHEAL must be
#                                print-only. A mutating body without a marker is the hole.
#
# THE MUTATION HEURISTIC (honest about its limits):
#   It is a SOURCE GREP over `declare -f <name>_fix` and CANNOT be perfect. It works by an
#   ALLOWLIST: after blanking string literals (so advice text can't trip it) and stripping
#   comments, every STATEMENT-POSITION command word must be a known output/control builtin
#   (warn/note/log/err/ok/echo/printf/return, the shell keywords, local/declare, source).
#   Anything else at statement position — brew, docker, rm, chmod, sudo, queue_restart,
#   set_env, `bash <script>`, engine_pin, … — counts as MUTATION and demands a marker.
#   A WRITE REDIRECT to a real file (`: > f`, `echo x > "$f"`, `printf … >> "$f"`) also counts
#   as MUTATION even when the leading word is safe — creating/writing a file is the "sentinel"
#   half of the reproduced regression; `/dev/null`, fd-dups (`>&2`, `2>&1`) and `[[ … ]]`
#   comparisons are NOT redirects and stay clean (§24 SHOULDFIX). `command`/`read`/`grep`/
#   `stat`/`readlink` and `for`/`select` loop vars + `case` labels are recognized as read-only
#   (they were latent false positives).
#   Designed for ZERO FALSE POSITIVES on today's 54 print-only bodies (a check that cries
#   wolf gets ignored or deleted). The two documented traps it deliberately survives:
#     - `queue_restart`/`docker restart`/`rm` sitting INSIDE an advice STRING → blanked, not
#       a statement, so not flagged (e.g. hermes_routing_fix, the *_install advice bodies).
#     - read-only getters that LOOK like mutation — get_env / engine_display /
#       engine_addhost_args / _oa_bin_dir — appear only inside `$(…)` command-substitutions
#       (arguments, never statement heads), so they are never scanned as commands
#       (e.g. host_docker_internal_fix reads all three and is correctly print-only).
#   RESIDUAL (accepted false-negative surface, cannot be caught by a static grep):
#     - a body that mutates ONLY under a runtime condition reached via a command it hides
#       inside `$(…)` or `if <cmd>; then` where <cmd> itself mutates;
#     - a body whose mutation is a side effect of a `source`d file at source time.
#   These evade the grep; the AGENT-ONBOARDING template note remains the backstop for them.
#   The check catches the realistic, template-shaped regression — a plain mutating command
#   at statement position with no marker — which is exactly what the council reproduced.
#
# This check's OWN _fix is print-only advice, so this check is itself UNMARKED — and it
# validates itself along with every other check (self-consistent: it must stay print-only).
CHECKS+=(fix_capable_integrity)
CHECK_TITLE[fix_capable_integrity]="FIX_CAPABLE marker integrity (mutating _fix must be marked; no orphans)"

# Emits each statement-position command token in <fn>'s body that is NOT on the safe
# output/control allowlist — i.e. a mutation candidate. Empty output ⇒ print-only.
fix_capable_integrity_diagnose() {
  local _fci_awk c hits k
  local -a violations=()

  # awk program held in a variable via a QUOTED heredoc — literal single quotes survive,
  # and `awk "$_fci_awk"` passes it verbatim (a variable's value is not re-expanded).
  IFS= read -r -d '' _fci_awk <<'AWK' || true
BEGIN{
  # Output/logging + no-op + control-flow + declaration builtins are the only things a
  # print-only _fix may run. `source` is safe on its own: a lib it loads that mutates would
  # do so via a SUBSEQUENT non-allowlisted call, which this scan would then catch.
  # Read-only shell builtins/tools a print-only _fix may run. `command`/`read`/`grep`/`stat`/
  # `readlink` added (§24 SHOULDFIX): they are inspection-only and were latent false positives.
  split("warn note log err ok okay hdr info echo printf print return break continue " \
        "true false local declare typeset readonly export unset source . " \
        "command read grep stat readlink " \
        "if then else elif fi for select while until do done case esac in function time", A, " ")
  for(i in A) SAFE[A[i]]=1
  SAFE["[["]=1; SAFE["]]"]=1; SAFE["["]=1; SAFE["]"]=1; SAFE["test"]=1
  SAFE[":"]=1; SAFE["{"]=1; SAFE["}"]=1; SAFE["("]=1; SAFE[")"]=1
}
NR==1{ next }                       # skip the `<name>_fix ()` signature line
{
  line=$0
  gsub(/"[^"]*"/, "\"\"", line)     # blank double-quoted spans (advice text, paths)
  gsub(/'[^']*'/, "", line)         # blank single-quoted spans
  sub(/#.*/, "", line)              # strip trailing comment (declare -f drops them anyway)

  # --- WRITE-REDIRECT detection (§24 SHOULDFIX — the false-negative the council caught) ---
  # `: > f` / `echo enabled > "$f"` / `printf … >> "$f"` all CREATE/write a file — the exact
  # "create a sentinel" half of the reproduced regression — yet the leading word (`:`/echo/
  # printf) is on the safe list, so the command scan alone misses them. A `>`/`>>` to a REAL
  # target is a mutation. Neutralize the redirects that are NOT file writes first, then flag a
  # remainder. Skipped: `[[ … ]]`/`[ … ]` tests (there `>` is a comparator, not a redirect).
  if (line !~ /\[\[/ && line !~ /(^|[^A-Za-z0-9_])\[[ \t]/) {
    rl=line
    gsub(/[0-9]*&?>>?[ \t]*\/dev\/null/, " ", rl)   # >/dev/null 2>/dev/null &>/dev/null : safe
    gsub(/[0-9]*>>?[ \t]*&[0-9-]+/, " ", rl)          # >&2 2>&1 : fd dup, safe
    gsub(/>[ \t]*\(/, " ", rl)                         # >(…) process substitution : not a file
    if (rl ~ /(^|[^0-9<&>])>>?[ \t]*[^ \t]/)          # a surviving `>`/`>>` to a real target
      print ">file"
  }

  n=split(line, seg, /;|\|\||&&|[|&]/)   # one statement per segment
  for(i=1;i<=n;i++){
    s=seg[i]
    do{                             # peel leading operators + control keywords
      pre=s
      gsub(/^[ \t]+/, "", s)
      sub(/^[!(){}]+/, "", s)
      sub(/^(if|then|else|elif|fi|do|done|while|until|for|select|case|esac|in|function)[ \t]/, "", s)
    } while(s!=pre)
    gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
    if(s=="") continue
    # a `for VAR in …` / `select VAR in …` loop header: VAR + the word-list are data, not commands
    if(s ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]+in([ \t]|$)/) continue
    # a `case` pattern label — `foo)` / `*)` / `a|b)` — is not a command
    if(s ~ /\)[ \t]*$/ && s !~ /\(/) continue
    if(s ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) continue   # NAME=… assignment: not a command
    sub(/^[0-9]*>>?[ \t]*/, "", s)  # drop a leading redirect artifact (e.g. a blanked `> ""`)
    if(s=="" || s=="\"\"") continue
    if(match(s, /^[^ \t]+/)){ w=substr(s, RSTART, RLENGTH) } else continue
    if(w ~ /^[0-9]+$/) continue     # bare number (e.g. the `1` a `2>&1` split leaves): never a command
    if(w=="\"\"") continue          # a blanked redirect target
    if(!(w in SAFE)) print w
  }
}
AWK

  local -A _is_check=()
  for c in "${CHECKS[@]}"; do _is_check[$c]=1; done

  # (1) No orphan FIX_CAPABLE markers.
  for k in "${!FIX_CAPABLE[@]}"; do
    [[ "${FIX_CAPABLE[$k]}" == "1" ]] || continue
    if [[ -z "${_is_check[$k]:-}" ]]; then
      violations+=("orphan marker: FIX_CAPABLE[$k]=1 but '$k' is not a registered check")
    elif ! declare -F "${k}_fix" >/dev/null 2>&1; then
      violations+=("orphan marker: FIX_CAPABLE[$k]=1 but ${k}_fix() is not defined")
    fi
  done

  # (2) AUTOHEAL is a subset of FIX_CAPABLE.
  for k in "${!AUTOHEAL[@]}"; do
    [[ "${AUTOHEAL[$k]}" == "1" ]] || continue
    if [[ "${FIX_CAPABLE[$k]:-0}" != "1" ]]; then
      violations+=("AUTOHEAL[$k]=1 must also carry FIX_CAPABLE[$k]=1 (AUTOHEAL implies capable)")
    fi
  done

  # (3) Every UNMARKED _fix must be print-only.
  for c in "${CHECKS[@]}"; do
    declare -F "${c}_fix" >/dev/null 2>&1 || continue
    if [[ "${FIX_CAPABLE[$c]:-0}" == "1" || "${AUTOHEAL[$c]:-0}" == "1" ]]; then
      continue
    fi
    hits="$(declare -f "${c}_fix" | awk "$_fci_awk" | sort -u | tr '\n' ' ')"
    hits="${hits%" "}"
    if [[ -n "$hits" ]]; then
      violations+=("unmarked ${c}_fix appears to MUTATE (statement-position: $hits) — add FIX_CAPABLE[$c]=1, or make the body print-only advice")
    fi
  done

  (( ${#violations[@]} == 0 )) && return 0

  echo "FIX_CAPABLE marker integrity FAILED — doctor.sh RUNS an unmarked _fix body in EVERY"
  echo "mode (including NO_PROMPT=1), so an unmarked-but-mutating _fix silently breaks"
  echo "doc/DOCTOR.md's report-only contract. Offenders:"
  printf '  - %s\n' "${violations[@]}"
  return 1
}

# Print-only: a static-integrity failure has no state to auto-apply. (Do NOT mark this
# check FIX_CAPABLE — this body must stay print-only, which the check itself verifies.)
fix_capable_integrity_fix() {
  warn "Nothing to auto-apply — this is a static invariant. Fix the flagged check by hand:"
  warn "  - _fix MUTATES state  -> add 'FIX_CAPABLE[<name>]=1' beside its 'CHECKS+=(<name>)'"
  warn "  - _fix is advice-only -> keep the body print-only (warn/note/echo + 'return 1')"
  warn "  - orphan marker       -> remove the stale FIX_CAPABLE[...] / AUTOHEAL[...] entry"
  warn "  - AUTOHEAL[<name>]    -> must also carry FIX_CAPABLE[<name>]=1"
  warn "Contract: installer/doctor/doctor.sh:30-48 and doc/DOCTOR.md."
  return 1
}
