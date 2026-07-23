# AutoFyn agent (brain) healthy + self-heal the /workspace-shadows-/app ImportError crash-loop.
#
# autofyn's own compose mounts the host checkout at /workspace (workdir), and the :stable image runs
# `python -m server` — which puts cwd=/workspace on sys.path[0], so the stale /workspace/config/
# constants.py SHADOWS the image's /app/config/constants.py → `ImportError: cannot import name
# 'SANDBOX_KIND_DOCKER'` → crash-loop (the watchdog W1 then halts the agent at restart=no + a FAILMARK).
# The durable fix is the PYTHONSAFEPATH=1 override written by bin/start-autofyn.sh; this check ENSURES
# it and restarts the agent when down. Self-heal rules: heal (apply override + restart) when the
# override is MISSING (the fix wasn't applied) or the agent is cleanly down; but if the override is
# ALREADY present AND the watchdog W1 FAILMARK is set, the agent is crash-looping DESPITE the fix (a
# different failure) — surface it and do NOT restart (don't fight W1). Skips when autofyn isn't
# installed. The agent is the Claude-Code-SDK orchestrator (CLOUD), idle on startup — restarting ONLY
# it (`--no-deps`) loads NO local model and never touches the gVisor sandbox.
AF_DIR_AGENT="$AI_STACK/autofyn"
AF_ALERT="$AI_STACK/installer/state/openshell-watchdog.alert"   # watchdog W1 FAILMARK file (check 43 reads it)
CHECKS+=(autofyn_agent)
CHECK_TITLE[autofyn_agent]="AutoFyn agent healthy (self-heal /workspace-shadow ImportError)"

_af_agent_docker() {  # mirror the watchdog's engine-agnostic resolution order
  local p; for p in /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }; done
  command -v docker 2>/dev/null || echo /usr/local/bin/docker
}
_af_agent_state() { "$(_af_agent_docker)" inspect autofyn-agent \
  --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null; }
_af_agent_ok() { local s="${1%%|*}" h="${1#*|}"; [[ "$s" == "running" && ( "$h" == "healthy" || "$h" == "none" ) ]]; }
_af_override_ok() { [[ -f "$1" ]] && grep -q 'PYTHONSAFEPATH:' "$1" 2>/dev/null; }   # colon = the YAML key (not the comment)
_af_failmarked() { [[ -f "$AF_ALERT" ]] && grep -q 'autofyn-agent' "$AF_ALERT" 2>/dev/null; }
_af_failmark_clear() {
  [[ -f "$AF_ALERT" ]] || return 0
  # NB: grep -v exits 1 when EVERY line matches (output empty) — that's the single-FAILMARK case, so
  # DON'T `&&` the mv off grep's rc or the file never clears. Separate + guard; rm the file if now empty.
  grep -v 'autofyn-agent' "$AF_ALERT" > "$AF_ALERT.tmp" 2>/dev/null || true
  mv -f "$AF_ALERT.tmp" "$AF_ALERT" 2>/dev/null || true
  [[ -s "$AF_ALERT" ]] || rm -f "$AF_ALERT"
  return 0
}
_af_write_override() {  # IDENTICAL content to bin/start-autofyn.sh (provenance header kept)
  cat > "$1" <<'YAML'
# ai-stack managed (bin/start-autofyn.sh / doctor check 69) — do NOT hand-edit.
# PYTHONSAFEPATH=1 makes the :stable image's /app win over the mounted /workspace (a clone of the
# public repo that LAGS the image): without it `python -m server` puts cwd=/workspace on sys.path[0]
# and the stale /workspace/config/constants.py shadows /app/config/constants.py → ImportError. py3.11+.
services:
  agent:
    environment:
      PYTHONSAFEPATH: "1"
YAML
}
# Time-bound a command (no `timeout` on macOS): bg + poll + kill at N s; returns the cmd rc, or 124.
_af_bounded() { local s="$1" p w=0; shift; "$@" & p=$!
  while (( w < s*2 )); do kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null; return $?; }; sleep 0.5; w=$((w+1)); done
  kill "$p" 2>/dev/null || true; return 124; }

autofyn_agent_diagnose() {
  [[ -f "$AF_DIR_AGENT/docker-compose.yml" ]] || { echo "autofyn not installed — skip"; return 0; }
  local d ov st; d="$(_af_agent_docker)"; ov="$AF_DIR_AGENT/docker-compose.override.yml"; st="$(_af_agent_state)"
  [[ -n "$st" ]] || { echo "autofyn-agent container absent — run 'mayssam-ai-stack.sh install 07'"; return 1; }
  if _af_agent_ok "$st"; then echo "  (running, ${st#*|})"; return 0; fi
  # Agent down. Decide whether to self-heal (and why), or bail so we don't fight the watchdog.
  local reason
  if ! _af_override_ok "$ov"; then
    _af_write_override "$ov"; reason="applied the PYTHONSAFEPATH override + restarted (was the /workspace shadow ImportError)"
  elif _af_failmarked; then
    echo "autofyn-agent halted by the watchdog (crash-looping DESPITE the PYTHONSAFEPATH fix → a DIFFERENT failure, NOT the /workspace shadow; a Python <3.11 image would also do this). Inspect: docker logs autofyn-agent — then 'mayssam-ai-stack.sh install 07', or clear the alert + restart."
    return 1
  else
    reason="restarted the down agent (override already applied)"
  fi
  # Restart ONLY the agent (`--no-deps`: never touches the gVisor sandbox / dashboard / db), time-bounded.
  local out i
  out="$( ( cd "$AF_DIR_AGENT" && _af_bounded 40 "$d" compose up -d --no-deps agent 2>&1 ) )" || true
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; st="$(_af_agent_state)"; if _af_agent_ok "$st"; then break; fi; done
  if _af_agent_ok "$st"; then
    _af_failmark_clear
    echo "  AUTO-HEALED: $reason (now ${st#*|})"; return 0
  fi
  echo "autofyn-agent still '${st:-down}' after self-heal — ${out:+compose said: ${out##*$'\n'}; }check: docker logs autofyn-agent (a Python <3.11 image makes PYTHONSAFEPATH a no-op)"; return 1
}

autofyn_agent_fix() {
  warn "Repair the AutoFyn agent (the host /workspace checkout shadows the :stable image's /app config):"
  warn "  bash $AI_STACK/bin/start-autofyn.sh    # rewrites the PYTHONSAFEPATH override + recreates ONLY the agent"
  warn "  docker logs autofyn-agent              # if it stays down, the cause is NOT the /workspace shadow"
  return 1
}
