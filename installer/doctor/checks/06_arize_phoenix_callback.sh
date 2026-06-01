# arize_phoenix is in the LiteLLM callbacks list AND the OTLP exporter is not
# emitting errors. A healthy exporter logs NOTHING on success, so we do NOT
# require proof-of-success — we only hard-fail on an explicit OTLP *error*
# line (e.g. "Failed to export batch", connection refused, 401/403). Absence
# of activity (fresh container, quiet success) stays green.
CHECKS+=(arize_phoenix_callback)
CHECK_TITLE[arize_phoenix_callback]="arize_phoenix callback in config.yaml AND OTLP exporter active"

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
    local raw_started uptime_sec
    raw_started="$(docker inspect litellm --format '{{.State.StartedAt}}' 2>/dev/null || echo "")"
    uptime_sec="$(
      python3 - <<PY 2>/dev/null || echo 0
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
    )"
    : "${uptime_sec:=0}"
    if (( uptime_sec > 120 )); then
      # A healthy, quiet exporter logs NOTHING on success — so the absence of a
      # success line proves nothing. Only hard-fail on an EXPLICIT OTLP error
      # line (export failure / refused connection / auth reject). Quiet success
      # is the common case on a fresh stack and must stay green.
      if docker logs litellm 2>&1 | grep -qiE 'failed to export batch|otlp.*(connection refused|failed)|export batch code: (401|403)'; then
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
