# ingress.sh — bare-hostname host ingress.
#
# Generates a Caddyfile from aliases.tsv and (later slices) manages a host-native
# Caddy daemon that binds each HTTP service's own 127.0.10.x:80/:443 and
# reverse-proxies to its existing native-port publish — giving the Mac browser
# `http(s)://litellm/` while leaving `name:port` and container traffic untouched.
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

# Where the generated Caddyfile lands + the Caddy admin control socket (a
# restricted local unix socket, not a TCP port — see spec §14 admin-endpoint).
INGRESS_CADDYFILE="${INGRESS_CADDYFILE:-$AI_STACK/installer/state/Caddyfile.ai-stack}"
INGRESS_ADMIN_SOCK="${INGRESS_ADMIN_SOCK:-/var/run/ai-stack-caddy-admin.sock}"

# ingress_alias_in_scope <alias> — true iff this alias row gets a port-free site:
# protocol == http AND IP is in the 127.0.10.x range. Excludes redis/grpc and the
# 127.0.0.1 daemons (openwork/aionui). Operates per ALIAS ROW (never service_key),
# so `falkordb-ui` (http, .8) is in but `falkordb` (redis, .7) is out.
ingress_alias_in_scope() {
  local a="$1"
  [[ "${ALIAS_PROTOCOL[$a]:-}" == "http" ]] || return 1
  [[ "${ALIAS_IP[$a]:-}" =~ ^127\.0\.10\. ]] || return 1
  return 0
}

# ingress_caddyfile_content — echo the canonical Caddyfile. For every in-scope
# alias, two explicit site blocks (no auto HTTP→HTTPS redirect): an http:// site
# and an https:// site (tls internal), both `bind`-ing the alias's own IP and
# reverse-proxying to <ip>:<native_port>. Pure / deterministic (AC-4). A site is
# emitted regardless of upstream liveness (a down service 502s by design — the
# bind must exist for the AC-2 no-collision proof).
ingress_caddyfile_content() {
  aliases_load || return 1
  # Global options: admin via a restricted local unix socket (caddy reload needs it).
  printf '{\n\tadmin unix/%s\n}\n' "$INGRESS_ADMIN_SOCK"
  local a ip port
  for a in "${ALIASES_LIST[@]}"; do
    ingress_alias_in_scope "$a" || continue
    ip="${ALIAS_IP[$a]}"; port="${ALIAS_HOST_PORT[$a]}"
    printf '\nhttp://%s {\n\tbind %s\n\treverse_proxy %s:%s\n}\n' "$a" "$ip" "$ip" "$port"
    printf 'https://%s {\n\tbind %s\n\ttls internal\n\treverse_proxy %s:%s\n}\n' "$a" "$ip" "$ip" "$port"
  done
}
