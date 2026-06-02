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
# hermes-fleet-v1.yaml). Default model is `local` = gemma4:e4b — LIGHT + FAST
# (~9.6GB), workable for interactive chat / claw3d / the Telegram gateway on a
# 24GB box. (local-heavy = qwen3.6:27b ~22GB thrashes 24GB → slow; still available
# as an explicit alias for heavy reasoning, just not the default.) All-local, no cloud.
LITELLM_SANDBOX_URL="http://host.docker.internal:4000/v1"
# Availability-gating fallback target = models.yml .default (local-gemma4), so a
# fresh install (LM Studio down) renders gated profiles to the SAME id that doctor
# check 40 + `model sync` expect — no false-positive DRIFT. Falls back to the
# literal `local` only when models.yml is absent (partial checkout).
HERMES_MODEL="local"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _hd="$(yq -r '.default' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_hd" && "$_hd" != "null" ]] && HERMES_MODEL="$_hd"
fi

MODELS_YML="$AI_STACK/installer/models.yml"

# fleet_profiles — DATA-DRIVEN roster: top-level kinds entries whose
# kind==hermes-profile. Capture-then-grep (errexit/pipefail-safe).
# NOTE: byte-identical to installer/lib/fleet.sh::fleet_profiles — keep the yq
# expression in sync (divergence would silently break the SOUL_COUNT guard).
fleet_profiles() {
  local out
  out="$(yq -r '.kinds | to_entries | map(select(.value.kind=="hermes-profile")) | .[].key' "$MODELS_YML" 2>/dev/null || true)"
  grep -v '^[[:space:]]*$' <<<"$out" || true
}

# profile_desc <name> — the kinds.<name>.desc role string ("" if absent).
profile_desc() { yq -r ".kinds.\"$1\".desc // \"\"" "$MODELS_YML" 2>/dev/null || true; }

# Canonical descriptions for the core 7 (profile_desc fallback so 04f renders
# byte-identically to the legacy hardcoded PROFILES array for them).
core7_desc() {
  case "$1" in
    hermes_cos)               echo "chief of staff — decomposes goals, routes to specialists, does not implement" ;;
    hermes_software_engineer) echo "pragmatic senior engineer — minimal-diff code, tests, refactors" ;;
    hermes_researcher)        echo "research collaborator — cites every claim, distinguishes evidence from speculation" ;;
    hermes_creator)           echo "careful writer — shapes research into audience-ready prose" ;;
    hermes_reviewer)          echo "rigorous reviewer — blocks with review-required: prefix when changes needed" ;;
    hermes_data_analyst)      echo "data analyst — SQL and Python answering specific questions over real data" ;;
    hermes_ops)               echo "ops engineer — deploys, monitoring, incidents; prefers boring working systems" ;;
    *)                        echo "" ;;
  esac
}

# resolve_desc <name> — kinds.desc, else the canonical core-7 description, else
# the profile name (used as the minimal-soul role + the bootstrap roster field).
resolve_desc() {
  local d; d="$(profile_desc "$1")"
  [[ -z "$d" || "$d" == "null" ]] && d="$(core7_desc "$1")"
  [[ -z "$d" ]] && d="$1"
  printf '%s' "$d"
}

# CORE7 force-seed list (preserve restore-on-reinstall for the canonical souls).
CORE7=(hermes_cos hermes_software_engineer hermes_researcher hermes_creator hermes_reviewer hermes_data_analyst hermes_ops)

# PROFILES — derived `name|desc` roster for the host-side configure loop.
PROFILES=()
while IFS= read -r _p; do
  [[ -z "$_p" ]] && continue
  PROFILES+=("$_p|$(resolve_desc "$_p")")
done < <(fleet_profiles)

precheck() {
  command -v openshell >/dev/null || return 1
  [[ -d "$SOULS_DIR" ]] || return 1
  local prof
  while IFS= read -r prof; do
    [[ -z "$prof" ]] && continue
    [[ -f "$SOULS_DIR/${prof}.md" ]] || return 1
  done < <(fleet_profiles)
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

# --- Universal seed for any DERIVED non-core profile missing a soul ---------
# After the unconditional core-7 seeds above, ensure EVERY derived profile has a
# soul before upload (so the SOUL_COUNT guard can't false-abort). Only seeds when
# ABSENT — user-edited fleet (non-core) souls survive re-runs by design. Shares
# the minimal template byte-for-byte with installer/lib/fleet.sh::render_minimal_soul.
seed_minimal_soul() {
  local name="$1" role="$2" f="$SOULS_DIR/${name}.md"
  printf '%s\n' \
'# Identity' \
"$role" \
'' \
'# Style' \
'- Be concise and concrete.' \
'' \
'# Defaults' \
'- Ask one clarifying question when the request is ambiguous.' \
'' \
'# Avoid' \
'- Inventing facts, APIs, or behavior you did not verify.' > "$f"
  ok "seeded minimal soul $f"
}
while IFS= read -r _dp; do
  [[ -z "$_dp" ]] && continue
  _is_core=0; for _c in "${CORE7[@]}"; do [[ "$_dp" == "$_c" ]] && { _is_core=1; break; }; done
  (( _is_core )) && continue
  [[ -f "$SOULS_DIR/${_dp}.md" ]] || seed_minimal_soul "$_dp" "$(resolve_desc "$_dp")"
done < <(fleet_profiles)

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
EOF
# Inject the DERIVED roster (name|description only — the legacy 3rd `local-heavy`
# field was dead; bootstrap's create only uses fields 1-2). Generated from the
# data-driven fleet_profiles roster so `fleet add` profiles appear here too.
{
  printf 'ROSTER=(\n'
  for entry in "${PROFILES[@]}"; do
    _rn="${entry%%|*}"; _rd="${entry#*|}"
    # Strip any '|' from the description so the `read -r name desc` split is clean.
    _rd="${_rd//|/ }"
    printf '  "%s|%s"\n' "$_rn" "$_rd"
  done
  printf ')\n'
} >> "$BOOT_DIR/bootstrap.sh"
cat >> "$BOOT_DIR/bootstrap.sh" <<'EOF'
for entry in "${ROSTER[@]}"; do
  IFS='|' read -r name desc <<< "$entry"
  # Capture-then-grep: a direct `hermes profile list | awk | grep -q` pipe dies
  # under `set -o pipefail` when grep -q closes the pipe (SIGPIPE 141) — that
  # could wedge the bootstrap mid-roster. Capture first, then grep the var.
  _plist="$(hermes profile list 2>/dev/null | awk '{print $1}')"
  if grep -qxF "$name" <<<"$_plist"; then
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
# Expect one uploaded soul per DERIVED profile (>=7; the reserved guard keeps the
# core 7 unremovable so this floor always holds). The universal seeder above
# guarantees a soul exists on disk for every derived profile before upload.
_EXPECT="$(fleet_profiles | wc -l | tr -d '[:space:]')"
[[ "$_EXPECT" =~ ^[0-9]+$ ]] || _EXPECT=7
if [[ "${SOUL_COUNT:-0}" -lt "$_EXPECT" ]]; then
  err "Expected $_EXPECT souls in /sandbox/fleet-souls, found ${SOUL_COUNT:-0}. Aborting."
  err "Profiles lacking an uploaded soul (derived vs on-disk):"
  while IFS= read -r _ep; do
    [[ -z "$_ep" ]] && continue
    [[ -f "$SOULS_DIR/${_ep}.md" ]] || err "    $_ep (no soul on host)"
  done < <(fleet_profiles)
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
# Scoped key is minted against the fixed SUPERSET (legacy IDs UNION the 3
# canonical model<->agent slugs) so a later `install.sh model assign/sync` never
# needs to re-mint when a profile is pointed at local-qwen3.6 / local-qwen3-coder.
# These canonical IDs are registered in config.yaml by Phase 01 BEFORE this mint
# (superset-before-mint). LiteLLM still enforces the allowlist server-side.
HERMES_SUPERSET_JSON='["local","local-gemma4","local-heavy","local-lfm2","local-qwen3-coder","local-qwen3.6"]'
HERMES_KEY="$(get_env HERMES_LITELLM_KEY '')"
if [[ -z "$HERMES_KEY" ]] \
   || ! curl -sf --max-time 5 -H "Authorization: Bearer $HERMES_KEY" http://litellm:4000/v1/models >/dev/null 2>&1; then
  log "Minting LiteLLM virtual key for Hermes (models=superset[local,local-gemma4,local-heavy,local-lfm2,local-qwen3-coder,local-qwen3.6])..."
  HERMES_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate \
    -d "{\"models\":${HERMES_SUPERSET_JSON},\"key_alias\":\"hermes-fleet\",\"metadata\":{\"owner\":\"hermes\",\"purpose\":\"phase04f\"}}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$HERMES_KEY_NEW" ]] || { err "Failed to mint HERMES_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env HERMES_LITELLM_KEY "$HERMES_KEY_NEW"
  HERMES_KEY="$HERMES_KEY_NEW"
  ok "HERMES_LITELLM_KEY minted (superset allowlist) + saved to .env (mode 0600)"
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
# resolve_profile_model <profile> — the per-profile model from installer/models.yml,
# availability-gated. Falls back to HERMES_MODEL (=local) when:
#   - models.yml is absent (fresh checkout / partial install), OR
#   - the assigned model is lmstudio AND LM Studio (:1234) is down / the served id
#     isn't in litellm/config.yaml (we must NOT render an MLX slug LiteLLM can't
#     serve — that would 503/404 the profile). FIXES the old dead `local-heavy`
#     3rd-field tag: every profile was hardcoded to HERMES_MODEL=local before.
MODELS_YML="$AI_STACK/installer/models.yml"
LITELLM_CFG="$AI_STACK/litellm/config.yaml"
_lms_up() { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null; }
resolve_profile_model() {
  local profile="$1" declared rt served
  [[ -f "$MODELS_YML" ]] && command -v yq >/dev/null 2>&1 || { echo "$HERMES_MODEL"; return; }
  declared="$(yq -r ".assignments.\"$profile\" // \"\"" "$MODELS_YML" 2>/dev/null)"
  [[ -z "$declared" || "$declared" == "null" ]] && { echo "$HERMES_MODEL"; return; }
  rt="$(yq -r ".models.\"$declared\".runtime" "$MODELS_YML" 2>/dev/null)"
  if [[ "$rt" != "lmstudio" ]]; then echo "$declared"; return; fi
  # lmstudio: availability-gate.
  if _lms_up && grep -qF "model_name: ${declared}" "$LITELLM_CFG" 2>/dev/null \
     && curl -s --max-time 5 http://litellm:4000/v1/models -H "Authorization: Bearer $HERMES_KEY" 2>/dev/null \
        | grep -qF "\"$declared\""; then
    echo "$declared"; return
  fi
  echo "$HERMES_MODEL"   # gated fallback
}

# configure_hermes_profile <pflag> <model>
# <pflag>: "" for the default profile, or "--profile <name>".
# provider=custom:litellm + base_url are model-independent (set once here; safe
# to re-set). api_key is re-piped via STDIN ONLY (never in argv/log).
configure_hermes_profile() {
  local pflag="$1" model="$2"
  openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c \
    "hermes $pflag config set model.default $model >/dev/null; hermes $pflag config set model.provider custom:litellm >/dev/null; hermes $pflag config set providers.litellm.base_url $LITELLM_SANDBOX_URL >/dev/null; hermes $pflag config set providers.litellm.model $model >/dev/null" \
    2>&1 | tail -2 || warn "hermes ${pflag:-(default)} non-secret config returned non-zero"
  printf '%s' "$HERMES_KEY" | openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -c \
    "read -r K; hermes $pflag config set providers.litellm.api_key \"\$K\" >/dev/null" \
    >/dev/null 2>&1 || warn "hermes ${pflag:-(default)} api_key config returned non-zero"
}
log "Configuring Hermes profiles → LiteLLM (per-profile model from models.yml, availability-gated)..."
configure_hermes_profile "" "$HERMES_MODEL"       # default profile (root config) keeps the safe default
for entry in "${PROFILES[@]}"; do
  _prof="${entry%%|*}"
  _model="$(resolve_profile_model "$_prof")"
  note "  $_prof -> $_model"
  configure_hermes_profile "--profile $_prof" "$_model"
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
record "phase 04·F complete: $_EXPECT hermes profiles bootstrapped + routed to LiteLLM ($HERMES_MODEL) in sandbox $SANDBOX"
ok "Phase 04·F — Hermes fleet — complete"
