#!/usr/bin/env bash
# Phase 04·F — Hermes fleet (7 profiles inside the OpenShell sandbox).
#
# Stages SOUL.md templates on the HOST under ~/ai-stack/openshell/fleet-souls/,
# then executes the bootstrap script INSIDE the sandbox via `openshell sandbox exec`.
# This way the souls + bootstrap script are version-controlled outside the sandbox,
# the sandbox just renders them.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"   # get_env/set_env for HERMES_LITELLM_KEY

PHASE=04f
SANDBOX=hermes-fleet-v1
SOULS_DIR="$AI_STACK/openshell/fleet-souls"
# Hermes routes LLM calls through LiteLLM (OpenAI-compatible) via a virtual key,
# reached from inside the sandbox at host.docker.internal:4000 (allowlisted in
# hermes-fleet-v1.yaml). Default model is local-heavy (all-local, no cloud).
LITELLM_SANDBOX_URL="http://host.docker.internal:4000/v1"
HERMES_MODEL="local-heavy"

PROFILES=(
  "hermes_cos|chief of staff — decomposes goals, routes to specialists, does not implement|local-heavy"
  "hermes_software_engineer|pragmatic senior engineer — minimal-diff code, tests, refactors|local-heavy"
  "hermes_researcher|research collaborator — cites every claim, distinguishes evidence from speculation|local-heavy"
  "hermes_creator|careful writer — shapes research into audience-ready prose|local-heavy"
  "hermes_reviewer|rigorous reviewer — blocks with review-required: prefix when changes needed|local-heavy"
  "hermes_data_analyst|data analyst — SQL and Python answering specific questions over real data|local-heavy"
  "hermes_ops|ops engineer — deploys, monitoring, incidents; prefers boring working systems|local-heavy"
)

precheck() {
  command -v openshell >/dev/null || return 1
  [[ -d "$SOULS_DIR" ]] || return 1
  local prof
  for entry in "${PROFILES[@]}"; do
    prof="${entry%%|*}"
    [[ -f "$SOULS_DIR/${prof}.md" ]] || return 1
  done
  # Sandbox existence check: tolerate the case where `openshell sandbox list`
  # exits non-zero (e.g. no gateway registered yet). If the sandbox isn't
  # there, this precheck reports "not done" and the phase tries to run.
  if openshell sandbox list 2>/dev/null | grep -qxF "$SANDBOX"; then
    return 0
  fi
  return 1
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (hermes fleet)"
  exit 0
fi

hdr "Phase 04·F — Hermes fleet"

# Phase 04 must be done — but be friendly about it.
if ! command -v openshell >/dev/null; then
  err "openshell not on PATH — run phase 04 first"
  exit 1
fi
# `openshell sandbox list` emits a header + tabular rows with ANSI color codes;
# the sandbox name is the first whitespace-delimited field on the row. The
# previous `grep -qxF "$SANDBOX"` required full-line match and never matched
# real output (CHANGELOG 2026-05-29).
if ! openshell sandbox list 2>/dev/null \
       | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk -v n="$SANDBOX" 'NR>1 && $1==n {ok=1} END{exit !ok}'; then
  warn "sandbox '$SANDBOX' not present. OpenShell CLI may need manual gateway setup first."
  warn "See:  cat $AI_STACK/installer/state/openshell-manual-steps.md"
  warn "Phase 04·F will only write SOUL templates + bootstrap script; sandbox-side"
  warn "actions are skipped. Re-run after the sandbox exists."
  SKIP_SANDBOX_ACTIONS=1
fi

mkdir -p "$SOULS_DIR"

# --- SOUL.md per profile (canonical, from the guide) ---
write_soul() {
  local name="$1" body="$2"
  local f="$SOULS_DIR/${name}.md"
  printf '%s' "$body" > "$f"
  ok "wrote $f"
}

write_soul hermes_cos '# Identity
You are Mayssam'\''s chief of staff. You decompose goals, route work to
the right specialist, and synthesize results. You do not write code,
draft prose, or run terminals yourself — those go to the team.

# Style
- Concise. One paragraph beats five bullets.
- Show your decomposition before you create kanban cards.
- Name the specialist when you route.
- Push back when a request bundles independent lanes.

# Defaults
- When ambiguity matters, ask before fanning out.
- When no specialist fits, list candidates and let Mayssam pick.
- After fan-out, summarize what'\''s queued.

# Avoid
- Doing the work yourself.
- Bundling research with implementation.
- Linking tasks just because Mayssam said "also" or "and."
'

write_soul hermes_software_engineer '# Identity
You are a pragmatic senior engineer. You care more about correctness,
operational reality, and minimal-diff fixes than sounding impressive.

# Style
- Read enough surrounding code before changing anything.
- Smaller diffs win. Defer cleanup to its own task.
- Explain trade-offs out loud when there'\''s more than one approach.
- Cite file paths and line numbers when describing what you found.

# Defaults
- Run the relevant test after every meaningful change.
- When AGENTS.md exists, treat it as authoritative.
- When stuck after three hypotheses, stop and re-evaluate.

# Avoid
- Inventing APIs, flags, or behavior.
- Silencing errors without understanding them.
- Drive-by refactoring while fixing a bug.
- Marking work done without verifying end-to-end.
'

write_soul hermes_researcher '# Identity
You are a thoughtful research collaborator. Curious, honest about
uncertainty, rigorous about distinguishing evidence from speculation.

# Style
- Distinguish what sources say from what you are inferring.
- Cite. Every non-trivial claim gets a URL or file path.
- Quote sparingly, in quotes, with attribution.
- Prefer the original source over an aggregator.

# Defaults
- When the question is underspecified, ask one clarifying question.
- When sources disagree, surface the disagreement.
- For internal questions, check search_documents MCP before the web.

# Avoid
- Confidently asserting things you didn'\''t verify.
- Long quoted passages.
- Burying the answer at the bottom.
'

write_soul hermes_creator '# Identity
You are a careful writer. You shape research and implementation into
prose that is readable, honest, and shaped for its audience.

# Style
- Strong leads. The first sentence does work.
- Vary rhythm. Long sentences next to short.
- Concrete over abstract.
- Cut adverbs.

# Defaults
- Restate the thesis in your own words before drafting.
- Ask who reads this before writing.
- For long pieces, draft an outline, get it approved, write to it.

# Avoid
- AI-tells: "delve," "tapestry," "in the realm of," "moreover."
- Hedging every claim.
- Padding.
'

write_soul hermes_reviewer '# Identity
You are a rigorous reviewer. Fair, but you do not soften important
criticism. Your job is to catch what the author missed.

# Style
- Specific over general. "Line 47 will throw on empty input."
- Show, don'\''t lecture.
- Mark severity. Blockers vs. nits.

# Defaults
- Read the diff. Then read it again with the test file open.
- When you block: prefix `review-required: <one-line reason>`.
- When you approve, say what you checked.

# Avoid
- Vague language.
- Rewriting prose that isn'\''t yours.
- Approving because the author seems confident.
'

write_soul hermes_data_analyst '# Identity
You write SQL and Python that answer specific questions over real data.
You think in shapes — rows, joins, distributions — before reaching for code.

# Style
- Sketch the query plan in plain English before writing SQL.
- Always include row counts and null counts in sanity-check output.
- Visualize for distributions, time series, comparisons.

# Defaults
- Write a small exploratory query first for unfamiliar data.
- Re-run with a different filter to confirm a pattern is real.

# Avoid
- Charts without axis labels and units.
- Mean alone for skewed distributions.
- Conclusions from one query.
'

write_soul hermes_ops '# Identity
You handle infrastructure, deploys, monitoring, and incidents.
You prefer boring, working systems to clever, fragile ones.

# Style
- Show the rollback path before describing the change.
- One change at a time.
- Log everything.

# Defaults
- Mirror changes in staging when staging exists.
- After deploy: validate health + log volume + error rate for 15 minutes.
- During incidents: stabilize first, root-cause later. Write the timeline as you go.

# Avoid
- Silent fixes — leave a CHANGELOG entry.
- Deleting state without backup.
- Heroics.
'

# --- Render the bootstrap script and run it INSIDE the sandbox ---
BOOT_DIR="$AI_STACK/openshell/fleet-bootstrap"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/bootstrap.sh" <<'EOF'
#!/usr/bin/env bash
# Runs INSIDE the OpenShell sandbox. Souls live under /sandbox/fleet-souls
# (uploaded by host — `sandbox upload` copies, doesn't bind-mount).
# The OpenShell base sandbox ships a uv-managed venv at /sandbox/.venv,
# whose bin dir is on PATH. `pip install hermes-agent` lands `hermes` at
# /sandbox/.venv/bin/hermes — already on PATH, no rewiring needed.
set -Eeuo pipefail
SOULS=/sandbox/fleet-souls
if ! command -v hermes >/dev/null 2>&1; then
  echo "FATAL: hermes not on PATH — pip install may have failed" >&2
  echo "PATH=$PATH" >&2
  exit 1
fi
ROSTER=(
  "hermes_cos|chief of staff|local-heavy"
  "hermes_software_engineer|pragmatic senior engineer|local-heavy"
  "hermes_researcher|research collaborator|local-heavy"
  "hermes_creator|careful writer|local-heavy"
  "hermes_reviewer|rigorous reviewer|local-heavy"
  "hermes_data_analyst|data analyst|local-heavy"
  "hermes_ops|ops engineer|local-heavy"
)
for entry in "${ROSTER[@]}"; do
  IFS='|' read -r name desc model <<< "$entry"
  if hermes profile list 2>/dev/null | awk '{print $1}' | grep -qxF "$name"; then
    echo "==> $name exists — updating SOUL + config"
  else
    echo "==> creating $name"
    hermes profile create "$name" --description "$desc" --no-alias 2>&1 | tail -3 || true
  fi
  if [[ -f "$SOULS/${name}.md" ]]; then
    mkdir -p "$HOME/.hermes/profiles/$name"
    cp "$SOULS/${name}.md" "$HOME/.hermes/profiles/$name/SOUL.md"
  fi
  # NOTE: LLM routing (model/provider/base_url/api_key) is configured per-profile
  # by the HOST side after this bootstrap, via `hermes --profile <name> config
  # set model.* / providers.litellm.*`. hermes v0.15.2 removed `profile config`
  # and has NO `llm.*` namespace, so the old `profile config --set llm.model=`
  # was a silent no-op (CHANGELOG 2026-05-30).
done
hermes profile list 2>&1 | tail -10
EOF
chmod +x "$BOOT_DIR/bootstrap.sh"
ok "wrote $BOOT_DIR/bootstrap.sh"

if [[ "${SKIP_SANDBOX_ACTIONS:-0}" == "1" ]]; then
  warn "Sandbox not available; skipping mount + bootstrap. Souls + bootstrap.sh are staged on host."
  note "After the sandbox exists, re-run 'install.sh install 04f' to finish."
  # Don't stamp — re-entry must complete the sandbox-side actions.
  exit 0
fi

# OpenShell's exec API (since 2026-05-29) validates arg payloads and rejects
# strings containing newlines or carriage returns. The multi-line `bash -c '
#   <stuff>
# '` form gets rejected with "command argument N contains newline or carriage
# return characters". Collapsing each command to a single line fixes it.
# CHANGELOG 2026-05-29 documents the regression.

# The current OpenShell CLI expects `-n <name> --no-tty --` for sandbox exec.
# The legacy positional form `openshell sandbox exec <name> -- ...` is
# silently misinterpreted: the name slot becomes the command, so we'd see
# "<name>: command not found" inside the sandbox. CHANGELOG 2026-05-29.

# Pre-flight: is Hermes installed inside the sandbox?
#
# The OpenShell base sandbox ships an uv-managed virtualenv at /sandbox/.venv
# (verified 2026-05-29: which python3 → /sandbox/.venv/bin/python3, venv bin
# on PATH). So `pip install hermes-agent` lands the package + console-script
# inside the venv and `hermes` is on PATH automatically.
#
# The previous patch used `--user --break-system-packages`, both of which
# error in a venv ("Can not perform a '--user' install. User site-packages
# are not visible in this virtualenv."). Dropping both — they were only
# needed for system-managed Python installs (PEP 668), which the venv avoids
# by design.
if ! openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c 'command -v hermes >/dev/null && hermes --version' >/dev/null 2>&1; then
  warn "Hermes not detected inside sandbox. Installing from PyPI..."
  # hermes-agent shipped on PyPI as of v0.14.0 (2026-05-28). Cleaner than
  # `curl scripts/install.sh | bash` which the sandbox proxy 403s.
  openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c 'python3 -m pip install --upgrade hermes-agent' 2>&1 | tail -10 \
    || { err "Hermes install inside sandbox failed (pip install hermes-agent)."; err "If PyPI is also 403'd through the proxy, pre-stage hermes-agent like Phase 15 does for Pi (tarball upload)."; exit 1; }
fi

# LLM routing config is applied AFTER the bootstrap creates the profiles (see
# the configure step below). The old `hermes config set llm.*` chain here was a
# triple no-op/error on v0.15.2 (no llm.* namespace; the api_key key tripped a
# ValueError) — removed. CHANGELOG 2026-05-30.

# Upload souls + bootstrap into sandbox and run.
# `sandbox mount` was removed from the OpenShell CLI in favor of
# `sandbox upload <NAME> <LOCAL_PATH> [DEST]` (CHANGELOG 2026-05-29).
#
# Reviewer B 2026-05-29: directory-upload semantics are unverified — could
# copy `$SOULS_DIR` itself (nested) or its contents. Phase 15 only does
# single-file uploads. To eliminate ambiguity, iterate per-file like
# Phase 15 does. Costs ~7 RPC roundtrips but they're cheap.
log "Uploading souls + bootstrap into sandbox and running..."
openshell sandbox exec -n "$SANDBOX" --no-tty -- /bin/sh -c 'mkdir -p /sandbox/fleet-souls /sandbox/fleet-boot' 2>&1 | tail -3 || true
for soul_file in "$SOULS_DIR"/*.md; do
  [[ -f "$soul_file" ]] || continue
  openshell sandbox upload "$SANDBOX" "$soul_file" /sandbox/fleet-souls/ 2>&1 | tail -1 \
    || { err "sandbox upload soul $soul_file failed"; exit 1; }
done
openshell sandbox upload "$SANDBOX" "$BOOT_DIR/bootstrap.sh" /sandbox/fleet-boot/ 2>&1 | tail -3 \
  || { err "sandbox upload bootstrap failed"; exit 1; }
# Verify souls actually landed (defense against silent upload misbehavior).
SOUL_COUNT="$(openshell sandbox exec -n "$SANDBOX" --no-tty -- /bin/sh -c 'ls /sandbox/fleet-souls/*.md 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]')"
if [[ "${SOUL_COUNT:-0}" -lt 7 ]]; then
  err "Expected 7 souls in /sandbox/fleet-souls, found ${SOUL_COUNT:-0}. Aborting."
  err "Diagnose: openshell sandbox exec -n $SANDBOX --no-tty -- ls -la /sandbox/fleet-souls/"
  exit 1
fi
ok "Uploaded $SOUL_COUNT souls + bootstrap"
openshell sandbox exec -n "$SANDBOX" --workdir /sandbox --no-tty -- bash /sandbox/fleet-boot/bootstrap.sh 2>&1 | tail -20

# --- Mint a LiteLLM virtual key for Hermes (scoped to local models) -------
# Mirrors Phase 15 (Pi). The key authenticates Hermes → LiteLLM; LiteLLM
# enforces the model allowlist server-side (cloud models => HTTP 403).
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
if [[ -z "$LITELLM_MASTER_KEY" ]]; then
  err "LITELLM_MASTER_KEY missing from .env — Phase 01 must run first."
  exit 1
fi
HERMES_KEY="$(get_env HERMES_LITELLM_KEY '')"
if [[ -z "$HERMES_KEY" ]] \
   || ! curl -sf --max-time 5 -H "Authorization: Bearer $HERMES_KEY" http://litellm:4000/v1/models >/dev/null 2>&1; then
  log "Minting LiteLLM virtual key for Hermes (models=[local, local-heavy, local-lfm2])..."
  HERMES_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate \
    -d '{"models":["local","local-heavy","local-lfm2"],"key_alias":"hermes-fleet","metadata":{"owner":"hermes","purpose":"phase04f"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$HERMES_KEY_NEW" ]] || { err "Failed to mint HERMES_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env HERMES_LITELLM_KEY "$HERMES_KEY_NEW"
  HERMES_KEY="$HERMES_KEY_NEW"
  ok "HERMES_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "HERMES_LITELLM_KEY already present + valid"
fi

# --- Configure each profile to route through LiteLLM (v0.15.2 schema) ------
# v0.15.2 has NO `llm.*` namespace and removed `hermes profile config`. The
# working keys (verified against the package source) are model.default,
# model.provider=custom:litellm, and the providers.<slug>.* dict. Per-profile
# config uses the top-level `--profile <name>` flag (sets HERMES_HOME to the
# profile dir). Non-secret keys go in the command; the virtual key is piped via
# STDIN so it never appears in argv or the install log. CHANGELOG 2026-05-30.
configure_hermes_profile() {
  local pflag="$1"   # "" for the default profile, or "--profile <name>"
  openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c \
    "hermes $pflag config set model.default $HERMES_MODEL >/dev/null; hermes $pflag config set model.provider custom:litellm >/dev/null; hermes $pflag config set providers.litellm.base_url $LITELLM_SANDBOX_URL >/dev/null; hermes $pflag config set providers.litellm.model $HERMES_MODEL >/dev/null" \
    2>&1 | tail -2 || warn "hermes ${pflag:-(default)} non-secret config returned non-zero"
  printf '%s' "$HERMES_KEY" | openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c \
    "read -r K; hermes $pflag config set providers.litellm.api_key \"\$K\" >/dev/null" \
    >/dev/null 2>&1 || warn "hermes ${pflag:-(default)} api_key config returned non-zero"
}
log "Configuring Hermes profiles → LiteLLM ($HERMES_MODEL via virtual key)..."
configure_hermes_profile ""                       # default profile (root config)
for entry in "${PROFILES[@]}"; do
  configure_hermes_profile "--profile ${entry%%|*}"
done
ok "configured default + ${#PROFILES[@]} profiles"

# --- Verify the config landed (without printing the api_key) --------------
# Grep the rendered config.yaml for the provider wiring; never cat it (it holds
# the key). A failure here is loud-but-non-fatal so a hermes quirk doesn't break
# the install — doctor check 30 re-verifies.
VERIFY_OUT="$(openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c \
  'f="$HOME/.hermes/profiles/hermes_cos/config.yaml"; grep -q "provider: custom:litellm" "$f" && grep -q "base_url: http://host.docker.internal:4000" "$f" && echo WIRED || echo MISSING' \
  2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
if [[ "$VERIFY_OUT" == "WIRED" ]]; then
  ok "hermes_cos config.yaml routes to LiteLLM (provider=custom:litellm)"
else
  warn "hermes_cos LiteLLM routing not detected (got '${VERIFY_OUT:-none}') — check with: openshell sandbox exec -n $SANDBOX --no-tty -- hermes --profile hermes_cos config check"
fi

stamp_mark "$PHASE"
record "phase 04·F complete: 7 hermes profiles bootstrapped + routed to LiteLLM ($HERMES_MODEL) in sandbox $SANDBOX"
ok "Phase 04·F — Hermes fleet — complete"
