# arize_phoenix is in the LiteLLM callbacks list AND the OTLP exporter is not
# emitting errors. A healthy exporter logs NOTHING on success, so we do NOT
# require proof-of-success — we only hard-fail on an explicit OTLP *error*
# line (e.g. "Failed to export batch", connection refused, 401/403). Absence
# of activity (fresh container, quiet success) stays green.
CHECKS+=(arize_phoenix_callback)
CHECK_TITLE[arize_phoenix_callback]="arize_phoenix callback in config.yaml AND OTLP exporter active"
FIX_CAPABLE[arize_phoenix_callback]=1   # <name>_fix MUTATES state (see doctor.sh FIX_CAPABLE)

arize_phoenix_callback_diagnose() {
  if [[ ! -f "$AI_STACK/litellm/config.yaml" ]]; then
    echo "litellm/config.yaml missing"
    return 1
  fi
  if ! litellm_has_callback arize_phoenix; then
    echo "arize_phoenix not in litellm_settings.callbacks"
    return 1
  fi
  if container_running litellm; then
    # Only inspect logs once the container has been up > 2 min (a fresh
    # container has no logs yet). Even then we look ONLY for explicit OTLP
    # error lines — a healthy exporter is silent on success.
    #
    # We compute uptime in Python because macOS `date -j -f` parses RFC3339
    # without the Z suffix as LOCAL time, which produces a TZ-shifted epoch
    # and breaks the > 120s check.
    #
    # F20: if the Python calc fails (python3 unavailable, docker inspect
    # returns malformed data, etc.) we must NOT silently stay green — the
    # 120s guard would be disabled and any OTLP error in the logs would go
    # undetected. We distinguish "calc failed" (uptime_sec=FAIL sentinel) from
    # "container just started" (uptime_sec=0 from Python itself), so we can
    # WARN on the former and skip on the latter without conflating them.
    local raw_started uptime_sec _uptime_calc_ok=1
    raw_started="$(docker inspect litellm --format '{{.State.StartedAt}}' 2>/dev/null || echo "")"
    uptime_sec="$(
      python3 - <<PY 2>/dev/null
import datetime, sys
raw = "${raw_started}"
if not raw:
    print(0); sys.exit(0)
# RFC3339 with trailing Z and optional fractional seconds.
s = raw.rstrip("Z")
if "." in s:
    s = s.split(".")[0]
dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").replace(
    tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(tz=datetime.timezone.utc)
print(int((now - dt).total_seconds()))
PY
    )" || { _uptime_calc_ok=0; uptime_sec=0; }
    # Guard: if the calc failed the uptime is unknown — emit an advisory WARN
    # rather than silently skipping the OTLP error check (false GREEN risk).
    if [[ "$_uptime_calc_ok" == "0" ]]; then
      echo "  (advisory) could not compute litellm container uptime — OTLP error log check skipped (verify manually: docker logs litellm | grep -i 'failed to export')"
    fi
    : "${uptime_sec:=0}"
    if [[ "$_uptime_calc_ok" == "1" ]] && (( uptime_sec > 120 )); then
      # A healthy, quiet exporter logs NOTHING on success — so the absence of a
      # success line proves nothing. Only hard-fail on an EXPLICIT OTLP error
      # line (export failure / refused connection / auth reject). Quiet success
      # is the common case on a fresh stack and must stay green.
      # grep -c consumes ALL of the streaming `docker logs` output — a -q here
      # raced under pipefail (docker logs SIGPIPE rc 141 wins the pipeline), so a
      # REAL OTLP error could read as "no error" (false GREEN). Count, then judge.
      local otlp_errs
      otlp_errs="$(docker logs litellm 2>&1 | grep -ciE 'failed to export batch|otlp.*(connection refused|failed)|export batch code: (401|403)')" || otlp_errs=0
      [[ "$otlp_errs" =~ ^[0-9]+$ ]] || otlp_errs=0
      if (( otlp_errs > 0 )); then
        echo "litellm logs show an OTLP export error — Phoenix endpoint unreachable or rejecting (see check 04/13)"
        return 1
      fi
    fi
    # Fresh container or no traffic yet: pass — callback is in config.yaml,
    # the container is running, that's all we can assert without traffic.
  fi
}

arize_phoenix_callback_fix() {
  litellm_ensure_callback arize_phoenix
  queue_restart litellm
}
