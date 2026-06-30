#!/usr/bin/env bash
# installer/lib/hermes.sh — shared helpers for the Hermes messaging gateway.
#
# The native hermes gateway runs INSIDE the hermes-fleet-v1 OpenShell sandbox and
# serves EVERY configured channel from a SINGLE process (`hermes gateway run`).
# Telegram is wired by Phase 20, Slack by Phase 38 — both restart this one gateway,
# so the restart primitive lives here (ONE place) and each phase/start-script does
# only its own channel-specific log post-checks.
#
# NOT a standalone script — `source` it AFTER installer/lib/common.sh (it uses err).

# Allow callers to override, but default to the fleet sandbox + its gateway log.
HERMES_SANDBOX="${HERMES_SANDBOX:-hermes-fleet-v1}"
HERMES_GW_LOG="${HERMES_GW_LOG:-/sandbox/.hermes-gateway.log}"   # in-sandbox path

# Drop NULs (hermes' box-draw banner) + ANSI so downstream grep/awk are robust.
# LC_ALL=C so tr/sed treat the log as bytes — the banner carries non-UTF8 bytes that
# make a UTF-8-locale tr abort with "Illegal byte sequence".
hermes_strip() { LC_ALL=C tr -d '\000' | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g'; }

hermes_resolve_openshell() {
  if [[ -n "${HERMES_OPEN_SHELL_BIN:-}" && -x "$HERMES_OPEN_SHELL_BIN" ]]; then echo "$HERMES_OPEN_SHELL_BIN"
  elif [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
}

# Echo the sandbox's Phase state (e.g. "Ready"); empty if absent.
hermes_sandbox_state() {
  local osh="$1"
  "$osh" sandbox get "$HERMES_SANDBOX" 2>/dev/null | hermes_strip \
    | awk '/^[[:space:]]*Phase:/ {print $2; exit}'
}

# Tail the in-sandbox gateway log (channel post-checks read this). $1 = lines (25).
hermes_gateway_log_tail() {
  local osh n="${1:-25}"; osh="$(hermes_resolve_openshell)"; [[ -n "$osh" ]] || return 1
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    bash -c "tail -$n $HERMES_GW_LOG 2>/dev/null" 2>&1 | hermes_strip
}

# Best-effort PID from a `hermes gateway status` string ('?' if absent).
hermes_gateway_pid() {
  grep -oiE 'PID:? *[0-9]+' <<<"${1:-${HERMES_GW_STATUS:-}}" | grep -oE '[0-9]+' | head -1 || echo '?'
}

# (Re)start the ONE gateway so it re-reads ~/.hermes/.env + config.yaml and serves
# EVERY configured channel. Idempotent: `run --replace` tears down any prior gateway
# and ends with exactly one running. CHANNEL-AGNOSTIC — callers do their own per-
# channel log post-checks. On success returns 0 and leaves the status text in
# HERMES_GW_STATUS; on failure returns 1 (HERMES_GW_STATUS still holds what we saw).
hermes_gateway_restart() {
  local osh; osh="$(hermes_resolve_openshell)"
  [[ -n "$osh" ]] || { err "openshell not on PATH — run phase 04"; return 1; }

  local state; state="$(hermes_sandbox_state "$osh")"
  if [[ "$state" != "Ready" ]]; then
    err "sandbox $HERMES_SANDBOX not Ready (state='${state:-absent}') — OpenShell relay down? 'brew services restart openshell'"
    return 1
  fi

  # Detach inside the sandbox: nohup + disown so the exec returns while the gateway
  # persists (reparented to the container init). --replace ensures exactly one.
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 45 -- \
    bash -c "nohup hermes gateway run --replace >$HERMES_GW_LOG 2>&1 & disown; sleep 4; echo detached" \
    >/dev/null 2>&1 || { err "failed to launch gateway in sandbox $HERMES_SANDBOX"; return 1; }

  sleep 2
  HERMES_GW_STATUS="$("$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 30 -- hermes gateway status 2>&1 | hermes_strip)"
  grep -qi 'running' <<<"$HERMES_GW_STATUS"
}

# --- Gateway-CONFIG durability (snapshot / restore) --------------------------
# The COMPLETE gateway config (model/provider/fallback + Slack allowlist/home-channel) lives in the
# sandbox's EPHEMERAL ~/.hermes/config.yaml. A sandbox recreate, or a relay-hang during Phase
# 04f's `hermes config set`, can GUT it (seen 2026-06-29: a 2-line config — no model/provider →
# the bot can't infer AND Slack auth breaks at once). These keep a HOST snapshot (installer/state/,
# gitignored — it holds the scoped LiteLLM key) so a gutted config can be restored. They use
# DOCKER, never the openshell relay (which HANGS under the very thrash that causes the gut). The
# watchdog (W5) self-heals continuously; these back doctor check 68 + `vz-ai-stack.sh hermes config`.
HERMES_GW_CONFIG_IN="/sandbox/.hermes/config.yaml"
hermes_gw_snapshot_path() { echo "${AI_STACK:?AI_STACK unset}/installer/state/hermes-gateway-config.snapshot.yaml"; }
_hermes_docker() { local p; for p in /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v docker 2>/dev/null || echo ""; }
_hermes_cid() { local d="$1"; "$d" ps -q --filter "name=openshell-${HERMES_SANDBOX}-" 2>/dev/null | head -1; }
# Restore-TRIGGER vs snapshot-PROMOTE use DIFFERENT gates (council B2/W4). KEEP byte-identical with
# bin/openshell-watchdog.sh::_config_{complete,gutted,promotable}.
#   complete   = has top-level model+provider (the inference keys a gut loses).
#   gutted     = NOT complete AND tiny (<=7 lines) — a TRUE truncation (the 2-line 19:32 gut), NOT a
#                future Hermes schema-restructure (a full config nested differently is many lines):
#                restoring over a large restructured config would clobber a healthy upgrade.
#   promotable = complete AND the default model is CLOUD (not a local-* gate). Snapshotting a
#                local-gated config would later RESTORE it -> load a local model -> OOM the box.
hermes_gw_config_complete()   { grep -qE '^model:' <<<"${1:-}" && grep -qE '^providers:' <<<"${1:-}"; }
hermes_gw_config_gutted()     { [[ -n "${1:-}" ]] && ! hermes_gw_config_complete "${1:-}" && (( $(grep -c '' <<<"${1:-}") <= 7 )); }
hermes_gw_config_promotable() { hermes_gw_config_complete "${1:-}" && ! grep -qE '^[[:space:]]*default:[[:space:]]*local(-[a-z0-9]+)?[[:space:]]*$' <<<"${1:-}"; }
# Echo the live in-sandbox config to stdout; rc 1 if docker / the sandbox container is absent.
hermes_gw_config_read() {
  local d c; d="$(_hermes_docker)"; [[ -n "$d" ]] || return 1
  c="$(_hermes_cid "$d")"; [[ -n "$c" ]] || return 1
  "$d" exec "$c" sh -c "cat $HERMES_GW_CONFIG_IN 2>/dev/null"
}
# Snapshot the live config to the host — ONLY a PROMOTABLE (healthy CLOUD) config; the file holds the
# scoped key so it is written 0600. Never overwrites a good snapshot with a gut or a local-gated config.
hermes_gw_snapshot() {
  local t s; t="$(hermes_gw_config_read)" || return 1
  hermes_gw_config_promotable "$t" || return 2
  s="$(hermes_gw_snapshot_path)"; printf '%s' "$t" > "$s.tmp" && chmod 600 "$s.tmp" && mv -f "$s.tmp" "$s"
}
# Restore the host snapshot into the sandbox (the caller restarts the gateway). rc 1 unless the snapshot
# is itself PROMOTABLE (healthy cloud) — never restore a stale/local/gutted snapshot.
hermes_gw_restore() {
  local d c s; s="$(hermes_gw_snapshot_path)"
  [[ -s "$s" ]] && hermes_gw_config_promotable "$(cat "$s")" || return 1
  d="$(_hermes_docker)"; [[ -n "$d" ]] || return 1
  c="$(_hermes_cid "$d")"; [[ -n "$c" ]] || return 1
  "$d" cp "$s" "$c:$HERMES_GW_CONFIG_IN"
}

# --- Owner/admin commands (dispatched by `vz-ai-stack.sh hermes config|slack`) -
# Relaunch the gateway via docker so it reloads ~/.hermes/{.env,config.yaml} after an admin change.
_hermes_gw_relaunch_docker() {
  local d c; d="$(_hermes_docker)"; c="$(_hermes_cid "$d")"; [[ -n "$c" ]] || return 1
  "$d" exec -d "$c" sh -c "export HOME=/sandbox; cd /sandbox; nohup /sandbox/.venv/bin/hermes gateway run --replace >/sandbox/.hermes-gateway.log 2>&1" >/dev/null 2>&1
}
# `hermes config {snapshot|restore|show}` — gateway-config durability for the owner.
hermes_cmd_config() {
  case "${1:-show}" in
    snapshot)
      if hermes_gw_snapshot; then echo "snapshotted the live gateway config -> $(hermes_gw_snapshot_path)"
      else echo "NOT snapshotted: live config is gutted or the sandbox is down (refusing to overwrite a good snapshot with a gut)"; return 1; fi ;;
    restore)
      if hermes_gw_restore; then _hermes_gw_relaunch_docker || true; echo "restored the gateway config from the host snapshot + relaunched the gateway — DM the bot to confirm"
      else echo "NO healthy host snapshot to restore ($(hermes_gw_snapshot_path)) — run 'vz-ai-stack.sh install 04f'"; return 1; fi ;;
    show|status|"")
      local live s; live="$(hermes_gw_config_read 2>/dev/null)" || { echo "hermes-fleet sandbox not running"; return 1; }
      hermes_gw_config_complete "$live" && echo "live gateway config: COMPLETE (model+provider present)" \
        || echo "live gateway config: GUTTED (no model/provider) — run 'hermes config restore' or 'install 04f'"
      s="$(hermes_gw_snapshot_path)"
      if [[ -s "$s" ]]; then echo "host snapshot: present ($(wc -l <"$s" | tr -d ' ') lines, $(hermes_gw_config_complete "$(cat "$s")" && echo complete || echo GUTTED))"; else echo "host snapshot: none yet"; fi ;;
    *) echo "usage: vz-ai-stack.sh hermes config {snapshot|restore|show}"; return 2 ;;
  esac
}
# `hermes slack {allow <id...>|allow-all|deny-all|list}` — owner allowlist control. Writes the
# AUTHORITATIVE store: SLACK_ALLOWED_USERS / SLACK_ALLOW_ALL_USERS in the sandbox config.yaml via
# `hermes config set` (the SAME store Phase 38 uses; run.py:888-902 bridges config.yaml top-level keys
# into os.environ AFTER loading .env, so config.yaml WINS, and slack.py:2813 reads os.getenv). config.yaml
# is covered by the W5 host snapshot, so a command-set allowlist survives restart/reboot/revive. (A
# destructive sandbox RECREATE re-derives it from HERMES_SLACK_ALLOWED_USERS in the HOST .env via Phase 38
# — set that too if you want it to survive a recreate.) ids are validated before interpolation (no shell
# injection into the docker-exec). Relaunches the gateway so the change takes effect.
hermes_cmd_slack() {
  local d c cfg=/sandbox/.hermes/config.yaml; d="$(_hermes_docker)"; c="$(_hermes_cid "$d")"
  [[ -n "$c" ]] || { echo "hermes-fleet sandbox not running — run 'vz-ai-stack.sh install 04'"; return 1; }
  local _set="export HOME=/sandbox; /sandbox/.venv/bin/hermes config set"
  case "${1:-list}" in
    list)
      "$d" exec "$c" sh -c "grep -E '^SLACK_ALLOWED_USERS:|^SLACK_ALLOW_ALL_USERS:' $cfg 2>/dev/null" \
        || echo "(no Slack allowlist set — bot is LOCKED, denies all)" ;;
    allow)
      shift; local ids="$*"; [[ -n "$ids" ]] || { echo "usage: vz-ai-stack.sh hermes slack allow <slack_user_id> [<id2> ...]"; return 2; }
      ids="${ids// /,}"
      [[ "$ids" =~ ^[A-Za-z0-9,]+$ ]] || { echo "invalid Slack id(s) '$ids' — expect alphanumeric member id(s) (U…/W…), comma-separated"; return 2; }
      "$d" exec "$c" sh -c "$_set SLACK_ALLOWED_USERS '$ids' >/dev/null 2>&1; $_set SLACK_ALLOW_ALL_USERS false >/dev/null 2>&1"
      _hermes_gw_relaunch_docker || true; echo "Slack allowlist set to [$ids] (config.yaml) + relaunched — DM the bot to confirm" ;;
    allow-all)
      "$d" exec "$c" sh -c "$_set SLACK_ALLOW_ALL_USERS true >/dev/null 2>&1; $_set SLACK_ALLOWED_USERS '' >/dev/null 2>&1"
      _hermes_gw_relaunch_docker || true; echo "Slack OPEN ACCESS (SLACK_ALLOW_ALL_USERS=true, allowlist cleared) — ANY workspace member can use the bot. Prefer 'allow <id>'." ;;
    deny-all)
      "$d" exec "$c" sh -c "$_set SLACK_ALLOWED_USERS '' >/dev/null 2>&1; $_set SLACK_ALLOW_ALL_USERS false >/dev/null 2>&1"
      _hermes_gw_relaunch_docker || true; echo "Slack LOCKED (allowlist cleared, allow-all=false) — bot denies all until 'hermes slack allow <id>'." ;;
    *) echo "usage: vz-ai-stack.sh hermes slack {allow <id...>|allow-all|deny-all|list}"; return 2 ;;
  esac
}
