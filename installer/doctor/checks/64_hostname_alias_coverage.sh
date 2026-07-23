# Every services.yml service whose open_url is a bare hostname has a matching
# installer/lib/aliases.tsv row (so prepare-sudo / ingress actually create that name).
#
# services.yml (open_url) and aliases.tsv are two hand-maintained sources that must
# agree: an open_url like http://deerflow:2026 only resolves if `deerflow` is a row in
# aliases.tsv (which drives /etc/hosts + the lo0 alias + the Caddy ingress site). This
# guards the class of gap where a service gains a hostname open_url but no alias row —
# exactly the deerflow regression. localhost / IP-literal open_urls are exempt (no bare
# hostname needed). Forward-only (open_url ⊆ aliases): aliases.tsv may legitimately
# carry rows with no open_url (grpc/redis planes). Pure file parse; no external calls.
CHECKS+=(hostname_alias_coverage)
CHECK_TITLE[hostname_alias_coverage]="services.yml hostname open_urls have aliases.tsv rows"

hostname_alias_coverage_diagnose() {
  local sy="$AI_STACK/services.yml" at="$AI_STACK/installer/lib/aliases.tsv"
  command -v yq >/dev/null 2>&1 || { echo "yq not available — cannot parse services.yml. [skip]"; return 0; }
  [[ -f "$sy" && -f "$at" ]] || { echo "services.yml or aliases.tsv missing. [skip]"; return 0; }
  local _aliases
  _aliases="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$at" | awk '{print $1}')"
  # FAIL-CLOSED: a yq parse error / a services.yml with no `.services` map must NOT
  # read as "all good" (that silent-empty path is the bug the negative test caught).
  local bad="" url host urls rc
  urls="$(yq -r '.services[].open_url' "$sy" 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then
    echo "yq failed to parse services.yml (rc=$rc) — cannot verify hostname coverage (fail-closed)."
    return 1
  fi
  if [[ -z "$urls" ]]; then
    echo "services.yml yielded no .services open_url entries — unexpected (fail-closed, not a silent pass)."
    return 1
  fi
  while IFS= read -r url; do
    [[ -z "$url" || "$url" == "null" ]] && continue
    host="$(printf '%s' "$url" | sed -E 's#^https?://##; s#[:/].*$##')"
    [[ -z "$host" ]] && continue
    # exempt localhost + IPv4/IPv6 literals (intentionally alias-free, e.g. claw3d);
    # an IPv6 literal open_url extracts to a leading "[" — exempt it too.
    [[ "$host" == "localhost" || "$host" == "["* || "$host" =~ ^127\. || "$host" =~ ^[0-9.]+$ ]] && continue
    printf '%s\n' "$_aliases" | grep -qxF "$host" || bad+="    $host   (open_url: $url)"$'\n'
  done <<< "$urls"
  if [[ -n "$bad" ]]; then
    printf "open_url hostname(s) with NO installer/lib/aliases.tsv row (prepare-sudo/ingress can't create them):\n%s" "$bad"
    return 1
  fi
  echo "  (every services.yml hostname open_url has a matching aliases.tsv row)"
  return 0
}

hostname_alias_coverage_fix() {
  warn "A services.yml open_url uses a bare hostname with no aliases.tsv row. Either:"
  warn "  • add the row to installer/lib/aliases.tsv (alias<TAB>127.0.10.x<TAB>http<TAB>host_port<TAB>ctr_port<TAB>phase<TAB>key)"
  warn "    then run 'sudo mayssam-ai-stack.sh prepare-sudo' (+ 'ingress reload' for the port-free URL), or"
  warn "  • change the open_url back to http://localhost:PORT if the service is intentionally alias-free."
  return 1
}
