# verify.sh — runtime end-to-end verification helpers (Safety Reviewer 2).
#
# WHY THIS EXISTS
# ---------------
# Phase 01 failure on the loopback-alias refactor exposed a class of bug that
# `bash -n`, `python -m ast.parse`, and `yq -e` cannot catch: docker
# `-p 127.0.10.X:80:...` accepts the bind, but on macOS *only 127.0.0.1 is on
# lo0 by default* — packets to 127.0.10.X go nowhere because the kernel has no
# route. The original brief asserted "127.0.0.0/8 is loopback"; that was
# wrong. Six reviewers across three cycles missed it because nobody ever
# probed the alias at runtime.
#
# This file is the antidote: for every architectural claim ("X is reachable
# at Y"), there is a small, fast, idempotent runtime probe that PROVES it.
# Syntax checks remain as a cheap precondition; these probes are the truth.
#
# DESIGN NOTES
# ------------
# * Every helper exits non-zero on failure and writes a single-line diagnosis
#   to stderr (so callers can `if verify_X ...; then` cleanly).
# * Every helper uses explicit timeouts on nc/curl/docker — a hanging probe
#   must not deadlock a phase.
# * Every helper installs a `trap ... RETURN` to tear down transient sockets
#   and containers even on signal or `set -e` exit.
# * Helpers are idempotent and parallel-safe: container names embed $$ and
#   bind ports use port 0 (kernel-assigned) where possible.
# * macOS-first: BSD `stat -f`, BSD `ifconfig`, BSD `nc`. No GNU coreutils.
# * No state mutation: a verify_* call leaves the host EXACTLY as it found
#   it (no new containers, no new lo0 aliases, no /etc/hosts edits).
#
# CONVENTIONS
# -----------
#   verify_*  : returns 0 on PASS, non-zero on FAIL. Diagnoses to stderr.
#   _verify_* : private helper, callers should not use directly.
#
# Sourced after common.sh and network.sh.

[[ -z "${AI_STACK:-}" ]] && { echo "verify.sh: AI_STACK unset" >&2; exit 2; }

# Default timeouts (seconds). Tunable for slower hosts via env.
VERIFY_CURL_TIMEOUT="${VERIFY_CURL_TIMEOUT:-3}"
VERIFY_NC_TIMEOUT="${VERIFY_NC_TIMEOUT:-2}"
VERIFY_DOCKER_RUN_TIMEOUT="${VERIFY_DOCKER_RUN_TIMEOUT:-15}"
# Image used for in-network probes. alpine is small + has busybox nc/wget/getent.
VERIFY_PROBE_IMAGE="${VERIFY_PROBE_IMAGE:-alpine:3.20}"

# --- _verify_with_timeout <seconds> <command...> ----------------------------
# Portable timeout wrapper: macOS lacks GNU `timeout` by default and we don't
# want to depend on `brew install coreutils`. Use perl's alarm — perl ships
# with macOS. Returns the exit code of the wrapped command, or 124 on timeout
# (matching GNU `timeout` convention).
_verify_with_timeout() {
  local secs="${1:?usage: _verify_with_timeout <secs> <cmd...>}"; shift
  perl -e '
    my $secs = shift;
    my $pid = fork;
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec @ARGV; die "exec failed: $!"; }
    local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 1; kill "KILL", $pid; exit 124; };
    alarm $secs;
    waitpid($pid, 0);
    exit($? >> 8);
  ' "$secs" "$@"
}

# --- _verify_pick_free_port -------------------------------------------------
# Echo an unused high port on 127.0.0.1. Best-effort: a race window remains
# between probe and use, but this is far better than hard-coding a number.
_verify_pick_free_port() {
  # Spin until we land on a port `nc -z` says is closed. Try 20 times max.
  local p i
  for ((i=0; i<20; i++)); do
    # Range chosen to avoid common service ports + ephemeral collisions.
    p=$(( ( RANDOM % 20000 ) + 40000 ))
    if ! nc -z -w 1 127.0.0.1 "$p" 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
  done
  printf '%s' "$p"   # Last try; caller will see if it races.
}

# --- verify_alias_routable <alias_ip> ---------------------------------------
# Prove the host kernel actually routes packets to <alias_ip>. This is the
# missing check that would have caught the original Phase 01 failure.
#
# Method: bind `nc -l <alias_ip> <free_port>` (which only succeeds if the IP
# is configured on an interface), then `curl http://<alias_ip>:<port>/` from
# the host. We don't care that nc speaks HTTP — even an empty reply means
# packets reached the listening process, which is the property we want.
#
# BSD nc semantics: without -k, the listener exits after the first connection
# closes. We therefore probe with ONE curl, capture its exit code, and tear
# the listener down (kill is a no-op if it already exited).
#
# Cleans up the nc listener on RETURN regardless of outcome.
verify_alias_routable() {
  local ip="${1:?usage: verify_alias_routable <ip>}"
  local port nc_pid rc=0

  # Sanity: is the IP even bound to lo0? Exact-match folded into awk END —
  # `| grep -q` after awk SIGPIPEs under pipefail (EPIPE class, 2026-07-21).
  if ! ifconfig lo0 2>/dev/null | awk -v ip="$ip" '/inet / && $2==ip{f=1} END{exit f?0:1}'; then
    printf 'verify_alias_routable: %s is not bound to lo0\n' "$ip" >&2
    printf '  fix: sudo bash %s/vz-ai-stack.sh prepare-sudo\n' "$AI_STACK" >&2
    return 1
  fi

  port="$(_verify_pick_free_port)"
  # Launch a one-shot listener; nc exits after the first connection close.
  ( nc -l "$ip" "$port" >/dev/null 2>&1 ) &
  nc_pid=$!
  # Trap on RETURN to tear down even on early failure. The `|| true` on each
  # cleanup step is critical: under `set -e` in the caller, a wait that reaps
  # a signal-killed child returns non-zero and would otherwise propagate.
  # shellcheck disable=SC2064
  trap "kill $nc_pid 2>/dev/null || true; wait $nc_pid 2>/dev/null || true; trap - RETURN" RETURN

  # Give nc a moment to bind. 200ms is enough; on slow CI bump to 500.
  sleep 0.3

  # One curl probe. nc isn't HTTP, so curl typically returns:
  #   exit 0   — got something HTTP-ish (rare with bare nc)
  #   exit 52  — "Empty reply from server"  (TCP connected, no HTTP response)
  #   exit 56  — "Recv failure"             (TCP connected, listener exited)
  #   exit 7   — "Couldn't connect"         (real failure: routing/IP down)
  #   exit 28  — "Operation timed out"      (real failure: no answer)
  # Exit codes 0/52/56 ALL prove the TCP connect succeeded — that's what we
  # care about. 7/28 are the failure signal.
  local curl_exit=0
  curl -s -o /dev/null \
    --max-time "$VERIFY_CURL_TIMEOUT" \
    --connect-timeout "$VERIFY_CURL_TIMEOUT" \
    "http://${ip}:${port}/" >/dev/null 2>&1 || curl_exit=$?
  case "$curl_exit" in
    0|52|56) rc=0 ;;
    *)
      printf 'verify_alias_routable: curl to http://%s:%s/ failed (exit %s)\n' \
        "$ip" "$port" "$curl_exit" >&2
      printf '  fix: ensure lo0 has alias %s — sudo ifconfig lo0 alias %s up\n' \
        "$ip" "$ip" >&2
      rc=1
      ;;
  esac
  return $rc
}

# --- verify_container_reachable_by_alias <container> <alias> <internal_port> <path>
# Given a RUNNING container, hit `http://<alias>` from the host and assert
# 2xx, 3xx, or 4xx (4xx is OK — it proves TCP reached an HTTP server, which
# is what "reachable" means; a real liveness probe is a separate concern).
#
# This is the helper that, had it existed, would have caught Phase 01's
# silent failure: `curl http://litellm:4000` would have returned 000 and the
# phase would have failed instead of stamping done.
verify_container_reachable_by_alias() {
  local container="${1:?usage: verify_container_reachable_by_alias <container> <alias> <internal_port> <path>}"
  local alias="${2:?need alias}"
  # NOTE (§24 council 2026-06-24): despite the name, this must be the HOST-published port
  # (aliases.tsv host_port), NOT the container port — the URL below is dialed FROM THE HOST,
  # where the alias IP listens on the published port. They differ when host_port != container_port
  # (e.g. chatdev 5274->5173). Callers must pass ALIAS_HOST_PORT.
  local internal_port="${3:?need host-published port}"
  local path="${4:-/}"

  # Container must actually be running, else the test is meaningless.
  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    printf 'verify_container_reachable_by_alias: container %s is not running\n' "$container" >&2
    return 1
  fi

  # Build the URL with the explicit port. Earlier scheme used host_port=80
  # so we could omit it, but OrbStack collapses all port-80 bindings into
  # one *:80 wildcard listener — verified — so distinct services on
  # different alias IPs end up routed to whichever was registered first.
  # Mandating the port disambiguates by host-side listener identity.
  local url="http://${alias}:${internal_port}${path}"
  local code=""
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    --max-time "$VERIFY_CURL_TIMEOUT" \
    --connect-timeout "$VERIFY_CURL_TIMEOUT" \
    "$url" 2>/dev/null)" || code=""
  # curl's %{http_code} is "000" on connection failure. If curl exited non-
  # zero AND printed nothing, normalize to "000". Never append.
  [[ -z "$code" ]] && code="000"
  case "$code" in
    2??|3??|4??)
      # All three mean "we reached an HTTP server". 4xx specifically catches
      # the LiteLLM-with-auth-on case (returns 401 on /v1/models without a
      # bearer) which is success for the routing question.
      return 0
      ;;
    *)
      printf 'verify_container_reachable_by_alias: %s returned HTTP %s\n' "$url" "$code" >&2
      # Heuristics for the common failure modes:
      if [[ "$code" == "000" ]]; then
        printf '  diagnosis: TCP connect failed. Most likely causes:\n' >&2
        printf '    - %s is not bound to lo0 (run: ifconfig lo0 | grep inet)\n' "$alias" >&2
        printf '    - %s is not publishing on this alias (run: docker port %s)\n' "$container" "$container" >&2
        printf '    - /etc/hosts is missing the %s entry (run: getent hosts %s)\n' "$alias" "$alias" >&2
      fi
      return 1
      ;;
  esac
}

# --- verify_container_reachable_by_docker_dns <network> <container> <internal_port>
# Spawn a one-shot alpine container on <network>, resolve <container> by
# bare name (docker's embedded DNS), TCP-connect to <internal_port>. Proves
# that container-to-container DNS works (the path most app traffic uses).
verify_container_reachable_by_docker_dns() {
  local network="${1:?usage: verify_container_reachable_by_docker_dns <network> <container> <internal_port>}"
  local container="${2:?need container}"
  local port="${3:?need internal port}"

  if ! docker network inspect "$network" >/dev/null 2>&1; then
    printf 'verify_container_reachable_by_docker_dns: network %s does not exist\n' "$network" >&2
    return 1
  fi

  # Bounded run; --rm so a hang doesn't leave a corpse. -t and a one-line
  # shell inside busybox.
  local probe_name="ai-stack-verify-probe-$$-$RANDOM"
  local out rc=0
  out="$(_verify_with_timeout "$VERIFY_DOCKER_RUN_TIMEOUT" \
    docker run --rm --name "$probe_name" \
    --network "$network" \
    "$VERIFY_PROBE_IMAGE" \
    sh -c "nc -z -w 2 $container $port && echo OK || echo FAIL" 2>&1)" || rc=$?
  # Aggressive cleanup just in case --rm raced.
  docker rm -f "$probe_name" >/dev/null 2>&1 || true

  if [[ "$out" != *OK* ]]; then
    printf 'verify_container_reachable_by_docker_dns: in-network probe could not reach %s:%s (network=%s)\n' \
      "$container" "$port" "$network" >&2
    printf '  docker probe output: %s\n' "${out:-<empty>}" >&2
    printf '  fix: confirm %s is on network %s — docker network inspect %s | grep -A2 Containers\n' \
      "$container" "$network" "$network" >&2
    return 1
  fi
  return 0
}

# --- verify_docker_port_publish_actually_routes <ip> <port> -----------------
# The end-to-end test that would have prevented the original bug: spawn a
# throwaway container that publishes <ip>:<port>:80 and runs `nc -l 80`
# inside. From the host, `curl http://<ip>:<port>` must reach the listener.
#
# If <ip> isn't on lo0, docker accepts the -p flag but the routing chain is
# dead air — this probe will FAIL where a shallow `docker run` succeeded.
verify_docker_port_publish_actually_routes() {
  local ip="${1:?usage: verify_docker_port_publish_actually_routes <ip> <host_port>}"
  local port="${2:?need port}"

  local probe_name="ai-stack-verify-route-$$-$RANDOM"
  local rc=0
  # Use busybox nc; -l listens, -p 80 is the internal port (default for our
  # alias scheme). We redirect a known response so curl gets something back.
  # Note: `docker run -d` returns immediately, so no host-side timeout wrapper
  # needed here — the container itself handles its own lifecycle.
  if ! docker run -d --rm --name "$probe_name" \
       -p "${ip}:${port}:80" \
       "$VERIFY_PROBE_IMAGE" \
       sh -c 'while true; do printf "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK" | nc -l -p 80 -w 1; done' \
       >/dev/null 2>&1; then
    printf 'verify_docker_port_publish_actually_routes: docker run failed for %s:%s\n' "$ip" "$port" >&2
    printf '  diagnosis: docker rejected the bind. Common causes:\n' >&2
    printf '    - port %s already in use on %s (run: lsof -nP -iTCP:%s -sTCP:LISTEN)\n' "$port" "$ip" "$port" >&2
    printf '    - %s is not bound to lo0 (run: ifconfig lo0 | grep inet)\n' "$ip" >&2
    return 1
  fi
  # Tear down on any return path.
  # shellcheck disable=SC2064
  trap "docker rm -f $probe_name >/dev/null 2>&1 || true; trap - RETURN" RETURN

  # Wait for the listener (busybox nc takes a moment to bind).
  local i code=""
  for i in 1 2 3 4 5 6 7 8; do
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      --max-time "$VERIFY_CURL_TIMEOUT" \
      --connect-timeout 1 \
      "http://${ip}:${port}/" 2>/dev/null)"
    [[ -z "$code" ]] && code="000"
    [[ "$code" == "200" ]] && break
    sleep 0.5
  done

  if [[ "$code" != "200" ]]; then
    printf 'verify_docker_port_publish_actually_routes: %s:%s returned HTTP %s (expected 200)\n' \
      "$ip" "$port" "$code" >&2
    if [[ "$code" == "000" ]]; then
      printf '  diagnosis: docker accepted the publish but packets do not route to %s.\n' "$ip" >&2
      printf '             On macOS this almost always means 127.0.10.x is NOT on lo0.\n' >&2
      printf '  fix: sudo ifconfig lo0 alias %s up   (or: sudo bash %s/vz-ai-stack.sh prepare-sudo)\n' "$ip" "$AI_STACK" >&2
    fi
    rc=1
  fi
  return $rc
}

# --- verify_add_host_works <host_alias> -------------------------------------
# Confirm `--add-host=<host_alias>:host-gateway` works on this host — i.e.
# the embedded DNS will resolve <host_alias> from inside a container. Used
# for the Ollama-on-host case: subsequent service containers attach via
# --add-host=ollama:host-gateway and we need to know that resolves before
# Phase 01 starts launching them.
verify_add_host_works() {
  local host_alias="${1:?usage: verify_add_host_works <host_alias>}"

  local probe_name="ai-stack-verify-addhost-$$-$RANDOM"
  local out rc=0
  out="$(_verify_with_timeout "$VERIFY_DOCKER_RUN_TIMEOUT" \
    docker run --rm --name "$probe_name" \
    --add-host="${host_alias}:host-gateway" \
    "$VERIFY_PROBE_IMAGE" \
    sh -c "getent hosts $host_alias" 2>&1)" || rc=$?
  docker rm -f "$probe_name" >/dev/null 2>&1 || true

  if [[ -z "$out" || "$rc" -ne 0 ]]; then
    printf 'verify_add_host_works: --add-host=%s:host-gateway did not resolve in a probe container\n' \
      "$host_alias" >&2
    printf '  probe output: %s (exit %s)\n' "${out:-<empty>}" "$rc" >&2
    printf '  fix: check OrbStack/Docker Desktop host-gateway support — Settings → Network\n' >&2
    return 1
  fi
  return 0
}

# --- verify_dns_flush_propagates <alias> <expected_ip> ----------------------
# After hosts_ensure_block + dscacheutil_flush, both dscacheutil and getent
# must agree the alias resolves to <expected_ip>. Catches the case where
# dscacheutil silently deprecates in a future macOS but /etc/hosts is fine —
# or where the flush didn't actually take effect.
verify_dns_flush_propagates() {
  local alias="${1:?usage: verify_dns_flush_propagates <alias> <expected_ip>}"
  local expected="${2:?need expected ip}"

  local from_dsc from_getent
  from_dsc="$(dscacheutil -q host -a name "$alias" 2>/dev/null \
    | awk '/^ip_address:/ {print $2; exit}')"
  # `getent hosts` reads via the system resolver, which on macOS *does*
  # consult /etc/hosts. Note: `host <alias>` does NOT — it goes straight to
  # DNS, so we explicitly do not use it here.
  from_getent="$(getent hosts "$alias" 2>/dev/null | awk '{print $1; exit}')"

  if [[ "$from_dsc" != "$expected" ]]; then
    printf 'verify_dns_flush_propagates: dscacheutil says %s → %s (expected %s)\n' \
      "$alias" "${from_dsc:-<empty>}" "$expected" >&2
    printf '  fix: sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder\n' >&2
    return 1
  fi
  if [[ -n "$from_getent" && "$from_getent" != "$expected" ]]; then
    printf 'verify_dns_flush_propagates: getent says %s → %s (expected %s)\n' \
      "$alias" "$from_getent" "$expected" >&2
    return 1
  fi
  return 0
}

# --- verify_etc_hosts_correctly_owned ---------------------------------------
# /etc/hosts must be root:wheel mode 0644. The Y-1 patch fixed a regression
# where `sudo mv tmp /etc/hosts` left the file owned by the invoking user;
# this check guarantees that regression cannot ship silently again.
verify_etc_hosts_correctly_owned() {
  local owner mode
  owner="$(stat -f '%Su:%Sg' /etc/hosts 2>/dev/null || true)"
  mode="$(stat -f '%Lp' /etc/hosts 2>/dev/null || true)"
  if [[ "$owner" != "root:wheel" ]]; then
    printf 'verify_etc_hosts_correctly_owned: /etc/hosts owner is %s (expected root:wheel)\n' \
      "${owner:-<unknown>}" >&2
    printf '  fix: sudo chown root:wheel /etc/hosts && sudo chmod 644 /etc/hosts\n' >&2
    return 1
  fi
  if [[ "$mode" != "644" ]]; then
    printf 'verify_etc_hosts_correctly_owned: /etc/hosts mode is %s (expected 644)\n' \
      "${mode:-<unknown>}" >&2
    printf '  fix: sudo chmod 644 /etc/hosts\n' >&2
    return 1
  fi
  return 0
}

# --- verify_sweep_aliases ---------------------------------------------------
# Convenience: run verify_alias_routable for every enabled alias in
# aliases.tsv. Returns 0 if all pass, non-zero with a summary if any fail.
# Used by Phase 00·V and `vz-ai-stack.sh verify`.
verify_sweep_aliases() {
  # network.sh exposes aliases_load + ALIAS_IP/ALIASES_LIST.
  if ! declare -p ALIASES_LIST >/dev/null 2>&1; then
    aliases_load || return 1
  fi
  local a ip fails=()
  for a in "${ALIASES_LIST[@]}"; do
    ip="${ALIAS_IP[$a]}"
    if ! verify_alias_routable "$ip" 2>/dev/null; then
      fails+=("$a ($ip)")
    fi
  done
  if (( ${#fails[@]} > 0 )); then
    printf 'verify_sweep_aliases: %d alias(es) not routable: %s\n' \
      "${#fails[@]}" "${fails[*]}" >&2
    return 1
  fi
  return 0
}
