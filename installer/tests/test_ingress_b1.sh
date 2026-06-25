#!/usr/bin/env bash
# test_ingress_b1.sh — Offline unit tests for B1 (ingress idempotency guard).
#
# Tests three scenarios with stubbed launchctl / caddy / curl / sudo:
#   S1: plist + Caddyfile UNCHANGED + daemon LOADED + health OK
#       → SKIP (no bootout/bootstrap called); exit 0; advisory logged
#   S2: Caddyfile CHANGED + daemon LOADED
#       → bootstrap IS called
#   S3: daemon LOADED but health probe FAILS → bootstrap IS called (self-heal)
#
# Runs WITHOUT touching the live stack / real launchctl / real sudo.
set -Eeuo pipefail

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1 — got: >>>$2<<<"; FAIL=$(( FAIL + 1 )); }

assert_contains()     { printf '%s' "$3" | grep -qF "$2" && pass "$1" || fail "$1" "$3"; }
assert_not_contains() { printf '%s' "$3" | grep -qF "$2" && fail "$1" "$3" || pass "$1"; }

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INGRESS_SH="$WORKTREE/installer/lib/ingress.sh"

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

STUBDIR="$TESTDIR/stubs"
mkdir -p "$STUBDIR"

# ── Stub factories ────────────────────────────────────────────────────────────

# sudo stub: handles -n (dry-run check) and passes through otherwise.
# This makes `sudo -n true` succeed (simulating cached sudo token).
make_sudo_stub() {
  cat > "$STUBDIR/sudo" <<'EOF'
#!/bin/bash
# Strip -n and run the rest
args=()
for a in "$@"; do [[ "$a" == "-n" ]] && continue; args+=("$a"); done
[[ ${#args[@]} -eq 0 ]] && exit 0
"${args[@]}"
EOF
  chmod +x "$STUBDIR/sudo"
}

make_launchctl_stub() {
  local print_exit="${1:-0}"   # 0=daemon loaded, 1=not loaded
  local calls_log="$TESTDIR/calls.log"
  cat > "$STUBDIR/launchctl" <<EOF
#!/bin/bash
case "\$1" in
  print)     exit $print_exit ;;
  bootout)   echo "STUB_BOOTOUT"   >> "$calls_log"; exit 0 ;;
  bootstrap) echo "STUB_BOOTSTRAP" >> "$calls_log"; exit 0 ;;
  load)      echo "STUB_LOAD"      >> "$calls_log"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/launchctl"
}

make_curl_stub() {
  local rc="${1:-0}"
  printf '#!/bin/bash\nexit %s\n' "$rc" > "$STUBDIR/curl"
  chmod +x "$STUBDIR/curl"
}

make_caddy_stub() {
  local validate_rc="${1:-0}"
  cat > "$STUBDIR/caddy" <<EOF
#!/bin/bash
case "\$1" in
  validate) exit $validate_rc ;;
  version)  echo "v2.9.0-stub"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBDIR/caddy"
}

# macOS `install` stub: copies src→dst
make_install_stub() {
  printf '#!/bin/bash\ncp "${@: -2:1}" "${@: -1}"\n' > "$STUBDIR/install"
  chmod +x "$STUBDIR/install"
}

# ifconfig stub (used by ingress_caddyfile_content for lo0 IP check)
make_ifconfig_stub() {
  cat > "$STUBDIR/ifconfig" <<'EOF'
#!/bin/bash
# Return a minimal lo0 block so grep for 127.0.10.x finds nothing
echo "lo0: flags=8049"
echo "	inet 127.0.0.1 netmask 0xff000000"
EOF
  chmod +x "$STUBDIR/ifconfig"
  # Also stub /sbin/ifconfig by creating a wrapper in stubs
  mkdir -p "$STUBDIR/sbin"
  cp "$STUBDIR/ifconfig" "$STUBDIR/sbin/ifconfig"
}

# ── Plist generation helper ───────────────────────────────────────────────────
# Generate the plist content ingress.sh would write, for cmp matching.
gen_plist() {
  local dest="$1"
  local plist_tmp; plist_tmp="$TESTDIR/gen_plist.sh"
  cat > "$plist_tmp" <<SCRIPT
#!/bin/bash
export PATH="$STUBDIR:\$PATH"
export AI_STACK="$WORKTREE"
export INGRESS_PLIST="$dest"
export INGRESS_CADDYFILE="$TESTDIR/gen.Caddyfile"
export INGRESS_WRAPPER="$TESTDIR/gen-ingress-run.sh"
export INGRESS_LOG_OUT="$TESTDIR/ingress.out"
export INGRESS_LOG_ERR="$TESTDIR/ingress.err"
export INGRESS_DATA_DIR="$TESTDIR/caddy-data"
log()  { :; }; ok() { :; }; warn() { :; }; err() { :; }; note() { :; }
source "$WORKTREE/installer/lib/common.sh" 2>/dev/null || true
aliases_load() { return 0; }
source "$INGRESS_SH"
ingress_plist_content > "$dest"
SCRIPT
  bash "$plist_tmp" 2>/dev/null
}

# ── run_daemon_test <plist> <caddyfile> <_INGRESS_CADDYFILE_CHANGED> ──────────
# Runs ingress_install_daemon in a subprocess with stubbed env.
run_daemon_test() {
  local plist="$1" caddyfile="$2" cfile_changed="$3"
  local runner; runner="$TESTDIR/runner_$$.sh"
  # Write runner to a file (SOUL r10: complex scripts in files, not inline)
  cat > "$runner" <<RUNNER
#!/bin/bash
set -euo pipefail
export PATH="$STUBDIR:\$PATH"
export AI_STACK="$WORKTREE"
export INGRESS_PLIST="$plist"
export INGRESS_CADDYFILE="$caddyfile"
export INGRESS_WRAPPER="$TESTDIR/ingress-run.sh"
export INGRESS_LOG_OUT="$TESTDIR/ingress.out"
export INGRESS_LOG_ERR="$TESTDIR/ingress.err"
export INGRESS_DATA_DIR="$TESTDIR/caddy-data"
# Source common.sh for log/ok/warn/err/note helpers
source "$WORKTREE/installer/lib/common.sh" 2>/dev/null || {
  log()  { echo "LOG: \$*"; }
  ok()   { echo "OK: \$*"; }
  warn() { echo "WARN: \$*" >&2; }
  err()  { echo "ERR: \$*" >&2; }
  note() { echo "NOTE: \$*"; }
}
# Stub aliases_load before network.sh is sourced by ingress.sh
aliases_load() { return 0; }
# Source ingress.sh — defines ingress_* fns; the bash-version re-exec and
# run-direct CLI block are both skipped when sourced.
source "$INGRESS_SH"
# Override _INGRESS_CADDYFILE_CHANGED to the test scenario value
_INGRESS_CADDYFILE_CHANGED=$cfile_changed
# Run the function under test
ingress_install_daemon
RUNNER
  chmod +x "$runner"
  bash "$runner" 2>&1
}

# ── Scenario 1: unchanged + loaded + healthy → SKIP ──────────────────────────
scenario1() {
  local label="S1 (unchanged+loaded+healthy → SKIP)"
  echo "--- $label ---"

  make_sudo_stub
  make_launchctl_stub 0    # daemon loaded
  make_curl_stub 0          # health OK
  make_caddy_stub 0         # validate OK
  make_install_stub
  make_ifconfig_stub
  > "$TESTDIR/calls.log"

  local plist="$TESTDIR/s1.plist"
  local caddyfile="$TESTDIR/s1.Caddyfile"
  gen_plist "$plist"
  printf '{ admin off }\n' > "$caddyfile"; chmod 0644 "$caddyfile"

  local out; out="$(run_daemon_test "$plist" "$caddyfile" "0")"
  local calls; calls="$(cat "$TESTDIR/calls.log" 2>/dev/null || true)"

  echo "  OUT: $out"
  echo "  CALLS: $calls"

  assert_not_contains "$label: no BOOTOUT"   "STUB_BOOTOUT"   "$calls"
  assert_not_contains "$label: no BOOTSTRAP" "STUB_BOOTSTRAP" "$calls"
  assert_not_contains "$label: no LOAD"      "STUB_LOAD"      "$calls"
  assert_contains     "$label: skip advisory" "already loaded" "$out"
}

# ── Scenario 2: Caddyfile CHANGED + loaded → bootstrap called ────────────────
scenario2() {
  local label="S2 (Caddyfile changed + loaded → BOOTSTRAP)"
  echo "--- $label ---"

  make_sudo_stub
  make_launchctl_stub 0    # daemon loaded
  make_curl_stub 0
  make_caddy_stub 0
  make_install_stub
  make_ifconfig_stub
  > "$TESTDIR/calls.log"

  local plist="$TESTDIR/s2.plist"
  local caddyfile="$TESTDIR/s2.Caddyfile"
  gen_plist "$plist"
  printf '{ admin off }\n' > "$caddyfile"; chmod 0644 "$caddyfile"

  # Simulate Caddyfile changed → _INGRESS_CADDYFILE_CHANGED=1
  local out; out="$(run_daemon_test "$plist" "$caddyfile" "1")"
  local calls; calls="$(cat "$TESTDIR/calls.log" 2>/dev/null || true)"

  echo "  OUT: $out"
  echo "  CALLS: $calls"

  assert_contains "$label: BOOTSTRAP called" "STUB_BOOTSTRAP" "$calls"
}

# ── Scenario 3: unchanged + loaded + health FAILS → bootstrap called ─────────
scenario3() {
  local label="S3 (loaded + health fail → BOOTSTRAP)"
  echo "--- $label ---"

  make_sudo_stub
  make_launchctl_stub 0    # daemon loaded
  make_curl_stub 1          # curl fails
  make_caddy_stub 1         # caddy validate also fails
  make_install_stub
  make_ifconfig_stub
  > "$TESTDIR/calls.log"

  local plist="$TESTDIR/s3.plist"
  local caddyfile="$TESTDIR/s3.Caddyfile"
  gen_plist "$plist"
  printf '{ admin off }\n' > "$caddyfile"; chmod 0644 "$caddyfile"

  # Caddyfile unchanged, daemon loaded, but health probe fails
  local out; out="$(run_daemon_test "$plist" "$caddyfile" "0")"
  local calls; calls="$(cat "$TESTDIR/calls.log" 2>/dev/null || true)"

  echo "  OUT: $out"
  echo "  CALLS: $calls"

  assert_contains "$label: BOOTSTRAP called" "STUB_BOOTSTRAP" "$calls"
  assert_contains "$label: health fail logged" "health probe failed" "$out"
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo "=== B1 Offline Tests: ingress idempotency guard ==="
echo ""
scenario1; echo ""
scenario2; echo ""
scenario3; echo ""
echo "=== Results: PASS=$PASS  FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
