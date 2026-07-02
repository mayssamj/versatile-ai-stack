#!/usr/bin/env bash
# test_versions.sh — contract test for installer/lib/versions.sh, the shared,
# side-effect-free version oracle sourced by BOTH status.sh and upgrade.sh.
#
# HERMETIC + CI-SAFE: a fixture services.yml + stubbed docker/npm/git/brew/curl
# on PATH. No network, no real docker, and — critically — NO model load ever
# (the oracle is contractually forbidden from ollama/lms load calls; the stubs
# would expose any such call as an unexpected invocation).
#
# Covers:
#   Layer A  svc_installed_version   (local, cheap, no network)
#   Layer B  svc_available_version   (upstream currency; stubbed registries)
#   Layer C  classify               (installed vs available -> one vocabulary)
#   invariants: zero top-level side effects, idempotent source guard.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v yq >/dev/null 2>&1 || { echo "yq not on PATH — skipping (not a failure)"; exit 0; }

# ---------------- hermetic sandbox ----------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$FIX"
export AI_STACK="$FIX"    # versions.sh resolves venv/clone paths under AI_STACK (env-overridable)

cat > "$FIX/services.yml" <<'YML'
version: 2
services:
  t_docker:  { type: docker,       enabled: true, image: "foo/bar:1.2.3" }
  t_roll:    { type: docker,       enabled: true, image: "foo/roll:latest" }
  t_brew:    { type: brew-service, enabled: true }
  t_npm:     { type: npm-global,   enabled: true, upgrade: { method: npm-global, target: coolpkg } }
  t_pip:     { type: pip-package,  enabled: true, upgrade: { method: uv-venv, venv: t_pip_venv, pkg: coolpip } }
  t_git:     { type: clone-only,   enabled: true, upgrade: { method: git-pull, dir: t_git_dir } }
YML
export SERVICES_YML="$FIX/services.yml"

# fake venv python + git clone dir the oracle will probe
mkdir -p "$FIX/t_pip_venv/bin" "$FIX/t_git_dir/.git"
cat > "$FIX/t_pip_venv/bin/python" <<'PY'
#!/usr/bin/env bash
# stub venv python: `python -m pip show coolpip`
[[ "$*" == *"pip show"* ]] && printf 'Name: coolpip\nVersion: 2.3.4\n'
PY
chmod +x "$FIX/t_pip_venv/bin/python"

# ---------------- stubbed probe binaries ----------------
STUB="$TMP/bin"; mkdir -p "$STUB"

cat > "$STUB/docker" <<'SH'
#!/usr/bin/env bash
# local RepoDigest for installed side; buildx imagetools for the remote side.
case "$*" in
  "image inspect --format {{index .RepoDigests 0}} foo/bar:1.2.3") echo "foo/bar@sha256:aaaa1111bbbb2222" ;;
  "image inspect --format {{index .RepoDigests 0}} foo/roll:latest") echo "foo/roll@sha256:oldoldoldold0000" ;;
  "buildx imagetools inspect foo/roll:latest --format {{.Manifest.Digest}}") echo "sha256:newnewnewnew9999" ;;
  "buildx imagetools inspect foo/bar:1.2.3 --format {{.Manifest.Digest}}") echo "sha256:aaaa1111bbbb2222" ;;
  *) exit 0 ;;
esac
SH

cat > "$STUB/brew" <<'SH'
#!/usr/bin/env bash
# installed: `brew list --versions <f>` -> "<f> 0.5.1"
# available: `brew outdated --json=v2` -> t_brew is behind (0.5.1 -> 0.6.0)
case "$*" in
  "list --versions "*) echo "${3} 0.5.1" ;;
  "outdated --json=v2") printf '{"formulae":[{"name":"t_brew","installed_versions":["0.5.1"],"current_version":"0.6.0"}],"casks":[]}\n' ;;
  *) exit 0 ;;
esac
SH

cat > "$STUB/npm" <<'SH'
#!/usr/bin/env bash
# installed: `npm ls -g coolpkg --depth=0` ; available: `npm view coolpkg version`
case "$*" in
  "ls -g coolpkg --depth=0") printf '/usr/local/lib\n`-- coolpkg@1.4.0\n' ;;
  "view coolpkg version") echo "1.5.0" ;;
  *) exit 0 ;;
esac
SH

cat > "$STUB/git" <<'SH'
#!/usr/bin/env bash
# ignore leading `-C <dir>`; installed HEAD abc1234, remote HEAD def5678 (behind)
last3="${*: -3}"
case "$*" in
  *"rev-parse --short HEAD"*) echo "abc1234" ;;
  *"ls-remote "*)             echo "def5678901234  HEAD" ;;
  *"describe"*)               echo "abc1234" ;;
  *) exit 0 ;;
esac
SH

# curl stub for PyPI JSON (uv-venv available side): coolpip latest 2.9.9
cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *pypi.org/pypi/coolpip/json*) printf '{"info":{"version":"2.9.9"}}' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# ---------------- source the unit under test ----------------
# NB: do NOT source common.sh — it defines its own ok()/note()/etc. that would
# clobber this test's PASS/FAIL helpers. versions.sh has no common.sh dependency.
source "$ROOT/installer/lib/services_accessors.sh"
if [[ ! -f "$ROOT/installer/lib/versions.sh" ]]; then
  bad "installer/lib/versions.sh does not exist yet (RED)"
  echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi

echo "== invariants =="
out="$(source "$ROOT/installer/lib/versions.sh" 2>&1; printf END)"
[[ "$out" == "END" ]] && ok "sources with zero stdout (side-effect-free)" || bad "printed on source: ${out%END}"
source "$ROOT/installer/lib/versions.sh"
source "$ROOT/installer/lib/versions.sh" && ok "re-source is a no-op (idempotent guard)" || bad "re-source errored"
for fn in svc_installed_version svc_available_version version_classify; do
  declare -F "$fn" >/dev/null 2>&1 && ok "$fn defined" || bad "$fn missing"
done

echo "== Layer A: svc_installed_version (local, stubbed) =="
ia(){ local svc="$1" want="$2" got; got="$(svc_installed_version "$svc" 2>/dev/null)"; [[ "$got" == *"$want"* ]] && ok "$svc installed='$got' (contains $want)" || bad "$svc installed='$got' expected ~ '$want'"; }
ia t_docker 1.2.3
ia t_brew   0.5.1
ia t_npm    1.4.0
ia t_pip    2.3.4
ia t_git    abc1234

echo "== Layer B: svc_available_version (upstream, stubbed) =="
ib(){ local svc="$1" want="$2" got; got="$(svc_available_version "$svc" 2>/dev/null)"; [[ "$got" == *"$want"* ]] && ok "$svc available='$got' (contains $want)" || bad "$svc available='$got' expected ~ '$want'"; }
ib t_brew 0.6.0
ib t_npm  1.5.0
ib t_pip  2.9.9
ib t_git  def5678

echo "== Layer C: version_classify installed available -> vocabulary =="
ic(){ local got; got="$(version_classify "$1" "$2" "$3" 2>/dev/null)"; [[ "$got" == "$4" ]] && ok "classify($1,$2,$3)=$got" || bad "classify($1,$2,$3)='$got' expected '$4'"; }
# args: type installed available -> class
ic npm-global 1.4.0 1.5.0 update-available
ic npm-global 1.5.0 1.5.0 up-to-date
ic npm-global 1.5.0 "-"   no-oracle
ic npm-global "-"   1.5.0 unknown

echo "== honesty: reconcile_result downgrades an unverified 'upgraded' =="
rc(){ local got; got="$(reconcile_result "$1" "$2" "$3" 2>/dev/null)"; [[ "$got" == "$4" ]] && ok "reconcile($1,$2,$3)=$got" || bad "reconcile($1,$2,$3)='$got' expected '$4'"; }
declare -F reconcile_result >/dev/null 2>&1 && ok "reconcile_result defined" || bad "reconcile_result missing"
rc upgraded    0.16.0 0.18.0 upgraded              # version really moved
rc upgraded    0.16.0 0.16.0 up-to-date            # THE no-op lie: nothing moved -> not 'upgraded'
rc upgraded    -      -      "done (unverified)"   # no oracle (e.g. hermes_fleet) -> never claim upgraded
rc up-to-date  1.0.0  1.0.0  up-to-date            # already-latest stays honest
rc FAILED      0.1    0.2    FAILED                # a real failure is never masked
rc "skipped (no npm)" - -    "skipped (no npm)"    # skips pass through untouched
rc manual      - -          manual                 # config-only pass through

echo "== bounding: _vz_bounded actually time-limits a hung probe (no coreutils timeout needed) =="
_t0=$SECONDS
if _vz_bounded 1 sleep 8 2>/dev/null; then :; fi
_dt=$(( SECONDS - _t0 ))
(( _dt <= 4 )) && ok "_vz_bounded 1 sleep 8 returned in ${_dt}s (bounded)" || bad "_vz_bounded did NOT bound (took ${_dt}s — Zscaler-hang risk)"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
