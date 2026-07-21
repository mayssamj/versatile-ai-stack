# Phoenix has the ai-stack project (means traces are actually flowing).
CHECKS+=(phoenix_project)
CHECK_TITLE[phoenix_project]="Phoenix has 'ai-stack' project (traces flowing)"

phoenix_project_diagnose() {
  # If the 'phoenix' alias doesn't resolve (prepare-sudo not run), every curl
  # below would return 000 and mis-report as a Phoenix-specific failure. Defer
  # to the alias checks instead of false-failing here.
  dscacheutil -q host -a name phoenix 2>/dev/null | grep -q ip_address || { echo "(phoenix alias unresolved — see checks 15/19) [skip]"; return 0; }
  if ! curl -sf --max-time 3 http://phoenix:6006 >/dev/null; then
    echo "Phoenix UI not responding on :6006"
    return 1
  fi
  # Try auth-gated /v1/projects first; if 401 (auth on, no key), fall back
  # to authenticated GET via basic auth — Mayssam confirmed admin/<PHOENIX_ADMIN_PASSWORD>
  # is set.
  local KEY; KEY="$(get_env PHOENIX_API_KEY "")"
  local body
  if [[ -n "$KEY" ]]; then
    # litellm_scoped_curl is a generic bearer-via-STDIN helper (common.sh) — reused here
    # so PHOENIX_API_KEY is injected via curl --config, never on the command line / argv.
    body="$(litellm_scoped_curl "$KEY" -s --max-time 3 http://phoenix:6006/v1/projects)"
  else
    body="$(curl -s --max-time 3 http://phoenix:6006/v1/projects)"
  fi
  if [[ -z "$body" ]] || echo "$body" | grep -qiE 'unauthorized|invalid token'; then
    echo "could not fetch /v1/projects — set PHOENIX_API_KEY in .env (UI: Settings → API Keys)"
    return 1
  fi
  if ! echo "$body" | jq -r '.data[]?.name' 2>/dev/null | grep -qxF 'ai-stack'; then
    # The project only materializes after the FIRST chat-completion's OTLP
    # batch flushes. On a clean `install all` no inference has run yet, so its
    # absence is expected — advisory, not red (mirrors check 06). We treat
    # "no chat traffic yet" as: litellm up < 2 min OR no chat/completions in
    # its logs. Only stay red if Phoenix is unreachable (handled above).
    local seen_chat=0
    if container_running litellm; then
      local raw_started uptime_sec
      raw_started="$(docker inspect litellm --format '{{.State.StartedAt}}' 2>/dev/null || echo "")"
      uptime_sec="$(
        python3 - <<PY 2>/dev/null || echo 0
import datetime, sys
raw = "${raw_started}"
if not raw:
    print(0); sys.exit(0)
s = raw.rstrip("Z")
if "." in s:
    s = s.split(".")[0]
dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").replace(
    tzinfo=datetime.timezone.utc)
print(int((datetime.datetime.now(tz=datetime.timezone.utc) - dt).total_seconds()))
PY
      )"
      : "${uptime_sec:=0}"
      # grep -c consumes all of the streaming `docker logs` (a -q races under
      # pipefail — EPIPE class).
      local nchat=0
      if (( uptime_sec > 120 )); then
        nchat="$(docker logs litellm 2>&1 | grep -ciE 'chat/completions|completion_tokens')" || nchat=0
        [[ "$nchat" =~ ^[0-9]+$ ]] || nchat=0
      fi
      if (( nchat > 0 )); then
        seen_chat=1
      fi
    fi
    if (( seen_chat == 0 )); then
      echo "  (Phoenix up; no 'ai-stack' project yet — no inference has run; will appear after first chat)"
      return 0
    fi
    echo "Phoenix reachable + chat traffic has flowed, but no 'ai-stack' project — traces are NOT landing (check 06/13)"
    return 1
  fi
}

phoenix_project_fix() {
  # Do NOT auto-run inference to materialise the project — a fix path must
  # not cold-start a model (directive: doctor must not cold-start; a fix path
  # that calls chat/completions loads a model, costs tokens, and can take
  # 20-150 s on a cold local runner). Instead, advise the operator to run the
  # dedicated smoke test which is the correct, scoped, operator-controlled path.
  warn "The 'ai-stack' Phoenix project is created by the first real inference call."
  warn "Run the stack smoke test to materialise it (no side-effects beyond one trace):"
  warn "    bash $AI_STACK/vz-ai-stack.sh smoke 01"
  warn "The smoke test sends exactly one call through LiteLLM and waits for the OTLP"
  warn "batch to flush. Re-run doctor after it completes."
  return 1
}
