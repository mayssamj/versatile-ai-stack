#!/usr/bin/env bash
# smoke/doctor-fix-capability.sh — regression test for CHANGE 4: doctor.sh's FIX_CAPABLE
# prompt GATE. Drives the REAL installer/doctor/doctor.sh against SYNTHETIC checks via the
# shipped DOCTOR_CHECKS_DIR hook (doctor.sh:51-53). OFFLINE/hermetic: no stack, no gateway,
# no models, no network — print_inference_hint is stubbed so nothing probes :11434, and
# ENV_FILE is redirected to a throwaway so the real/worktree .env is never touched.
#
# WHAT IT PINS (the 2026-07-16 "74/76" incident): doctor USED to offer "Auto-fix available.
# Apply? [Y/n]" for ANY check that merely DEFINED a _fix (`declare -F`), so the operator
# answered y, nothing ran, and doctor reported "fix ran but the check still fails". CHANGE 4
# made the OFFER gate on FIX_CAPABLE: an UNMARKED (advisory) check now prints "Manual step
# required:" + its guidance instead of a false promise. This smoke pins every branch of that
# gate (doctor.sh:120-163):
#   1. CAPABLE + failing  -> interactive PROMPT -> answering y RUNS the fix -> "fixed (verified)"
#   2. ADVISORY (unmarked)-> NO prompt, "Manual step required:" + guidance, and NEVER the
#                            "fix ran but the check still fails" over-promise   <- CHANGE 4
#   3. AUTOHEAL           -> unchanged: no prompt, auto-heals
#   4. NO_PROMPT=1        -> capable is skipped; advisory still prints its guidance
#   5. a check with NO _fix at all is unaffected (no fix branch)
#
# MUST run under bash 5 (the repo re-execs into it; /bin/bash 3.2 dies on inherit_errexit).
#   bash installer/smoke/doctor-fix-capability.sh   (or: mayssam-ai-stack.sh test doctor-fix-capability)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke doctor fix-capability — the FIX_CAPABLE prompt gate (hermetic)"
fail() { err "Smoke doctor-fix-capability FAIL — $*"; exit 1; }

DOCTOR="$AI_STACK/installer/doctor/doctor.sh"
BASH5="${BASH:-/opt/homebrew/bin/bash}"; [[ -x "$BASH5" ]] || BASH5="$(command -v bash)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/docfixcap-XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
export ENV_FILE="$TMP/env"            # never touch the real/worktree .env (doctor sources docker.sh -> get_env)
export SMOKE_CAP_SENTINEL="$TMP/cap.sentinel"
export SMOKE_HEAL_SENTINEL="$TMP/heal.sentinel"

# Stub the inference hint (doctor.sh:180-181) so the run never sources lmstudio.sh / probes
# :11434 — verified below by asserting its banner is ABSENT from every captured run.
print_inference_hint() { :; }; export -f print_inference_hint

# --- synthetic checks (one file each; sourced by doctor.sh's DOCTOR_CHECKS_DIR loop) ------
mk_cap()   { cat > "$1/zzcap.sh"   <<'CHK'
CHECKS+=(zzcap); CHECK_TITLE[zzcap]="synthetic CAPABLE check"
FIX_CAPABLE[zzcap]=1
zzcap_diagnose(){ [[ -f "${SMOKE_CAP_SENTINEL:-/nonexistent/x}" ]] && return 0; echo "zzcap: broken (needs the real fix)"; return 1; }
zzcap_fix(){ : > "${SMOKE_CAP_SENTINEL}"; echo "zzcap: ran the real mutating fix"; return 0; }
CHK
}
mk_adv()   { cat > "$1/zzadv.sh"   <<'CHK'
CHECKS+=(zzadv); CHECK_TITLE[zzadv]="synthetic ADVISORY check"
zzadv_diagnose(){ echo "zzadv: broken (manual only)"; return 1; }
zzadv_fix(){ warn "ADVICE_XYZZY: run 'mayssam-ai-stack.sh install foo' by hand"; return 1; }
CHK
}
mk_heal()  { cat > "$1/zzheal.sh"  <<'CHK'
CHECKS+=(zzheal); CHECK_TITLE[zzheal]="synthetic AUTOHEAL check"
FIX_CAPABLE[zzheal]=1; AUTOHEAL[zzheal]=1
zzheal_diagnose(){ [[ -f "${SMOKE_HEAL_SENTINEL:-/nonexistent/x}" ]] && return 0; echo "zzheal: broken (needs heal)"; return 1; }
zzheal_fix(){ : > "${SMOKE_HEAL_SENTINEL}"; echo "zzheal: auto-healed the state"; return 0; }
CHK
}
mk_nofix() { cat > "$1/zznofix.sh" <<'CHK'
CHECKS+=(zznofix); CHECK_TITLE[zznofix]="synthetic NO-FIX check"
zznofix_diagnose(){ echo "zznofix: broken and there is no fix function"; return 1; }
CHK
}
newdir() { local d; d="$(mktemp -d "$TMP/checks-XXXXXX")"; printf '%s' "$d"; }

# --- pty driver: run doctor.sh with a REAL tty on stdin, auto-answering the confirm -------
cat > "$TMP/pty.py" <<'PY'
import os, sys, select, subprocess, time
answers = os.environ.get("PTY_ANSWERS", "y\n").encode()
waitfor = os.environ.get("PTY_WAIT", "Apply?").encode()
master, slave = os.openpty()
p = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
buf = b""; sent = False; start = time.time()
while True:
    if p.poll() is not None and not select.select([master], [], [], 0)[0]:
        break
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try: data = os.read(master, 4096)
        except OSError: break
        if not data: break
        buf += data
    if not sent and (waitfor in buf or time.time() - start > 10):
        try: os.write(master, answers)
        except OSError: pass
        sent = True
p.wait()
sys.stdout.buffer.write(buf)
sys.exit(p.returncode)
PY

run_plain() {  # <dir> ; NON-interactive (stdin </dev/null). Extra env via caller exports.
  local dir="$1"; set +e
  OUT="$(DOCTOR_CHECKS_DIR="$dir" "$BASH5" "$DOCTOR" </dev/null 2>&1)"; RC=$?
  set -e
}
run_pty() {    # <dir> ; interactive tty, auto-answers "y" at the Apply? prompt
  # python3 gates the interactive path — guard so a missing interpreter fails as ITSELF, not
  # misattributed to a doctor.sh regression (NIT §24). python3 is a repo dep, present here.
  command -v python3 >/dev/null 2>&1 || { err "run_pty needs python3 (repo dep) — not on PATH"; exit 1; }
  local dir="$1"; set +e
  OUT="$(DOCTOR_CHECKS_DIR="$dir" PTY_ANSWERS=$'y\n' PTY_WAIT="Apply?" \
         python3 "$TMP/pty.py" "$BASH5" "$DOCTOR")"; RC=$?
  set -e
}
has()  { grep -qF -- "$1" <<<"$OUT"; }
nhas() { ! grep -qF -- "$1" <<<"$OUT"; }

# =====================================================================================
# 0. VACUITY GUARD — the synthetic checks must actually FAIL diagnose (so the fix branch
#    is genuinely reached) and CAPABLE/AUTOHEAL must FLIP to pass once their fix ran. If
#    this ever stops holding, every scenario below is vacuous.
rm -f "$SMOKE_CAP_SENTINEL" "$SMOKE_HEAL_SENTINEL"
d0="$(newdir)"; mk_cap "$d0"; mk_adv "$d0"; mk_heal "$d0"; mk_nofix "$d0"
(
  set +u; declare -ag CHECKS=(); declare -Ag CHECK_TITLE=() AUTOHEAL=() FIX_CAPABLE=(); set -u
  for f in "$d0"/*.sh; do source "$f"; done
  zzcap_diagnose  >/dev/null 2>&1 && { echo "V: zzcap must FAIL without sentinel"; exit 1; }
  zzadv_diagnose  >/dev/null 2>&1 && { echo "V: zzadv must FAIL"; exit 1; }
  zzheal_diagnose >/dev/null 2>&1 && { echo "V: zzheal must FAIL without sentinel"; exit 1; }
  zznofix_diagnose >/dev/null 2>&1 && { echo "V: zznofix must FAIL"; exit 1; }
  declare -F zznofix_fix >/dev/null 2>&1 && { echo "V: zznofix must have NO _fix"; exit 1; }
  : > "$SMOKE_CAP_SENTINEL"; zzcap_diagnose >/dev/null 2>&1 || { echo "V: zzcap must PASS once fixed"; exit 1; }
  rm -f "$SMOKE_CAP_SENTINEL"
) || fail "0: vacuity guard — synthetic diagnoses do not behave as designed"
ok "0: vacuity guard — synthetic checks fail as designed and CAPABLE flips green after its fix"

# 1. CAPABLE + failing -> interactive PROMPT -> answering y RUNS the fix -> "fixed (verified)".
rm -f "$SMOKE_CAP_SENTINEL"
d1="$(newdir)"; mk_cap "$d1"
run_pty "$d1"
has "Auto-fix available. Apply?" || fail "1: a CAPABLE check must OFFER the auto-fix prompt (not seen). OUT:
$OUT"
has "fixed (verified)."          || fail "1: answering y must apply+verify -> 'fixed (verified).' OUT:
$OUT"
[[ -f "$SMOKE_CAP_SENTINEL" ]]   || fail "1: the fix must actually RUN (sentinel not created). OUT:
$OUT"
nhas "Inference runtimes"        || fail "1: print_inference_hint stub leaked — a :11434 probe happened. OUT:
$OUT"
ok "1: CAPABLE — prompt offered, 'y' ran the real fix, 'fixed (verified).' (sentinel created)"

# 2. ADVISORY (unmarked) + failing -> NO prompt, 'Manual step required:' + guidance, and
#    NEVER the 'fix ran but the check still fails' over-promise. (THE CHANGE-4 assertion.)
d2="$(newdir)"; mk_adv "$d2"
run_plain "$d2"
has  "Manual step required:"                  || fail "2: advisory must print 'Manual step required:'. OUT:
$OUT"
has  "ADVICE_XYZZY"                            || fail "2: advisory guidance body must be shown. OUT:
$OUT"
nhas "Auto-fix available. Apply?"             || fail "2: advisory must NOT offer an auto-fix prompt. OUT:
$OUT"
nhas "fix ran but the check still fails"      || fail "2: advisory must NOT over-promise a fix. OUT:
$OUT"
nhas "non-interactive shell"                  || fail "2: advisory must NOT fall into the capable non-interactive branch. OUT:
$OUT"
ok "2: ADVISORY — 'Manual step required:' + guidance, no prompt, no 'fix ran but still fails'"

# 3. AUTOHEAL -> unchanged: no prompt, auto-heals (runs regardless of tty; NO_PROMPT unset).
rm -f "$SMOKE_HEAL_SENTINEL"
d3="$(newdir)"; mk_heal "$d3"
run_plain "$d3"
has  "auto-healing"              || fail "3: AUTOHEAL must auto-heal (no 'auto-healing' note). OUT:
$OUT"
has  "auto-healed (verified)."   || fail "3: AUTOHEAL must verify the heal -> 'auto-healed (verified).' OUT:
$OUT"
nhas "Auto-fix available. Apply?"|| fail "3: AUTOHEAL must NOT prompt. OUT:
$OUT"
[[ -f "$SMOKE_HEAL_SENTINEL" ]]  || fail "3: AUTOHEAL fix must actually RUN (sentinel not created). OUT:
$OUT"
ok "3: AUTOHEAL — no prompt, auto-healed + verified (sentinel created)"

# 4. NO_PROMPT=1 -> capable is SKIPPED (not applied); advisory STILL prints its guidance.
rm -f "$SMOKE_CAP_SENTINEL"
d4="$(newdir)"; mk_cap "$d4"; mk_adv "$d4"
NO_PROMPT=1 run_plain "$d4"
has  "auto-fix available; NO_PROMPT=1 so skipping" || fail "4: capable under NO_PROMPT=1 must be SKIPPED with that note. OUT:
$OUT"
[[ ! -f "$SMOKE_CAP_SENTINEL" ]]  || fail "4: NO_PROMPT=1 must NOT run the capable fix (sentinel wrongly created). OUT:
$OUT"
has  "Manual step required:"      || fail "4: advisory must STILL print guidance under NO_PROMPT=1. OUT:
$OUT"
has  "ADVICE_XYZZY"               || fail "4: advisory guidance body must show under NO_PROMPT=1. OUT:
$OUT"
ok "4: NO_PROMPT=1 — capable skipped (no mutation); advisory guidance still printed"

# 5. A check with NO _fix at all is unaffected: it reports the failure, no fix branch fires.
d5="$(newdir)"; mk_nofix "$d5"
run_plain "$d5"
has  "zznofix: broken and there is no fix function" || fail "5: a no-fix check must still report its diagnose detail. OUT:
$OUT"
nhas "Manual step required:"     || fail "5: a no-fix check must not enter the advisory branch. OUT:
$OUT"
nhas "Auto-fix available. Apply?"|| fail "5: a no-fix check must not offer a prompt. OUT:
$OUT"
nhas "auto-healing"              || fail "5: a no-fix check must not auto-heal. OUT:
$OUT"
nhas "fixed (verified)."         || fail "5: a no-fix check must not report a fix. OUT:
$OUT"
ok "5: NO _fix — failure reported, no fix branch fired"

ok "Smoke doctor-fix-capability PASS — FIX_CAPABLE gate pinned across all five branches"
