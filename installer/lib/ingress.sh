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

# macOS ships bash 3.2 at /bin/bash; `sudo bash …` picks it, and it lacks
# `declare -g` that network.sh::aliases_load needs (→ a 0-site Caddyfile). When
# RUN DIRECTLY (the `ingress` CLI) under bash <4, re-exec under a modern bash so
# `sudo … ingress up` Just Works. (Sourced contexts run as the user's bash 4+.)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$_b" ]] && exec "$_b" "$0" "$@"
  done
  echo "ingress.sh: requires bash 4+ (found ${BASH_VERSION:-?}); 'brew install bash'." >&2
  exit 2
fi

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
# Threaded signal: ingress_write_caddyfile sets this to 1 when it actually
# writes a new/changed Caddyfile, 0 when the file was already current.
# ingress_install_daemon reads this to decide whether a privileged restart
# is needed. Initialized here so it's always defined before any call.
_INGRESS_CADDYFILE_CHANGED="${_INGRESS_CADDYFILE_CHANGED:-0}"
INGRESS_CADDYFILE="${INGRESS_CADDYFILE:-$AI_STACK/installer/state/Caddyfile.ai-stack}"
INGRESS_WRAPPER="${INGRESS_WRAPPER:-$AI_STACK/installer/state/ingress-run.sh}"
INGRESS_PLIST="${INGRESS_PLIST:-/Library/LaunchDaemons/com.ai-stack.ingress.plist}"
INGRESS_LOG_OUT="${INGRESS_LOG_OUT:-/var/log/ai-stack-ingress.out}"
INGRESS_LOG_ERR="${INGRESS_LOG_ERR:-/var/log/ai-stack-ingress.err}"
# Pin Caddy's data dir (the local CA) to a stable path, so it's deterministic
# under the root launchd daemon (where $HOME is ambiguous) and `ingress trust`
# knows exactly where root.crt is. Caddy stores under $XDG_DATA_HOME/caddy.
INGRESS_DATA_DIR="${INGRESS_DATA_DIR:-$AI_STACK/installer/state/caddy-data}"

# ingress_caddy_bin — absolute path to the caddy binary (launchd has no brew
# PATH; sudo strips /opt/homebrew). $PATH first, then Homebrew locations; fail (1)
# if truly absent so callers report "not installed" rather than mis-run.
ingress_caddy_bin() {
  local c
  c="$(command -v caddy 2>/dev/null || true)"
  [[ -n "$c" ]] && { printf '%s' "$c"; return 0; }
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
  local a="$1" proto
  proto="${ALIAS_PROTOCOL[$a]:-}"   # separate line: under set -u, $a must be set BEFORE this expands
  # `http`          — service dual-binds its own alias IP; Caddy proxies <ip>:<port>.
  # `http-loopback` — service binds 127.0.0.1 only (a host process / Host-pinned viewer
  #                   added via `ingress add`); Caddy listens on the alias IP and proxies
  #                   to 127.0.0.1:<port>. Both are in-scope for the port-free `name/` site.
  [[ "$proto" == "http" || "$proto" == "http-loopback" ]] || return 1
  [[ "${ALIAS_IP[$a]:-}" =~ ^127\.0\.10\. ]] || return 1
  return 0
}

# ingress_caddyfile_content — echo the canonical Caddyfile. Global options:
#   admin off                  — no admin endpoint; we apply config by restarting
#                                the daemon, not a (fragile) reload socket.
#   auto_https disable_redirects — DON'T add an HTTP->HTTPS redirect listener
#                                (it would grab :80 and conflict with our explicit
#                                http:// sites — the bug that produced curl -> 000).
#   skip_install_trust         — NEVER touch the system trust store. As root the
#                                daemon's auto-trust would silently install a
#                                machine-wide CA; we trust opt-in via the LOGIN
#                                keychain (`ingress trust`) instead.
# Per in-scope alias, two EXPLICIT site blocks: http:// and https:// (tls
# internal), both `bind`-ing the alias's own IP. The reverse-proxy upstream depends
# on the protocol: `http` → <ip>:<native_port> (the service dual-binds its alias IP);
# `http-loopback` → 127.0.0.1:<native_port> with an upstream Host rewrite (the service
# binds 127.0.0.1 only). Pure/deterministic (AC-4). A site is emitted regardless of
# upstream liveness (a down service 502s by design — the bind must exist for the
# AC-2 no-collision proof).
ingress_caddyfile_content() {
  aliases_load || return 1
  printf '{\n\tadmin off\n\tauto_https disable_redirects\n\tskip_install_trust\n}\n'
  local a ip port lo0_ips
  # Snapshot the loopback aliases once. A site whose `bind <ip>` address is NOT on
  # lo0 makes `caddy run` fail to bind at STARTUP — and with KeepAlive=Crashed that
  # crash-loops the WHOLE daemon, taking every other ingress site down. So SKIP such
  # a site (with a warning) instead of emitting an unbindable `bind`; the operator
  # runs `sudo vz-ai-stack.sh prepare-sudo` then re-reloads and the site self-heals.
  # (`caddy validate` only checks syntax, not address availability, so it won't catch
  # this — the guard must live here. Exact-match, mirroring the start-script guards.)
  lo0_ips="$(/sbin/ifconfig lo0 2>/dev/null | grep -oE '127\.0\.10\.[0-9]+')"
  for a in "${ALIASES_LIST[@]}"; do
    ingress_alias_in_scope "$a" || continue
    ip="${ALIAS_IP[$a]}"; port="${ALIAS_HOST_PORT[$a]}"
    # INGRESS_TEST_NO_LO0_GUARD: smoke-only seam to exercise PURE generation
    # deterministically on a machine where the alias IPs aren't bound (fresh CI /
    # worktree). NEVER set in production — the guard below is the daemon's
    # crash-loop protection (the negative smoke test asserts it fires when unset).
    if [[ -z "${INGRESS_TEST_NO_LO0_GUARD:-}" ]] && ! printf '%s\n' "$lo0_ips" | grep -qxF "$ip"; then
      warn "ingress: skipping http(s)://$a — its loopback IP $ip is not on lo0 (run: sudo vz-ai-stack.sh prepare-sudo, then re-reload)" >&2
      continue
    fi
    if [[ "${ALIAS_PROTOCOL[$a]}" == "http-loopback" ]]; then
      # Upstream is on 127.0.0.1 (the host server never binds the alias IP). Rewrite the
      # upstream Host to 127.0.0.1:<port> so the server's loopback Host-pin (anti-DNS-
      # rebinding) still passes; the Caddy listener stays on the alias IP (lo0, host-only).
      # Do NOT rewrite Origin — that would defeat the upstream CSRF guard (§24 security review).
      printf '\nhttp://%s {\n\tbind %s\n\treverse_proxy 127.0.0.1:%s {\n\t\theader_up Host 127.0.0.1:%s\n\t}\n}\n' "$a" "$ip" "$port" "$port"
      printf 'https://%s {\n\tbind %s\n\ttls internal\n\treverse_proxy 127.0.0.1:%s {\n\t\theader_up Host 127.0.0.1:%s\n\t}\n}\n' "$a" "$ip" "$port" "$port"
    else
      printf '\nhttp://%s {\n\tbind %s\n\treverse_proxy %s:%s\n}\n' "$a" "$ip" "$ip" "$port"
      printf 'https://%s {\n\tbind %s\n\ttls internal\n\treverse_proxy %s:%s\n}\n' "$a" "$ip" "$ip" "$port"
    fi
  done
}

# ingress_wrapper_content — the launchd wrapper. Pins XDG_DATA_HOME (so the CA is
# deterministic under root), waits (bounded) for the first lo0 alias 127.0.10.1
# to exist before exec'ing caddy (no EADDRNOTAVAIL boot race). Caddy + Caddyfile
# paths are baked in at generate time (launchd has no PATH).
ingress_wrapper_content() {
  local cbin; cbin="$(ingress_caddy_bin)"
  cat <<EOF
#!/bin/sh
# ai-stack ingress launch wrapper (generated — do not edit). See ingress.sh.
export XDG_DATA_HOME="$INGRESS_DATA_DIR"
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
# (cmp-before-write; a no-op when unchanged). Validates with `caddy validate`
# first so one malformed site can't black-hole all 13. chmod 0644 so a non-root
# `ingress status` can read it (the file may be root-written via `sudo up`).
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
    rm -f "$tmp"; chmod 0644 "$dest" 2>/dev/null || true
    log "ingress: Caddyfile already current: $dest"
    _INGRESS_CADDYFILE_CHANGED=0
    return 0
  fi
  mv "$tmp" "$dest"; chmod 0644 "$dest" 2>/dev/null || true
  _INGRESS_CADDYFILE_CHANGED=1
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
  if [[ -r "$INGRESS_CADDYFILE" ]]; then
    ok "Caddyfile: $INGRESS_CADDYFILE ($(grep -c '^http://' "$INGRESS_CADDYFILE" 2>/dev/null || echo 0) sites)"
  elif [[ -f "$INGRESS_CADDYFILE" ]]; then
    ok "Caddyfile: $INGRESS_CADDYFILE (present; not readable as this user)"
  else
    note "Caddyfile: not generated (run: ingress generate)"
  fi
  if launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1; then
    ok "daemon: loaded ($INGRESS_LABEL)"
  else
    note "daemon: not loaded ($INGRESS_LABEL)"
  fi
}

# --- Live commands (execute only with caddy + sudo) -------------------------

# ingress_install_daemon — install the wrapper (0755) + root plist (0644), then
# (re)bootstrap so the running caddy picks up the CURRENT Caddyfile.
# Skips the privileged bootout/bootstrap when ALL of: plist unchanged, Caddyfile
# unchanged (_INGRESS_CADDYFILE_CHANGED=0 set by ingress_write_caddyfile), and
# daemon already loaded — unless the defensive health probe fails (which signals
# a crashed/corrupt daemon and forces a restart to self-heal).
# On a CyberArk-EPM / admin-blocked box this avoids noisy bootstrap-failure
# messages when re-running install on an already-running ingress.
ingress_install_daemon() {
  mkdir -p "$(dirname "$INGRESS_WRAPPER")"
  local wtmp; wtmp="$(mktemp)" || return 1
  ingress_wrapper_content > "$wtmp"
  if [[ ! -f "$INGRESS_WRAPPER" ]] || ! cmp -s "$wtmp" "$INGRESS_WRAPPER"; then
    mv "$wtmp" "$INGRESS_WRAPPER"; chmod 0755 "$INGRESS_WRAPPER"
  else rm -f "$wtmp"; fi

  # Need root to write /Library/LaunchDaemons + bootstrap. Defer ONLY if we truly
  # can't get it (not root, no cached sudo, AND not a tty to prompt on).
  if (( EUID != 0 )) && ! sudo -n true 2>/dev/null && ! { [[ -t 0 ]] || [[ -t 1 ]]; }; then
    warn "ingress daemon needs sudo; none cached and not a tty — deferring."
    note "Run 'sudo bash vz-ai-stack.sh ingress up' to install the port-80 daemon."
    return 0
  fi
  local SUDO=""; (( EUID != 0 )) && SUDO="sudo"

  # (Re)install the plist only when it changed — avoids a needless sudo write.
  local ptmp; ptmp="$(mktemp)" || return 1
  ingress_plist_content > "$ptmp"
  if [[ ! -f "$INGRESS_PLIST" ]] || ! cmp -s "$ptmp" "$INGRESS_PLIST"; then
    $SUDO install -m 644 -o root -g wheel "$ptmp" "$INGRESS_PLIST" \
      || { err "install failed for $INGRESS_PLIST"; rm -f "$ptmp"; return 1; }
  fi
  rm -f "$ptmp"

  # --- Idempotency guard: skip privileged restart when nothing changed ---------
  # Skip the bootout/bootstrap when ALL THREE hold:
  #   (a) plist on disk is byte-identical (checked above — $INGRESS_PLIST not replaced)
  #   (b) Caddyfile was not rewritten (_INGRESS_CADDYFILE_CHANGED=0, set by ingress_write_caddyfile)
  #   (c) the daemon is already loaded (launchctl print succeeds)
  # DEFENSIVE: even when all three hold, verify the daemon is actually healthy
  # (a health probe that FAILS means the daemon may be crashed/corrupt — fall
  # through and do the bootstrap anyway to self-heal).
  local _plist_changed=0
  # Re-derive plist state: if we had to install it above the plist was new/changed.
  # We already know the plist file exists and was either written or already identical.
  # Use a lightweight re-check of the on-disk content.
  if ingress_plist_content | cmp -s - "$INGRESS_PLIST" 2>/dev/null; then
    _plist_changed=0
  else
    _plist_changed=1
  fi
  if [[ "$_plist_changed" == "0" ]] \
     && [[ "${_INGRESS_CADDYFILE_CHANGED:-0}" == "0" ]] \
     && launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1; then
    # All three conditions met — now run the defensive health probe.
    # Try curl first (validates the Caddy port-80 listener is alive); fall back
    # to caddy validate (validates config syntax at minimum).
    local _health_ok=0
    if curl -sf -m2 http://localhost:80 >/dev/null 2>&1 \
       || curl -sf -m2 http://127.0.0.1:80 >/dev/null 2>&1; then
      _health_ok=1
    else
      local cbin; cbin="$(ingress_caddy_bin || true)"
      if [[ -n "$cbin" ]] && "$cbin" validate --config "$INGRESS_CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
        _health_ok=1
      fi
    fi
    if [[ "$_health_ok" == "1" ]]; then
      log "ingress daemon already loaded + config unchanged — skipping privileged restart."
      ok "ingress daemon: already loaded ($INGRESS_LABEL)"
      return 0
    else
      log "ingress daemon loaded but health probe failed — proceeding with restart."
    fi
  fi

  # (Re)start the daemon so the current Caddyfile is applied.
  $SUDO launchctl bootout system "$INGRESS_PLIST" 2>/dev/null || true
  $SUDO launchctl bootstrap system "$INGRESS_PLIST" 2>/dev/null \
    || $SUDO launchctl load "$INGRESS_PLIST" 2>/dev/null \
    || { err "launchctl bootstrap failed for $INGRESS_LABEL"; return 1; }
  ok "ingress daemon (re)started: $INGRESS_LABEL"
}

# ingress_up — ensure caddy, (re)generate+validate the Caddyfile, then (re)start
# the daemon so it serves the current config.
ingress_up() {
  ingress_caddy_bin >/dev/null || { err "caddy not installed — run 'brew install caddy'"; return 1; }
  ingress_write_caddyfile || return 1
  ingress_install_daemon || return 1
  ingress_status
}

# ingress_reload — alias for "apply current config": regenerate + restart.
ingress_reload() {
  ingress_caddy_bin >/dev/null || { err "caddy not installed"; return 1; }
  ingress_write_caddyfile || return 1
  ingress_install_daemon
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

# _ingress_ca_crt — locate Caddy's local root CA cert. Prefer the pinned data dir
# (set via XDG_DATA_HOME in the wrapper); fall back to the legacy root/user dirs.
_ingress_ca_crt() {
  [[ -n "${INGRESS_CA_CRT:-}" ]] && { printf '%s' "$INGRESS_CA_CRT"; return 0; }
  local p
  for p in \
    "$INGRESS_DATA_DIR/caddy/pki/authorities/local/root.crt" \
    "/var/root/Library/Application Support/Caddy/pki/authorities/local/root.crt" \
    "$HOME/Library/Application Support/Caddy/pki/authorities/local/root.crt"; do
    if [[ -f "$p" ]] || sudo test -f "$p" 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# ingress_trust — install Caddy's local root CA into the USER LOGIN keychain
# (NOT system-wide), so https://litellm/ is browser-trusted for this user only.
# Triggers a macOS GUI auth dialog (login-keychain trust is interactive — must
# run in a GUI session).
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
    $SUDO rm -rf "$INGRESS_DATA_DIR" \
                 "/var/root/Library/Application Support/Caddy" \
                 "$HOME/Library/Application Support/Caddy" 2>/dev/null || true
  fi
  ok "ingress: torn down ($tier)"
}

# --- list / add / remove (hostname registry view + opt-in registrar) ---------

# _ingress_bind_posture <port> — classify what's LISTENING on <port> (host-local,
# no network I/O, no cold-start): "lan" if any listener is on 0.0.0.0/* (LAN-reachable),
# "loopback" if only 127.x/[::1], "down" if nothing. lsof is fast + local.
_ingress_bind_posture() {
  local port="$1" out
  out="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)" || true
  [[ -z "$out" ]] && { echo down; return; }
  if grep -qE "(\*|0\.0\.0\.0|\[::\]):${port}([^0-9]|$)" <<<"$out"; then echo lan; else echo loopback; fi
}

# _ingress_next_free_ip — lowest unused 127.0.10.N (1..254). Scans ALL such tokens in
# BOTH the tracked aliases.tsv AND the local overrides, INCLUDING comment lines, so a
# reserved-but-commented IP (e.g. .15) or a personal local row is never reclaimed.
# Returns 1 (no echo) when the /24 host range is exhausted.
_ingress_next_free_ip() {
  local used n
  used="$(grep -hoE '127\.0\.10\.[0-9]+' "$AI_STACK_ALIASES_TSV" "$AI_STACK_ALIASES_LOCAL_TSV" 2>/dev/null | sed 's/.*\.//' | sort -un)"
  for n in $(seq 1 254); do
    grep -qxF "$n" <<<"$used" || { printf '127.0.10.%s' "$n"; return 0; }
  done
  return 1
}

# _ingress_tsv_write <tmpfile> [dest] — atomically replace <dest> (default the tracked
# aliases.tsv) with <tmpfile>'s contents (rename is atomic; no flock — Darwin has none —
# and temp+mv can't corrupt). Preserves 0644 mode. add/remove pass the LOCAL file.
_ingress_tsv_write() { chmod 0644 "$1" 2>/dev/null || true; mv "$1" "${2:-$AI_STACK_ALIASES_TSV}"; }

# ingress_list — read-only map of every configured hostname (source of truth =
# aliases.tsv, via aliases_load — no second parser), all URL forms, bind posture,
# and host-local liveness. Zero privilege, zero network, safe to run anytime.
ingress_list() {
  aliases_load || return 1
  local caddy_up=0; launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1 && caddy_up=1

  hdr "ai-stack hostnames  (source: installer/lib/aliases.tsv)"
  printf '%-18s %-12s %-24s %-22s %-9s %s\n' "ALIAS" "IP" "name:port" "name/" "BIND" "UP"
  # ASCII rule (box-drawing chars are multibyte → break printf width counting → misalign).
  printf '%-18s %-12s %-24s %-22s %-9s %s\n' "------------------" "-----------" "----------------------- " "--------------------- " "--------" "--"
  local a ip proto port np ns bind mark up
  for a in "${ALIASES_LIST[@]}"; do
    ip="${ALIAS_IP[$a]}"; proto="${ALIAS_PROTOCOL[$a]}"; port="${ALIAS_HOST_PORT[$a]}"
    case "$proto" in
      http)          np="$a:$port" ;;
      http-loopback) np="- (use name/)" ;;
      redis)         np="redis://$a:$port" ;;
      grpc)          np="$a:$port (grpc)" ;;
      *)             np="$a:$port" ;;
    esac
    if ingress_alias_in_scope "$a"; then ns="http://$a/"; else ns="-"; fi
    bind="$(_ingress_bind_posture "$port")"
    # ASCII markers only (BIND is not the last column → multibyte ⚠/— would misalign it).
    case "$bind" in lan) mark="LAN!"; up="up" ;; loopback) mark="loopback"; up="up" ;; *) mark="-"; up="-" ;; esac
    printf '%-18s %-12s %-24s %-22s %-9s %s\n' "$a" "$ip" "$np" "$ns" "$mark" "$up"
  done
  echo
  note "Every HTTP alias is also reachable at localhost:<port>."
  if (( caddy_up )); then note "Port-free http://name/ is served by the ingress daemon (running)."
  else note "Port-free http://name/ needs the ingress daemon: sudo vz-ai-stack.sh ingress up"; fi

  hdr "Host-only servers — no hostname (reach at localhost:PORT)"
  printf '  %-22s %-16s %s\n' "tutorial-serve"       "localhost:8899" "on-demand doc server (loopback Host-pinned)"
  printf '  %-22s %-16s %s\n' "models-serve"         "localhost:8898" "model console (loopback Host-pinned; shares :8898 w/ unsloth)"
  printf '  %-22s %-16s %s\n' "fleet-studio"         "localhost:8975" "needs an https:// secure context to use a hostname"
  printf '  %-22s %-16s %s\n' "understand-dashboard" "localhost:5173" "Vite graph dashboard (on-demand)"
  note "Give any localhost:PORT a port-free hostname:  vz-ai-stack.sh ingress add <name> <port>"

  # LAN-exposure scan — generic (catches host servers with NO alias too, e.g. lmstudio).
  local lan; lan="$(lsof -nP +c 0 -iTCP -sTCP:LISTEN 2>/dev/null \
      | awk '{a=$(NF-1)} a ~ /^(\*|0\.0\.0\.0|\[::\]):[0-9]+$/ {print "  " $1 "  " a}' \
      | sed 's/\\x20/ /g' | sort -u)"   # lsof +c 0 escapes spaces as \x20 on macOS (verified) — unescape for display
  if [[ -n "$lan" ]]; then
    echo; warn "Listening on ALL interfaces (0.0.0.0 — reachable from your LAN, not just this Mac):"
    printf '%s\n' "$lan" >&2
    warn "Host servers binding 0.0.0.0 (e.g. lmstudio/docs-mcp/unsloth) are often that way for container access; review if your network is untrusted."
  fi
}

# ingress_add <name> <port> [--ip 127.0.10.N] — register a port-free http://name/ for a
# localhost:port server via a loopback-proxy (http-loopback) alias row. TSV-only (check 64
# is forward-only). Does NOT auto-run sudo — prints the activation block (§5/§25).
ingress_add() {
  local name="" port="" want_ip=""
  while (( $# )); do
    case "$1" in
      --ip)  [[ -n "${2:-}" ]] || { err "ingress add: --ip requires a value (127.0.10.N)"; return 2; }
             want_ip="$2"; shift 2 ;;   # guard FIRST: `shift 2` with $#<2 can't advance → infinite loop
      -*)    err "ingress add: unknown flag '$1'"; return 2 ;;
      *)     if   [[ -z "$name" ]]; then name="$1"
             elif [[ -z "$port" ]]; then port="$1"
             else err "ingress add: too many arguments"; return 2; fi; shift ;;
    esac
  done
  [[ -n "$name" && -n "$port" ]] || { err "usage: vz-ai-stack.sh ingress add <name> <port> [--ip 127.0.10.N]"; return 2; }
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { err "ingress add: <name> must be lowercase DNS-safe ^[a-z0-9][a-z0-9-]*\$ (got '$name')"; return 2; }
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { err "ingress add: <port> must be 1-65535 (got '$port')"; return 2; }
  aliases_load || return 1
  [[ -z "${ALIAS_IP[$name]:-}" ]] || { err "ingress add: '$name' already exists (${ALIAS_IP[$name]} ${ALIAS_PROTOCOL[$name]} :${ALIAS_HOST_PORT[$name]}). Pick another name, or 'ingress remove $name' first."; return 1; }
  local ip
  if [[ -n "$want_ip" ]]; then
    [[ "$want_ip" =~ ^127\.0\.10\.[0-9]+$ ]] || { err "ingress add: --ip must be 127.0.10.N (got '$want_ip')"; return 2; }
    local _oct="${want_ip##*.}"
    (( _oct >= 1 && _oct <= 254 )) || { err "ingress add: --ip octet must be 1-254 (got '$want_ip'; .0/.255 are network/broadcast)"; return 2; }
    # Taken-check against ALL 127.0.10.N tokens incl. comment/reserved rows (same set the
    # allocator uses); exact fixed-string match avoids the dots-as-ERE-wildcards trap.
    grep -hoE '127\.0\.10\.[0-9]+' "$AI_STACK_ALIASES_TSV" "$AI_STACK_ALIASES_LOCAL_TSV" 2>/dev/null | grep -qxF "$want_ip" \
      && { err "ingress add: $want_ip is already allocated (incl. reserved/commented + local rows)"; return 1; }
    ip="$want_ip"
  else
    ip="$(_ingress_next_free_ip)" || { err "ingress add: no free 127.0.10.N in 1-254 — host range exhausted"; return 1; }
  fi
  if ! lsof -nP -iTCP@127.0.0.1:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "ingress add: nothing is listening on 127.0.0.1:$port right now — http://$name/ will 502 until that server starts (fine if you start it later)."
  fi
  # Personal hostnames go in the gitignored LOCAL file (never the tracked public aliases.tsv).
  local LF="$AI_STACK_ALIASES_LOCAL_TSV"
  local tmp; tmp="$(mktemp "${LF%/*}/.aliases.XXXXXX")" || return 1   # co-located → mv is atomic (same fs)
  if [[ -f "$LF" ]]; then
    cp "$LF" "$tmp" || { rm -f "$tmp"; return 1; }
  else
    printf '# ai-stack LOCAL hostname overrides (gitignored) — your personal `ingress add` rows.\n# Same TSV columns as aliases.tsv; aliases_load merges these ON TOP. Safe to edit/delete.\n' > "$tmp"
  fi
  printf '%s\t%s\thttp-loopback\t%s\t%s\tmanual\t%s\n' "$name" "$ip" "$port" "$port" "$name" >> "$tmp"
  _ingress_tsv_write "$tmp" "$LF" || { err "ingress add: failed to update $LF"; return 1; }
  ok "ingress add: registered http://$name/ → 127.0.0.1:$port  (alias $ip, http-loopback)"
  note "Stored in your gitignored aliases.local.tsv — personal, never committed to the repo."
  ingress_write_caddyfile >/dev/null 2>&1 || true   # site appears after the IP is on lo0
  note "Host-pinned apps (models/tutorial-serve) & secure-context apps (fleet-studio) want https://$name/ + 'ingress trust' for full use; plain http://$name/ is loopback-proxied as-is."
  _ingress_print_activation "$name"
}

# ingress_remove <name> — remove a manually-added (http-loopback) hostname. Refuses core
# dual-bind aliases (removing one would break the stack — edit aliases.tsv directly instead).
ingress_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || { err "usage: vz-ai-stack.sh ingress remove <name>"; return 2; }
  # Validate BEFORE using $name in the ERE below (a metachar-laden name could over-match).
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { err "ingress remove: invalid name '$name' (expected ^[a-z0-9][a-z0-9-]*\$)"; return 2; }
  aliases_load || return 1
  [[ -n "${ALIAS_IP[$name]:-}" ]] || { err "ingress remove: '$name' is not a registered hostname (checked aliases.tsv + aliases.local.tsv)"; return 1; }
  if [[ "${ALIAS_PROTOCOL[$name]}" != "http-loopback" ]]; then
    err "ingress remove: '$name' is a core ${ALIAS_PROTOCOL[$name]} alias, not a manually-added hostname — refusing (would break the service)."
    err "  Edit installer/lib/aliases.tsv directly if you really intend to remove it."
    return 1
  fi
  local ip="${ALIAS_IP[$name]}"
  # http-loopback rows live ONLY in the local file (the tracked aliases.tsv never gets them).
  local LF="$AI_STACK_ALIASES_LOCAL_TSV"
  # The row must actually be IN the local file. A http-loopback row in the TRACKED aliases.tsv
  # is a pre-migration leftover (old `ingress add`) — refuse rather than silently no-op + "✓".
  { [[ -f "$LF" ]] && grep -qE "^${name}[[:space:]]" "$LF"; } || {
    err "ingress remove: '$name' is not in your local aliases.local.tsv."
    err "  (A http-loopback row in the tracked installer/lib/aliases.tsv is a pre-migration leftover —"
    err "   move it to aliases.local.tsv, or edit aliases.tsv directly to remove it.)"
    return 1
  }
  local tmp; tmp="$(mktemp "${LF%/*}/.aliases.XXXXXX")" || return 1   # co-located → mv is atomic (same fs)
  grep -vE "^${name}[[:space:]]" "$LF" > "$tmp" || true
  _ingress_tsv_write "$tmp" "$LF" || { err "ingress remove: failed to update $LF"; return 1; }
  ok "ingress remove: removed hostname '$name' (was $ip http-loopback)"
  ingress_write_caddyfile >/dev/null 2>&1 || true
  echo
  note "Apply (needs sudo — run from your MAIN checkout):"
  printf '    sudo vz-ai-stack.sh prepare-sudo && sudo vz-ai-stack.sh ingress reload\n'
  note "prepare-sudo removes the /etc/hosts entry + updates the lo0 plist so $ip is NOT re-bound on reboot."
  note "$ip stays on lo0 until your next reboot (harmless); free it now with: sudo ifconfig lo0 -alias $ip"
}

# _ingress_print_activation <name> — the single ordered sudo block to light up a new hostname.
_ingress_print_activation() {
  local name="$1"
  echo
  note "Activate (needs sudo — run from your MAIN checkout, then quit+reopen the browser for https):"
  printf '    sudo vz-ai-stack.sh prepare-sudo && sudo vz-ai-stack.sh ingress reload\n'
  note "Verify:  curl -I http://$name/    (200/301/401/404 = wired; 000/502 = upstream not up)"
}

# --- CLI (run-direct only) --------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _cmd="${1:-status}"; shift 2>/dev/null || true
  case "$_cmd" in
    up)               ingress_up "$@" ;;
    down)             ingress_down "$@" ;;
    reload)           ingress_reload "$@" ;;
    status)           ingress_status ;;
    list|ls)          ingress_list "$@" ;;
    add)              ingress_add "$@" ;;
    remove|rm)        ingress_remove "$@" ;;
    trust)            ingress_trust "$@" ;;
    untrust)          ingress_untrust "$@" ;;
    teardown)         ingress_teardown "$@" ;;
    generate)         ingress_write_caddyfile "$@" ;;
    print-caddyfile)  ingress_caddyfile_content ;;
    print-plist)      ingress_plist_content ;;
    print-wrapper)    ingress_wrapper_content ;;
    *) err "ingress: unknown subcommand '$_cmd' (list|add|remove|up|down|reload|status|trust|untrust|teardown|generate|print-*)"; exit 2 ;;
  esac
fi
