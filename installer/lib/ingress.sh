# ingress.sh — bare-hostname host ingress.
#
# Generates a Caddyfile from aliases.tsv and manages a host-native Caddy daemon
# that binds each HTTP service's own 127.0.10.x:80/:443 and reverse-proxies to
# its existing native-port publish — giving the Mac browser `http(s)://litellm/`
# while leaving `name:port` and container traffic untouched.
#
# Single source of truth = installer/lib/aliases.tsv. This file REUSES
# network.sh::aliases_load — it does NOT re-parse the TSV.
#
# Dual-mode: sourced by vz-ai-stack.sh / 00n_networking.sh / reset.sh, OR run
# directly as the `ingress` CLI (bin/ingress → `vz-ai-stack.sh ingress …`).
#
# Design: doc/specs/2026-06-21-bare-hostname-ingress.md

# When RUN DIRECTLY, self-resolve AI_STACK from this file's path (../..),
# matching docker-engine.sh / fleet.sh shape, so the CLI works standalone.
if [[ -z "${AI_STACK:-}" ]]; then
  AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" \
    || { echo "ingress.sh: AI_STACK unset and unresolvable" >&2; exit 2; }
fi

# Pull deps when run directly (or sourced before them); guard on a known fn from each.
declare -F log          >/dev/null 2>&1 || source "$AI_STACK/installer/lib/common.sh"
declare -F aliases_load >/dev/null 2>&1 || source "$AI_STACK/installer/lib/network.sh"

# Idempotent source guard. A bare `return` is illegal on a DIRECT run, so only
# short-circuit when actually sourced (BASH_SOURCE[0] != $0) AND already loaded.
[[ "${BASH_SOURCE[0]}" != "${0}" && -n "${_AI_STACK_INGRESS_LOADED:-}" ]] && return 0
_AI_STACK_INGRESS_LOADED=1

# Generated artifacts + the launchd daemon identity.
INGRESS_LABEL="${INGRESS_LABEL:-com.ai-stack.ingress}"
INGRESS_CADDYFILE="${INGRESS_CADDYFILE:-$AI_STACK/installer/state/Caddyfile.ai-stack}"
INGRESS_WRAPPER="${INGRESS_WRAPPER:-$AI_STACK/installer/state/ingress-run.sh}"
INGRESS_PLIST="${INGRESS_PLIST:-/Library/LaunchDaemons/com.ai-stack.ingress.plist}"
INGRESS_ADMIN_SOCK="${INGRESS_ADMIN_SOCK:-/var/run/ai-stack-caddy-admin.sock}"
INGRESS_LOG_OUT="${INGRESS_LOG_OUT:-/var/log/ai-stack-ingress.out}"
INGRESS_LOG_ERR="${INGRESS_LOG_ERR:-/var/log/ai-stack-ingress.err}"

# ingress_caddy_bin — absolute path to the caddy binary (launchd has no brew
# PATH). Prefers $PATH, then the Homebrew arm64 location; falls back to the bare
# name so an absent caddy fails visibly rather than silently.
ingress_caddy_bin() {
  local c
  c="$(command -v caddy 2>/dev/null || true)"
  [[ -n "$c" ]] && { printf '%s' "$c"; return 0; }
  # sudo resets PATH (drops /opt/homebrew) — probe the known Homebrew locations
  # so the daemon-install path works under `sudo ingress up`.
  for c in /opt/homebrew/bin/caddy /usr/local/bin/caddy; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ingress_alias_in_scope <alias> — true iff this alias ROW gets a port-free site:
# protocol == http AND IP in 127.0.10.x. Excludes redis/grpc and the 127.0.0.1
# daemons (openwork/aionui). Keyed on the alias row (never service_key) so
# `falkordb-ui` (http, .8) is in but `falkordb` (redis, .7) is out.
ingress_alias_in_scope() {
  local a="$1"
  [[ "${ALIAS_PROTOCOL[$a]:-}" == "http" ]] || return 1
  [[ "${ALIAS_IP[$a]:-}" =~ ^127\.0\.10\. ]] || return 1
  return 0
}

# ingress_caddyfile_content — echo the canonical Caddyfile. Per in-scope alias,
# two EXPLICIT site blocks (no auto HTTP->HTTPS redirect): an http:// site and an
# https:// site (tls internal), both `bind`-ing the alias's own IP and
# reverse-proxying to <ip>:<native_port>. Pure / deterministic (AC-4). A site is
# emitted regardless of upstream liveness (a down service 502s by design — the
# bind must exist for the AC-2 no-collision proof).
ingress_caddyfile_content() {
  aliases_load || return 1
  printf '{\n\tadmin unix/%s\n}\n' "$INGRESS_ADMIN_SOCK"
  local a ip port
  for a in "${ALIASES_LIST[@]}"; do
    ingress_alias_in_scope "$a" || continue
    ip="${ALIAS_IP[$a]}"; port="${ALIAS_HOST_PORT[$a]}"
    printf '\nhttp://%s {\n\tbind %s\n\treverse_proxy %s:%s\n}\n' "$a" "$ip" "$ip" "$port"
    printf 'https://%s {\n\tbind %s\n\ttls internal\n\treverse_proxy %s:%s\n}\n' "$a" "$ip" "$ip" "$port"
  done
}

# ingress_wrapper_content — the launchd wrapper. Waits (bounded) for the first
# lo0 alias 127.0.10.1 to exist before exec'ing caddy, so the daemon can't lose
# a boot race against the loopback persistence daemon (EADDRNOTAVAIL). Caddy +
# Caddyfile paths are baked in at generate time (launchd has no PATH).
ingress_wrapper_content() {
  local cbin; cbin="$(ingress_caddy_bin)"
  cat <<EOF
#!/bin/sh
# ai-stack ingress launch wrapper (generated — do not edit). See ingress.sh.
n=0
until /sbin/ifconfig lo0 2>/dev/null | grep -q '127\\.0\\.10\\.1'; do
  n=\$((n+1))
  if [ "\$n" -ge 120 ]; then
    echo "ingress-wrapper: lo0 alias 127.0.10.1 never appeared after 60s" >&2
    exit 1
  fi
  sleep 0.5
done
exec "$cbin" run --config "$INGRESS_CADDYFILE" --adapter caddyfile
EOF
}

# ingress_plist_content — the root LaunchDaemon. DIVERGES from the one-shot
# loopback plist: a long-running daemon needs KeepAlive-on-crash (NOT a bare
# true, which would fight `ingress down`), a ThrottleInterval so a
# validate-passing/runtime-failing config can't spin launchd, and BOTH std
# streams (a bad-config reason prints to stdout). RunAtLoad for reboot survival.
ingress_plist_content() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$INGRESS_LABEL</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$INGRESS_WRAPPER</string>
  </array>
  <key>StandardOutPath</key>
  <string>$INGRESS_LOG_OUT</string>
  <key>StandardErrorPath</key>
  <string>$INGRESS_LOG_ERR</string>
</dict>
</plist>
EOF
}

# ingress_write_caddyfile [dest] — write the generated Caddyfile idempotently
# (cmp-before-write, repo idiom: a no-op when unchanged, no churn). Returns 0
# either way. Validates with `caddy validate` first when caddy is present, so one
# malformed site can't black-hole all 13.
ingress_write_caddyfile() {
  local dest="${1:-$INGRESS_CADDYFILE}" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)" || return 1
  if ! ingress_caddyfile_content > "$tmp"; then rm -f "$tmp"; err "ingress: generation failed"; return 1; fi
  local cbin; cbin="$(ingress_caddy_bin || true)"
  if [[ -n "$cbin" ]]; then
    "$cbin" validate --config "$tmp" --adapter caddyfile >/dev/null 2>&1 \
      || { rm -f "$tmp"; err "ingress: generated Caddyfile failed validation — keeping existing"; return 1; }
  fi
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; log "ingress: Caddyfile already current: $dest"; return 0
  fi
  mv "$tmp" "$dest"
  ok "ingress: wrote Caddyfile ($(grep -c '^http://' "$dest" 2>/dev/null || echo 0) sites): $dest"
}

# ingress_status — report what's installed/loaded (offline-safe; no privilege).
ingress_status() {
  local cbin; cbin="$(ingress_caddy_bin || true)"
  if [[ -n "$cbin" ]]; then
    ok "caddy: $cbin ($("$cbin" version 2>/dev/null | head -1))"
  else
    warn "caddy: not installed — run 'brew install caddy'"
  fi
  if [[ -f "$INGRESS_CADDYFILE" ]]; then
    ok "Caddyfile: $INGRESS_CADDYFILE ($(grep -c '^http://' "$INGRESS_CADDYFILE" 2>/dev/null || echo 0) sites)"
  else
    note "Caddyfile: not generated (run: ingress generate)"
  fi
  if launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1; then
    ok "daemon: loaded ($INGRESS_LABEL)"
  else
    note "daemon: not loaded ($INGRESS_LABEL)"
  fi
}

# --- Live commands (execute only with caddy + sudo; E2E-gated on M0/M0b) -----

# ingress_install_daemon — install the wrapper (0755) + root plist (0644)
# idempotently, mirroring lo0_install_persistence_plist (cmp-before-write +
# EUID/sudo-defer), then (re)bootstrap into the system domain.
ingress_install_daemon() {
  mkdir -p "$(dirname "$INGRESS_WRAPPER")"
  local wtmp; wtmp="$(mktemp)" || return 1
  ingress_wrapper_content > "$wtmp"
  if [[ ! -f "$INGRESS_WRAPPER" ]] || ! cmp -s "$wtmp" "$INGRESS_WRAPPER"; then
    mv "$wtmp" "$INGRESS_WRAPPER"; chmod 0755 "$INGRESS_WRAPPER"
  else rm -f "$wtmp"; fi

  local ptmp; ptmp="$(mktemp)" || return 1
  ingress_plist_content > "$ptmp"
  if [[ -f "$INGRESS_PLIST" ]] && cmp -s "$ptmp" "$INGRESS_PLIST" \
       && launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1; then
    rm -f "$ptmp"; ok "ingress daemon already current + loaded"; return 0
  fi
  if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
    rm -f "$ptmp"
    warn "ingress daemon needs sudo to (re)install; sudo unavailable non-interactively."
    note "Run 'sudo bash vz-ai-stack.sh ingress up' to install the port-80 daemon."
    return 0
  fi
  local SUDO=""; (( EUID != 0 )) && SUDO="sudo"
  $SUDO install -m 644 -o root -g wheel "$ptmp" "$INGRESS_PLIST" \
    || { err "install failed for $INGRESS_PLIST"; rm -f "$ptmp"; return 1; }
  rm -f "$ptmp"
  $SUDO launchctl bootout system "$INGRESS_PLIST" 2>/dev/null || true
  $SUDO launchctl bootstrap system "$INGRESS_PLIST" 2>/dev/null \
    || $SUDO launchctl load "$INGRESS_PLIST" 2>/dev/null \
    || { err "launchctl bootstrap failed for $INGRESS_LABEL"; return 1; }
  ok "ingress daemon installed + bootstrapped: $INGRESS_LABEL"
}

# ingress_up — the main entrypoint: ensure caddy, (re)generate+validate the
# Caddyfile, then reload a running daemon (zero-downtime) or install a fresh one.
ingress_up() {
  ingress_caddy_bin >/dev/null || { err "caddy not installed — run 'brew install caddy'"; return 1; }
  ingress_write_caddyfile || return 1
  if launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1; then
    ingress_reload || return 1
  else
    ingress_install_daemon || return 1
  fi
  ingress_status
}

# ingress_reload — push a config change with zero downtime via the admin socket;
# fall back to a daemon (re)install if the admin endpoint is unreachable.
ingress_reload() {
  local cbin; cbin="$(ingress_caddy_bin)" || { err "caddy not installed"; return 1; }
  ingress_write_caddyfile || return 1
  if "$cbin" reload --config "$INGRESS_CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    ok "ingress: caddy reloaded (zero-downtime)"
  else
    warn "ingress: caddy reload failed (admin socket unreachable?) — reinstalling daemon"
    ingress_install_daemon
  fi
}

# ingress_down — stop the daemon (plist stays; 'ingress up' restarts it).
ingress_down() {
  if [[ -f "$INGRESS_PLIST" ]]; then
    local SUDO=""; (( EUID != 0 )) && SUDO="sudo"
    $SUDO launchctl bootout system "$INGRESS_PLIST" 2>/dev/null \
      || $SUDO launchctl unload "$INGRESS_PLIST" 2>/dev/null || true
    ok "ingress daemon stopped (plist remains)"
  else
    note "ingress daemon not installed"
  fi
}

# _ingress_ca_crt — locate Caddy's local root CA cert (the daemon runs as root,
# so its data dir is root's home; fall back to the user's). Echo path or fail.
_ingress_ca_crt() {
  [[ -n "${INGRESS_CA_CRT:-}" ]] && { printf '%s' "$INGRESS_CA_CRT"; return 0; }
  local p
  for p in \
    "/var/root/Library/Application Support/Caddy/pki/authorities/local/root.crt" \
    "$HOME/Library/Application Support/Caddy/pki/authorities/local/root.crt"; do
    if [[ -f "$p" ]] || sudo test -f "$p" 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# ingress_trust — install Caddy's local root CA into the USER LOGIN keychain
# (NOT system-wide), so https://litellm/ is browser-trusted for this user only.
# Triggers a macOS GUI auth dialog (login-keychain trust is interactive — must
# run in a GUI session). M0b-verified.
ingress_trust() {
  local crt; crt="$(_ingress_ca_crt)" \
    || { err "Caddy root CA not found — start the ingress first ('ingress up')"; return 1; }
  local tmp; tmp="$(mktemp).crt"
  sudo cat "$crt" > "$tmp" 2>/dev/null || cp "$crt" "$tmp" 2>/dev/null \
    || { err "cannot read Caddy root CA at $crt"; rm -f "$tmp"; return 1; }
  security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$tmp" \
    && ok "ingress: Caddy root CA trusted in login keychain (quit+reopen the browser)" \
    || { err "ingress trust failed (GUI auth required?)"; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# ingress_untrust — remove the Caddy root CA from the login keychain.
ingress_untrust() {
  local crt; crt="$(_ingress_ca_crt)" || { note "no Caddy root CA to untrust"; return 0; }
  local tmp; tmp="$(mktemp).crt"; sudo cat "$crt" > "$tmp" 2>/dev/null || cp "$crt" "$tmp" 2>/dev/null || true
  security remove-trusted-cert "$tmp" 2>/dev/null || true
  security delete-certificate -c "Caddy Local Authority" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
  rm -f "$tmp"
  ok "ingress: Caddy root CA untrusted (login keychain)"
}

# ingress_teardown <tier> — reverse install. hard: stop daemon + remove plist +
# wrapper + Caddyfile + logs, free :80/:443. nuke: also untrust CA + wipe Caddy
# data dir. Best-effort + loud; SIGKILL a surviving owned caddy. (reset.sh hook)
ingress_teardown() {
  local tier="${1:-hard}" SUDO=""; (( EUID != 0 )) && SUDO="sudo"
  ingress_down
  $SUDO rm -f "$INGRESS_PLIST" "$INGRESS_WRAPPER" "$INGRESS_CADDYFILE" \
              "$INGRESS_LOG_OUT" "$INGRESS_LOG_ERR" 2>/dev/null || true
  # Free :80/:443 if a caddy we own lingers.
  local pid
  for pid in $(lsof -nP -iTCP:80 -iTCP:443 -sTCP:LISTEN -t 2>/dev/null | sort -u); do
    ps -o comm= -p "$pid" 2>/dev/null | grep -qi caddy && { $SUDO kill -9 "$pid" 2>/dev/null || true; }
  done
  if [[ "$tier" == "nuke" ]]; then
    ingress_untrust 2>/dev/null || true
    $SUDO rm -rf "/var/root/Library/Application Support/Caddy" \
                 "$HOME/Library/Application Support/Caddy" 2>/dev/null || true
  fi
  ok "ingress: torn down ($tier)"
}

# --- CLI (run-direct only) --------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _cmd="${1:-status}"; shift 2>/dev/null || true
  case "$_cmd" in
    up)               ingress_up "$@" ;;
    down)             ingress_down "$@" ;;
    reload)           ingress_reload "$@" ;;
    status)           ingress_status ;;
    trust)            ingress_trust "$@" ;;
    untrust)          ingress_untrust "$@" ;;
    teardown)         ingress_teardown "$@" ;;
    generate)         ingress_write_caddyfile "$@" ;;
    print-caddyfile)  ingress_caddyfile_content ;;
    print-plist)      ingress_plist_content ;;
    print-wrapper)    ingress_wrapper_content ;;
    *) err "ingress: unknown subcommand '$_cmd' (up|down|reload|status|trust|untrust|teardown|generate|print-*)"; exit 2 ;;
  esac
fi
