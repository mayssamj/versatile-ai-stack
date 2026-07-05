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
  t_brew_ok: { type: brew-service, enabled: true }
  t_npm:     { type: npm-global,   enabled: true, upgrade: { method: npm-global, target: coolpkg } }
  t_pip:     { type: pip-package,  enabled: true, upgrade: { method: uv-venv, venv: t_pip_venv, pkg: coolpip } }
  t_git:     { type: clone-only,   enabled: true, upgrade: { method: git-pull, dir: t_git_dir } }
YML
export SERVICES_YML="$FIX/services.yml"
# compose fixture for the _iv_compose image-ID fallback test (absolute path so
# svc_path → a real dir the function can cd into; the docker stub feeds its images).
mkdir -p "$FIX/t_compose_dir"
cat >> "$FIX/services.yml" <<YML
  t_compose: { type: compose, enabled: true, path: "$FIX/t_compose_dir" }
YML

# fake venv python + git clone dir the oracle will probe
mkdir -p "$FIX/t_pip_venv/bin" "$FIX/t_git_dir/.git"
cat > "$FIX/t_pip_venv/bin/python" <<'PY'
#!/usr/bin/env bash
# stub: a uv-created venv is PIP-LESS by default — `python -m pip show` FAILS.
# This reproduces the real remnic_hermes bug; _iv_pip must fall back to `uv pip show`.
[[ "$*" == *"pip show"* ]] && { echo "No module named pip" >&2; exit 1; }
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
  # _iv_compose fixture: a locally-built image with NO RepoDigest (inspect fails) → the
  # ID fallback fires; T_IMG_ID lets the test move the id to simulate a real rebuild.
  "compose config --images") printf 't_img_a\n' ;;
  "image inspect --format {{index .RepoDigests 0}} t_img_a") exit 1 ;;
  "image inspect --format {{.Id}} t_img_a") echo "sha256:${T_IMG_ID:-aaaa}" ;;
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
  # --json form used by _npm_global_version (host-global reconcile probe)
  "ls -g coolpkg --depth=0 --json")     printf '{"dependencies":{"coolpkg":{"version":"1.4.0"}}}\n' ;;
  "ls -g @scope/pkg --depth=0 --json")  printf '{"dependencies":{"@scope/pkg":{"version":"2.0.1"}}}\n' ;;
  "ls -g ghostpkg --depth=0 --json")    echo '{"name":"lib"}'; exit 1 ;;   # absent → npm exits 1
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

# uv stub: the stack's venvs are uv-managed + pip-less, so _iv_pip must probe with
# `uv pip show --python <py> <pkg>` (the fix for the remnic_hermes visibility bug).
cat > "$STUB/uv" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pip show"*coolpip*) printf 'Name: coolpip\nVersion: 2.3.4\n' ;;
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

echo "== _npm_global_version (host-global reconcile input; --json, scoped-name & absent safe) =="
nv(){ local pkg="$1" want="$2" got; got="$(_npm_global_version "$pkg")"; [[ "$got" == "$want" ]] && ok "_npm_global_version($pkg)='$got'" || bad "_npm_global_version($pkg)='$got' expected '$want'"; }
nv coolpkg     1.4.0
nv @scope/pkg  2.0.1     # scoped name contains '/' — a sed-based probe would break here
nv ghostpkg    ""        # npm exits 1 + {"name":"lib"} → empty, no set -e/pipefail abort

echo "== _compose_lone_semver_tag (compose pinned-tag; host:port & multi-tag safe) =="
ct(){ local got; got="$(_compose_lone_semver_tag "$1")"; [[ "$got" == "$2" ]] && ok "lone-tag → '${got:-<none>}'" || bad "lone-tag='$got' expected '$2'"; }
ct "nousresearch/hermes-agent:v2026.6.19@sha256:9f367
hermes-workspace:aistack-hardened" "v2026.6.19"   # 1 semantic tag + a local-build → the tag
ct "a:v1.0
b:v2.0"                    ""                       # two semantic tags → ambiguous → none
ct "a:latest
b:stable"                  ""                       # non-semantic tags → none
ct "localhost:5000/foo/bar" ""                      # registry host:port, NO tag → must NOT read "5000/…"
ct "registry:5000/x:v3.1.4" "v3.1.4"                # host:port WITH a real tag → the tag
ct "img@sha256:deadbeef"    ""                       # digest-only, no tag → none

echo "== _iv_compose image-ID fallback: a rebuild (id change) MOVES the fingerprint =="
export T_IMG_ID=v1; cfp1="$(_iv_compose t_compose)"; cfp1b="$(_iv_compose t_compose)"
export T_IMG_ID=v2; cfp2="$(_iv_compose t_compose)"
unset T_IMG_ID
[[ "$cfp1" == "$cfp1b" ]] && ok "_iv_compose stable when the image ID is unchanged ('$cfp1')" || bad "_iv_compose unstable on identical id: '$cfp1' vs '$cfp1b'"
[[ "$cfp1" != "$cfp2"  ]] && ok "_iv_compose fingerprint MOVES on an id change ('$cfp1' → '$cfp2')" || bad "_iv_compose fingerprint did NOT move on an id change (both '$cfp1') — fallback dead"

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
ic npm-global 1.5.0 "-"   unknown       # installed KNOWN but upstream unreachable -> 'unknown' (agrees with upgrade --check), NOT 'no-oracle'
ic npm-global "-"   "-"   no-oracle     # nothing knowable at all -> no-oracle
ic npm-global "-"   1.5.0 unknown

echo "== version_status: brew up-to-date must NOT read 'no-oracle' (parity with upgrade --check) =="
vs(){ local got; got="$(version_status "$1" 2>/dev/null)"; [[ "$got" == "$2" ]] && ok "version_status($1)=$got" || bad "version_status($1)='$got' expected '$2'"; }
vs t_brew    update-available   # in `brew outdated`
vs t_brew_ok up-to-date         # installed + not outdated -> up-to-date (was wrongly 'no-oracle')

echo "== check_image / version_status docker currency (coverage gap) =="
di(){ local got; got="$(check_image "$1" 2>/dev/null)"; [[ "$got" == "$2" ]] && ok "check_image($1)=$got" || bad "check_image($1)='$got' expected '$2'"; }
di foo/bar:1.2.3   pinned            # fixed semver tag -> pinned (won't auto-move)
di foo/roll:latest update-available  # rolling tag, local digest != remote digest
di ai-stack/foo:local build          # locally-built namespace -> build (never pulled)
vs t_docker pinned                    # version_status(docker) delegates to check_image

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
# Force-cover the perl-alarm FALLBACK idiom directly — on CI Linux _vz_bounded
# picks coreutils `timeout`, so the darwin-critical perl path (the ONLY bound on
# the target host, which has no timeout/gtimeout) would otherwise be untested.
if command -v perl >/dev/null 2>&1; then
  _p0=$SECONDS
  perl -e 'my $s=shift; alarm $s; exec @ARGV or exit 127' 1 sleep 8 >/dev/null 2>&1 || true
  _pdt=$(( SECONDS - _p0 ))
  (( _pdt <= 4 )) && ok "perl-alarm fallback bounds a hung cmd in ${_pdt}s" || bad "perl-alarm did NOT bound (${_pdt}s)"
else
  bad "perl absent — _vz_bounded has NO bound on a timeout-less host"
fi

echo "== _compose_lone_semver_tag never aborts the caller under set -e (the upgrade --check --all crash) =="
# The bug: `(( sn == 1 ))` was the function's LAST statement, so it RETURNED exit 1 when sn!=1
# (0 or >1 lone semver tags) → the caller's `_lt="$(_compose_lone_semver_tag …)"` assignment
# aborted under set -e + inherit_errexit, crashing `upgrade --check --all` on the first compose
# stack with no lone semver tag (honcho/autofyn/aitown). Assert the caller SURVIVES for sn=0/1/2.
_clst_out="$(AI_STACK="$ROOT" bash -c '
  set -Eeuo pipefail; shopt -s inherit_errexit 2>/dev/null || true
  source '"$ROOT"'/installer/lib/versions.sh
  z="$(_compose_lone_semver_tag "honcho/honcho:latest")"; printf "sn0=[%s]rc=%s;" "$z" "$?"
  o="$(_compose_lone_semver_tag "a:v2026.7.1
b:img-hardened")"; printf "sn1=[%s]rc=%s;" "$o" "$?"
  t="$(_compose_lone_semver_tag "a:v1.2.3
b:v4.5.6")"; printf "sn2=[%s]rc=%s;" "$t" "$?"
  printf "REACHED_END"
' 2>&1)"
[[ "$_clst_out" == *REACHED_END ]] \
  && ok "_compose_lone_semver_tag: caller survives set -e for sn=0/1/2 (no crash)" \
  || bad "_compose_lone_semver_tag aborted the caller under set -e (got: '$_clst_out')"
[[ "$_clst_out" == *'sn0=[]rc=0'* && "$_clst_out" == *'sn1=[v2026.7.1]rc=0'* && "$_clst_out" == *'sn2=[]rc=0'* ]] \
  && ok "_compose_lone_semver_tag: empty for sn=0/2, the tag for sn=1, rc=0 throughout" \
  || bad "_compose_lone_semver_tag returned wrong value/rc (got: '$_clst_out')"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
