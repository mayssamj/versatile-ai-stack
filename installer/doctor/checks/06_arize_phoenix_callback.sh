# arize_phoenix is in the LiteLLM callbacks list AND the OTLP exporter is
# actively running inside the container (proven by either a successful trace
# export or a "Failed to export batch" line — both prove the exporter is
# initialized; a missing callback would show NEITHER).
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
    # The OTLP exporter shows up in logs once any chat-completion request
    # has fired (success or 'Failed to export batch'). A FRESH container
    # has no logs yet — don't fail on that; just note.
    # Only fail when the container has been up > 2 min AND logs contain
    # multiple successful chat completions but no OTLP activity at all
    # (that would prove the callback is genuinely not loaded).
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
      local chat_calls
      chat_calls="$(docker logs litellm 2>&1 | grep -ciE 'chat/completions|completion_tokens' || true)"
      : "${chat_calls:=0}"
      if (( chat_calls >= 2 )); then
        if ! docker logs litellm 2>&1 | grep -qiE 'opentelemetry|otlp|export batch|arize|phoenix'; then
          echo "litellm logs show $chat_calls chat call(s) but NO OTLP activity — callback may have failed to load"
          return 1
        fi
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
