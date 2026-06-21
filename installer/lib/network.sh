# network.sh — ai-stack network helpers (D20, D21, D7 revised).
#
# Sourced after common.sh. Provides:
#   aliases_load                — load aliases.tsv into associative maps
#   network_ensure_ai_stack     — create the ai-stack bridge network if absent
#   network_remove_ai_stack     — tear it down (for `reset --confirm hard|nuke`)
#   hosts_ensure_block          — atomic, idempotent /etc/hosts management
#   hosts_remove_block          — strip the >>> ai-stack block out
#   dscacheutil_flush           — flush macOS DNS cache
#   resolve_alias <alias>       — return the IP for an alias
#
# Also exports:
#   AI_STACK_NET_FLAGS          — `--network ai-stack --add-host=ollama:host-gateway`
#   AI_STACK_SUBNET (default 10.99.0.0/24)
#   AI_STACK_GATEWAY (default 10.99.0.1)
#
# Design rationale lives in installer/state/refactor-design-final.md (D7/D20–D28).

[[ -z "${AI_STACK:-}" ]] && { echo "network.sh: AI_STACK unset" >&2; exit 2; }

# Single source of truth for the IP table.
AI_STACK_ALIASES_TSV="${AI_STACK_ALIASES_TSV:-$AI_STACK/installer/lib/aliases.tsv}"

# Configurable to escape VPN/route collisions (D20).
AI_STACK_SUBNET="${AI_STACK_SUBNET:-10.99.0.0/24}"
AI_STACK_GATEWAY="${AI_STACK_GATEWAY:-10.99.0.1}"

# Canonical docker-run flags for managed containers (D3 — referenced, not
# enforced centrally yet, since each bin/start-*.sh still hand-rolls its run).
AI_STACK_NET_FLAGS="--network ai-stack --add-host=ollama:host-gateway"

export AI_STACK_ALIASES_TSV AI_STACK_SUBNET AI_STACK_GATEWAY AI_STACK_NET_FLAGS

# Hosts-block markers.
HOSTS_MARK_BEGIN="# >>> ai-stack (managed; do not edit manually) >>>"
HOSTS_MARK_END="# <<< ai-stack (managed) <<<"

# --- aliases_load -----------------------------------------------------------
# Populates 6 associative arrays + 1 ordered list. Idempotent — safe to source
# repeatedly. Skips comment lines (starting with #) and blank lines.
aliases_load() {
  declare -gA ALIAS_IP=()
  declare -gA ALIAS_PROTOCOL=()
  declare -gA ALIAS_HOST_PORT=()
  declare -gA ALIAS_CONTAINER_PORT=()
  declare -gA ALIAS_PHASE=()
  declare -gA ALIAS_SERVICE_KEY=()
  declare -ga ALIASES_LIST=()

  if [[ ! -r "$AI_STACK_ALIASES_TSV" ]]; then
    err "aliases_load: $AI_STACK_ALIASES_TSV not readable"
    return 1
  fi

  local raw alias ip protocol host_port container_port phase service_key
  # Read whole file, split into fields manually so we are tolerant of
  # multiple-tab spacing without depending on `read -a` quirks.
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    # Strip CR if file picked one up.
    raw="${raw%$'\r'}"
    # Skip blank lines and comments.
    [[ -z "$raw" ]] && continue
    [[ "$raw" =~ ^[[:space:]]*# ]] && continue
    # Collapse runs of whitespace to a single tab, then split on TAB.
    local norm
    norm="$(printf '%s\n' "$raw" | awk -F'\t' '{ s=""; for(i=1;i<=NF;i++){ if($i!=""){ s=s $i "\t" } } sub(/\t$/,"",s); print s }')"
    IFS=$'\t' read -r alias ip protocol host_port container_port phase service_key <<<"$norm" || true
    [[ -z "${alias:-}" || -z "${ip:-}" ]] && continue
    ALIAS_IP[$alias]="$ip"
    ALIAS_PROTOCOL[$alias]="$protocol"
    ALIAS_HOST_PORT[$alias]="$host_port"
    ALIAS_CONTAINER_PORT[$alias]="$container_port"
    ALIAS_PHASE[$alias]="$phase"
    ALIAS_SERVICE_KEY[$alias]="$service_key"
    ALIASES_LIST+=("$alias")
  done < "$AI_STACK_ALIASES_TSV"

  return 0
}

# --- expected_hosts_block ---------------------------------------------------
# Echo the canonical /etc/hosts block computed from aliases.tsv.
expected_hosts_block() {
  aliases_load || return 1
  printf '%s\n' "$HOSTS_MARK_BEGIN"
  local a
  for a in "${ALIASES_LIST[@]}"; do
    # Width 12 keeps the file readable but won't break parsers.
    printf '%-12s %s\n' "${ALIAS_IP[$a]}" "$a"
  done
  printf '%s\n' "$HOSTS_MARK_END"
}

# --- current_hosts_block ----------------------------------------------------
# Echo the existing managed block from /etc/hosts (or nothing if absent).
current_hosts_block() {
  awk -v b="$HOSTS_MARK_BEGIN" -v e="$HOSTS_MARK_END" '
    $0==b { inblock=1 }
    inblock { print }
    $0==e { inblock=0 }
  ' /etc/hosts 2>/dev/null || true
}

# --- network_ensure_ai_stack ------------------------------------------------
# Idempotent: inspect first; create only if missing. Fails loudly on subnet
# collision (D20).
network_ensure_ai_stack() {
  if docker network inspect ai-stack >/dev/null 2>&1; then
    local driver
    driver="$(docker network inspect ai-stack --format '{{.Driver}}' 2>/dev/null || echo "")"
    if [[ "$driver" != "bridge" ]]; then
      err "ai-stack network exists but driver is '$driver' (expected bridge)."
      err "Remove with: docker network rm ai-stack  (after stopping attached containers)"
      return 1
    fi
    return 0
  fi

  log "Creating Docker network 'ai-stack' (subnet $AI_STACK_SUBNET)..."
  if ! docker network create \
      --driver bridge \
      --subnet "$AI_STACK_SUBNET" \
      --gateway "$AI_STACK_GATEWAY" \
      ai-stack >/dev/null 2>&1; then
    # Most likely cause: subnet overlap with an existing docker network or
    # a host route. Re-run with details so the user can pick an alt subnet.
    err "docker network create ai-stack failed."
    err "Likely cause: subnet $AI_STACK_SUBNET overlaps an existing docker network or host route."
    err "Escape hatch: AI_STACK_SUBNET=10.123.0.0/24 AI_STACK_GATEWAY=10.123.0.1 bash vz-ai-stack.sh install 00n"
    err ""
    err "Existing docker networks (for reference):"
    docker network ls --format '  {{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>&1 | sed 's/^/    /' >&2 || true
    return 1
  fi
  ok "Created Docker network 'ai-stack' ($AI_STACK_SUBNET)"
  record "created docker network ai-stack ($AI_STACK_SUBNET)"
  return 0
}

# --- network_remove_ai_stack ------------------------------------------------
# Stops/removes attached containers first, then drops the network. Idempotent.
network_remove_ai_stack() {
  if ! docker network inspect ai-stack >/dev/null 2>&1; then
    return 0
  fi
  log "Detaching containers from ai-stack network..."
  local cid
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    docker network disconnect -f ai-stack "$cid" >/dev/null 2>&1 || true
  done < <(docker network inspect ai-stack --format '{{range $k,$v := .Containers}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null)
  if docker network rm ai-stack >/dev/null 2>&1; then
    ok "Removed Docker network 'ai-stack'"
    record "removed docker network ai-stack"
  else
    warn "docker network rm ai-stack failed (containers still attached?)"
    return 1
  fi
  return 0
}

# --- dscacheutil_flush ------------------------------------------------------
# macOS DNS cache flush. Requires sudo. Called automatically after a hosts
# update; exposed so doctor checks can opt into a refresh.
dscacheutil_flush() {
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
}

# --- lo0_ensure_aliases -----------------------------------------------------
# CRITICAL macOS-specific step: bind every 127.0.10.x address to lo0 so the
# OS actually routes traffic to those IPs. The original networking refactor
# brief asserted "macOS makes all of 127.0.0.0/8 available as loopback" —
# that's wrong. Only 127.0.0.1 is on lo0 by default. Without these aliases,
# Docker binds happily to 127.0.10.1:80 but no packets ever reach it because
# the kernel has no route for that IP.
#
# Requires sudo. Idempotent: `ifconfig lo0 alias` is a no-op if the alias
# is already configured. Does NOT persist across reboots — see
# lo0_install_persistence_plist below.
lo0_ensure_aliases() {
  aliases_load || { err "aliases_load failed"; return 1; }
  local already_bound
  already_bound="$(ifconfig lo0 2>/dev/null | awk '/inet 127\.0\.10\./ {print $2}')"
  local missing=()
  local a ip
  for a in "${ALIASES_LIST[@]}"; do
    ip="${ALIAS_IP[$a]}"
    # Host loopback services (openwork/aionui) use 127.0.0.1 — the lo0 PRIMARY,
    # always present; there is no 127.0.10.x alias to bind for them.
    [[ "$ip" == "127.0.0.1" ]] && continue
    if ! grep -qxF "$ip" <<<"$already_bound"; then
      missing+=("$ip")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    return 0
  fi
  log "Binding ${#missing[@]} loopback aliases to lo0 (sudo required)..."
  for ip in "${missing[@]}"; do
    sudo ifconfig lo0 alias "$ip" up >/dev/null 2>&1 || warn "failed to bind $ip"
  done
  ok "loopback aliases bound: ${missing[*]}"
}

# --- lo0_remove_aliases -----------------------------------------------------
# Reverse of lo0_ensure_aliases. Used by reset --confirm nuke. Requires sudo.
lo0_remove_aliases() {
  aliases_load || return 1
  local a ip
  for a in "${ALIASES_LIST[@]}"; do
    ip="${ALIAS_IP[$a]}"
    sudo ifconfig lo0 -alias "$ip" >/dev/null 2>&1 || true
  done
}

# --- lo0_install_persistence_plist ------------------------------------------
# macOS lo0 aliases do NOT persist across reboots. Install a launchd plist
# that re-binds them at boot so the install survives a restart without the
# user re-running prepare-sudo. Plist owned by root:wheel mode 644.
lo0_install_persistence_plist() {
  aliases_load || return 1
  local plist="/Library/LaunchDaemons/com.ai-stack.loopback.plist"
  local tmp
  tmp="$(mktemp /tmp/ai-stack-loopback.plist.XXXXXX)" || return 1
  trap "rm -f '$tmp'" EXIT
  # Build the ProgramArguments array dynamically from aliases.tsv.
  {
    cat <<'XML_HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.ai-stack.loopback</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>
XML_HEADER
    # The actual command — a series of ifconfig invocations joined by ; so
    # one launchd job binds all 14 in order.
    local a ip first=1
    for a in "${ALIASES_LIST[@]}"; do
      ip="${ALIAS_IP[$a]}"
      if (( first )); then first=0; else printf ' ; '; fi
      printf '/sbin/ifconfig lo0 alias %s up' "$ip"
    done
    cat <<'XML_FOOTER'
    </string>
  </array>
  <key>StandardErrorPath</key>
  <string>/var/log/ai-stack-loopback.err</string>
</dict>
</plist>
XML_FOOTER
  } > "$tmp"
  # Idempotent fast-path: if the installed plist already matches what we'd
  # write, there's nothing to do — and crucially NO sudo is needed. This is the
  # common case during a normal `install` after `prepare-sudo` already put the
  # plist in place; previously we always re-ran `sudo install`, which emits a
  # scary "a terminal is required to read the password" error under a
  # non-interactive install. CHANGELOG 2026-05-30.
  if [[ -f "$plist" ]] && cmp -s "$tmp" "$plist"; then
    rm -f "$tmp"; trap - EXIT
    ok "loopback persistence plist already current: $plist"
    return 0
  fi
  # Plist missing or stale AND we're not root AND sudo can't run
  # non-interactively → defer rather than block on a password prompt. The lo0
  # aliases are already bound for THIS session (lo0_ensure_aliases ran); only
  # reboot-persistence is deferred to `prepare-sudo`.
  if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
    rm -f "$tmp"; trap - EXIT
    warn "loopback persistence plist needs sudo to (re)install; sudo unavailable non-interactively."
    note "Run 'sudo bash vz-ai-stack.sh prepare-sudo' to persist lo0 aliases across reboot (does not affect this session)."
    return 0
  fi
  # When EUID is already 0 (called from prepare-sudo), don't double-sudo —
  # macOS sudo requires a TTY for password prompt and a sudo-from-root in a
  # non-interactive context can fail. Just run install directly. Otherwise
  # (called from a normal user shell) prefix with sudo.
  if (( EUID == 0 )); then
    install -m 644 -o root -g wheel "$tmp" "$plist" \
      || { err "install failed for $plist"; rm -f "$tmp"; trap - EXIT; return 1; }
    launchctl bootstrap system "$plist" 2>/dev/null \
      || launchctl load "$plist" 2>/dev/null \
      || true
  else
    sudo install -m 644 -o root -g wheel "$tmp" "$plist" \
      || { err "sudo install failed for $plist"; rm -f "$tmp"; trap - EXIT; return 1; }
    sudo launchctl bootstrap system "$plist" 2>/dev/null \
      || sudo launchctl load "$plist" 2>/dev/null \
      || true
  fi
  rm -f "$tmp"
  trap - EXIT
  ok "loopback persistence plist installed: $plist"
}

# Remove the persistence plist (for reset --confirm nuke).
lo0_uninstall_persistence_plist() {
  local plist="/Library/LaunchDaemons/com.ai-stack.loopback.plist"
  if [[ -f "$plist" ]]; then
    sudo launchctl bootout system "$plist" 2>/dev/null \
      || sudo launchctl unload "$plist" 2>/dev/null \
      || true
    sudo rm -f "$plist"
  fi
}

# --- resolve_alias ----------------------------------------------------------
# Echo the IP for a given alias. Prefer dscacheutil (post-cache state), then
# fall back to /etc/hosts directly. Empty stdout on failure.
resolve_alias() {
  local alias="$1"
  local ip
  ip="$(dscacheutil -q host -a name "$alias" 2>/dev/null | awk '/^ip_address:/ {print $2; exit}')"
  if [[ -n "$ip" ]]; then
    printf '%s' "$ip"
    return 0
  fi
  # Fallback: parse /etc/hosts directly.
  awk -v a="$alias" '
    /^[[:space:]]*#/ { next }
    {
      for (i=2; i<=NF; i++) {
        if ($i == a) { print $1; exit }
      }
    }
  ' /etc/hosts 2>/dev/null
}

# --- hosts_ensure_block -----------------------------------------------------
# Idempotent /etc/hosts management (D7 revised):
#   1. Read /etc/hosts (no sudo needed for read).
#   2. Compute expected block from aliases.tsv.
#   3. If block already matches → return 0 (no sudo prompt).
#   4. Otherwise: backup /etc/hosts → /tmp/ai-stack-hosts.bak-$RUN_ID (once per run).
#   5. Detect non-interactive sudo: bail with a clear message if not a tty
#      AND sudo -n is denied.
#   6. mktemp + sudo mv + dscacheutil_flush.
#   7. trap EXIT/INT/TERM to rm -f the tmp file.
#   8. Self-verify resolution; restore from backup if it fails.
hosts_ensure_block() {
  aliases_load || return 1
  local expected current
  expected="$(expected_hosts_block)" || return 1
  current="$(current_hosts_block)"

  if [[ "$current" == "$expected" ]]; then
    # No-op fast path — never prompts for sudo if the block is already correct.
    return 0
  fi

  # Sudo-availability check (D7-5).
  if ! sudo -n true 2>/dev/null && [[ ! -t 0 ]]; then
    err "hosts_ensure_block: /etc/hosts needs an update, but stdin is not a tty"
    err "and sudo cannot prompt non-interactively. Re-run from a real terminal,"
    err "or run: sudo -v   then re-invoke this command."
    return 1
  fi

  # Backup once per RUN_ID (D7-4).
  local backup="/tmp/ai-stack-hosts.bak-${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
  if [[ ! -f "$backup" ]]; then
    cp -p /etc/hosts "$backup" || { err "could not back up /etc/hosts to $backup"; return 1; }
    note "Backed up /etc/hosts → $backup"
  fi

  # Build merged file: existing contents with any prior managed block stripped,
  # then append the fresh block at the end.
  local tmp
  tmp="$(mktemp /tmp/ai-stack-hosts.new.XXXXXX)" || { err "mktemp failed"; return 1; }
  chmod 644 "$tmp"

  # Trap to clean up tmp on early exit / interrupt (D7-7).
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT INT TERM

  awk -v b="$HOSTS_MARK_BEGIN" -v e="$HOSTS_MARK_END" '
    $0==b { skip=1; next }
    skip && $0==e { skip=0; next }
    skip { next }
    { print }
  ' /etc/hosts > "$tmp"

  # Strip any trailing blank lines so the appended block isn't preceded by
  # a stack of blanks. macOS sed lacks GNU's tail tricks; awk is cleanest.
  local stripped
  stripped="$(mktemp /tmp/ai-stack-hosts.new.XXXXXX)" || { err "mktemp failed"; return 1; }
  chmod 644 "$stripped"
  awk '
    { lines[NR]=$0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i=1; i<=last; i++) print lines[i]
    }
  ' "$tmp" > "$stripped"
  mv -f "$stripped" "$tmp"

  # Append a blank line separator + the new managed block.
  printf '\n' >> "$tmp"
  expected_hosts_block >> "$tmp"

  # Atomic move with sudo (D7-3).
  log "Updating /etc/hosts (sudo required)..."
  if ! sudo mv -f "$tmp" /etc/hosts; then
    err "sudo mv $tmp /etc/hosts failed"
    return 1
  fi
  # tmp no longer exists after mv; the trap rm is a no-op.

  # Restore canonical OWNER + perms on /etc/hosts (Reviewer Y-1).
  # The tmp file is owned by the invoking user; `sudo mv` preserves that
  # ownership across the rename, silently demoting /etc/hosts to a
  # user-writable file. Re-chown + chmod restores the OS integrity boundary.
  sudo chown root:wheel /etc/hosts >/dev/null 2>&1 || true
  sudo chmod 644 /etc/hosts >/dev/null 2>&1 || true

  # Flush DNS cache (D7-4).
  log "Flushing macOS DNS cache..."
  dscacheutil_flush || warn "dscacheutil_flush returned non-zero (cache may be stale briefly)"

  # Self-verify (D7-8): pick one well-known alias to confirm resolution.
  local got
  got="$(resolve_alias litellm)"
  if [[ "$got" != "${ALIAS_IP[litellm]}" ]]; then
    err "self-verify FAILED: 'litellm' resolves to '$got' (expected ${ALIAS_IP[litellm]})"
    err "Restoring /etc/hosts from $backup ..."
    if sudo cp -p "$backup" /etc/hosts; then
      dscacheutil_flush || true
      err "Restored. Backup preserved at $backup for inspection."
    else
      err "RESTORE ALSO FAILED. Manual recovery required from $backup"
    fi
    return 1
  fi

  ok "/etc/hosts updated; ${#ALIASES_LIST[@]} aliases now resolve"
  record "wrote /etc/hosts managed block (${#ALIASES_LIST[@]} aliases)"
  trap - EXIT INT TERM
  return 0
}

# --- hosts_remove_block -----------------------------------------------------
# Strip the >>> ai-stack block out of /etc/hosts. Atomic. Used by
# `reset --confirm nuke`.
hosts_remove_block() {
  if ! grep -qF "$HOSTS_MARK_BEGIN" /etc/hosts 2>/dev/null; then
    return 0
  fi

  if ! sudo -n true 2>/dev/null && [[ ! -t 0 ]]; then
    err "hosts_remove_block: needs sudo but stdin is not a tty. Re-run from a real terminal."
    return 1
  fi

  local backup="/tmp/ai-stack-hosts.bak-${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
  if [[ ! -f "$backup" ]]; then
    cp -p /etc/hosts "$backup" || { err "could not back up /etc/hosts"; return 1; }
    note "Backed up /etc/hosts → $backup"
  fi

  local tmp
  tmp="$(mktemp /tmp/ai-stack-hosts.new.XXXXXX)" || return 1
  chmod 644 "$tmp"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT INT TERM

  awk -v b="$HOSTS_MARK_BEGIN" -v e="$HOSTS_MARK_END" '
    $0==b { skip=1; next }
    skip && $0==e { skip=0; next }
    skip { next }
    { print }
  ' /etc/hosts > "$tmp"

  # Trim trailing blank lines for a clean file.
  local stripped
  stripped="$(mktemp /tmp/ai-stack-hosts.new.XXXXXX)" || return 1
  chmod 644 "$stripped"
  awk '
    { lines[NR]=$0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i=1; i<=last; i++) print lines[i]
    }
  ' "$tmp" > "$stripped"
  mv -f "$stripped" "$tmp"

  if ! sudo mv -f "$tmp" /etc/hosts; then
    err "sudo mv failed; /etc/hosts unchanged"
    return 1
  fi
  sudo chmod 644 /etc/hosts >/dev/null 2>&1 || true
  dscacheutil_flush || true
  ok "/etc/hosts managed block removed"
  record "removed /etc/hosts managed block"
  trap - EXIT INT TERM
  return 0
}
