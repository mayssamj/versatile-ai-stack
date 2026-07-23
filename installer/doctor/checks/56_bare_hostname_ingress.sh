# bare-hostname host ingress healthy (Phase 31).
#
# OPT-IN: a host-native Caddy gives the Mac port-free http(s)://litellm/. This
# check is a no-op [skip] when caddy isn't installed or the daemon isn't loaded.
# When the daemon IS loaded it proves there is NO OrbStack *:80 collapse by
# asserting two services answer on their OWN socket IP (curl %{local_ip}) — which
# holds even if the upstream container is down (a 502 still connects to the right
# IP). Makes NO external network calls; loopback only.
CHECKS+=(bare_hostname_ingress)
CHECK_TITLE[bare_hostname_ingress]="bare-hostname ingress http(s)://name/ (Phase 31)"

_bhi_local_ip() {  # echo the local socket IP curl used to reach <alias>:80 on <ip>
  local alias="$1" ip="$2"
  curl -o /dev/null -s -m 4 -w '%{local_ip}' --resolve "$alias:80:$ip" "http://$alias/" 2>/dev/null || true
}

bare_hostname_ingress_diagnose() {
  if ! command -v caddy >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/caddy && ! -x /usr/local/bin/caddy ]]; then
    echo "ingress not installed — run 'mayssam-ai-stack.sh install ingress' for port-free http(s)://litellm/. [skip]"
    return 0
  fi
  if ! launchctl print "system/com.ai-stack.ingress" >/dev/null 2>&1; then
    echo "caddy installed but ingress daemon not loaded — run 'mayssam-ai-stack.sh ingress up'. [skip]"
    return 0
  fi
  # Daemon loaded ⇒ the user opted in; a broken bind is a real regression.
  local lit phx
  lit="$(_bhi_local_ip litellm 127.0.10.1)"
  phx="$(_bhi_local_ip phoenix 127.0.10.2)"
  if [[ "$lit" != "127.0.10.1" || "$phx" != "127.0.10.2" ]]; then
    echo "ingress :80 not isolated per-IP (litellm->${lit:-unreachable}, phoenix->${phx:-unreachable}; expected 127.0.10.1 / 127.0.10.2). Re-run 'mayssam-ai-stack.sh ingress up'."
    return 1
  fi
  echo "  (ingress live: http://litellm/ -> 127.0.10.1, http://phoenix/ -> 127.0.10.2; no *:80 collapse. 'ingress trust' for https://.)"
  return 0
}

bare_hostname_ingress_fix() {
  warn "Bring up / repair the bare-hostname ingress:"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh ingress up"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh ingress trust   # trust the local CA for https://"
  return 1
}
