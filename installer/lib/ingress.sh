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
  [[ -x /opt/homebrew/bin/caddy ]] && { printf '%s' /opt/homebrew/bin/caddy; return 0; }
  printf 'caddy'
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
  if command -v caddy >/dev/null 2>&1; then
    caddy validate --config "$tmp" --adapter caddyfile >/dev/null 2>&1 \
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
  if command -v caddy >/dev/null 2>&1; then
    ok "caddy: $(ingress_caddy_bin) ($(caddy version 2>/dev/null | head -1))"
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

# --- CLI (run-direct only) --------------------------------------------------
# Live subcommands (up/down/reload/trust/untrust) land in Slices 4-5; the
# offline generators are wired now so they're exercisable + testable today.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _cmd="${1:-status}"; shift 2>/dev/null || true
  case "$_cmd" in
    generate)         ingress_write_caddyfile "$@" ;;
    print-caddyfile)  ingress_caddyfile_content ;;
    print-plist)      ingress_plist_content ;;
    print-wrapper)    ingress_wrapper_content ;;
    status)           ingress_status ;;
    *) err "ingress: unknown subcommand '$_cmd' (generate|print-caddyfile|print-plist|print-wrapper|status)"; exit 2 ;;
  esac
fi
