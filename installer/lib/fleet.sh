#!/usr/bin/env bash
# fleet.sh — the Hermes fleet manager.
#
#   vz-ai-stack.sh fleet list                          READ-ONLY: profiles in models.yml + sandbox presence
#   vz-ai-stack.sh fleet add <name> --role "<d>" [--model <m>] [--dry-run] [--no-sync]
#   vz-ai-stack.sh fleet remove <name> [--dry-run] [--keep-soul]
#   vz-ai-stack.sh fleet new <fleetname> [--profiles a,b,c] [--mint-key] [--allow-mlx] [--dry-run]
#   vz-ai-stack.sh fleet destroy <fleetname> [--dry-run]
#
# TWO scopes:
#   add/remove/list  — grow/shrink the EXISTING phase-04f sandbox `hermes-fleet-v1`
#                      by editing data (models.yml + souls) and re-rendering 04f.
#                      Phase 04f is DATA-DRIVEN over models.yml kinds==hermes-profile.
#   new/destroy      — stand up / tear down a SEPARATE isolated sandbox `<name>-v1`
#                      with its own deny-by-default policy + starter profile set.
#
# Design notes (load-bearing):
#   * NEVER loads a model. New/added profiles default to the nemotron-3-nano:4b ollama
#     `.default` so they are servable on a fresh box; availability-gating
#     handles a down runtime.
#   * NEVER echoes a key value (HERMES_LITELLM_KEY / FLEET_*_LITELLM_KEY).
#   * All `openshell sandbox exec` calls use `</dev/null` (stdin-contention bug).
#   * Capture-then-grep for every membership test (a direct `yq | grep -q` dies
#     under pipefail on SIGPIPE — see models.sh L70-75).
#   * DOCTOR COVERAGE GAP (intentional): doctor checks 30 (hermes routing) + 33
#     (telegram) HARDCODE the `hermes-fleet-v1` sandbox / `hermes_cos` profile.
#     `fleet new` sandboxes are NOT health-checked by doctor. We deliberately do
#     NOT touch checks 30/33 (keeps doctor 40/40). `fleet new` surfaces this in
#     its completion note.
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"   # port_listening
source "$AI_STACK/installer/lib/openshell.sh"  # openshell_sandbox_ensure/_delete (hang-resilient)

MODELS_YML="$AI_STACK/installer/models.yml"
SOULS_DIR="$AI_STACK/openshell/fleet-souls"
SANDBOX="hermes-fleet-v1"                       # the phase-04f managed fleet
STAMP="04f"
LITELLM_SANDBOX_URL="http://host.docker.internal:4000/v1"
LITELLM_CFG="$AI_STACK/litellm/config.yaml"
GATEWAY_PORT=17670
POLICIES_DIR="$AI_STACK/openshell/policies"

# The canonical hermes profiles 04f stages + which doctor 30 leans on (the AI
# software-engineering team). Reserved — `fleet remove` refuses these.
CORE7=(hermes_manager hermes_techlead hermes_frontend_engineer hermes_backend_engineer hermes_ml_engineer hermes_qa_test_engineer hermes_reviewing_engineer hermes_sre_engineer hermes_incident_manager)

# ---------------------------------------------------------------------------
# models.yml accessors (mirror lib/models.sh house style)
# ---------------------------------------------------------------------------
my_q() { yq -r "$1" "$MODELS_YML" 2>/dev/null; }

# fleet_profiles — THE single roster source: top-level kinds entries whose
# kind==hermes-profile. Capture-then-grep, errexit/pipefail-safe.
# NOTE: 04f defines a byte-identical fleet_profiles(). Keep the yq expression in
# sync — divergence would silently break the SOUL_COUNT guard.
fleet_profiles() {
  local out
  out="$(my_q '.kinds | to_entries | map(select(.value.kind=="hermes-profile")) | .[].key' 2>/dev/null || true)"
  grep -v '^[[:space:]]*$' <<<"$out" || true
}

is_fleet_profile() { local out; out="$(fleet_profiles)"; grep -qxF "$1" <<<"$out"; }
kinds_keys()       { local out; out="$(my_q '.kinds | keys | .[]')"; grep -v '^[[:space:]]*$' <<<"$out" || true; }
assign_keys()      { local out; out="$(my_q '.assignments | keys | .[]')"; grep -v '^[[:space:]]*$' <<<"$out" || true; }
model_exists()     { local out; out="$(my_q '.models | keys | .[]')"; grep -qxF "$1" <<<"$out"; }
profile_desc()     { my_q ".kinds.\"$1\".desc // \"\""; }

# valid_name — bare-underscore profile-name convention (matches hermes_cos).
# NOT models.sh's ^local- regex (those are model names). Returns 2 + err on fail.
valid_name() {
  if [[ "$1" =~ ^[a-z][a-z0-9_]*$ ]]; then return 0; fi
  err "invalid profile name '$1' — must match ^[a-z][a-z0-9_]*\$ (e.g. hermes_legal)"
  return 2
}

# is_reserved <name> <mode> — refuse collisions.
#   mode=add:    CORE7 OR any existing .kinds key OR any .assignments key
#                (so `fleet add pi/deerflow/ace/rlm` and the core 7 are refused).
#   mode=remove: CORE7 only (you only remove fleet profiles; is_fleet_profile
#                already excludes non-hermes kinds).
is_reserved() {
  local name="$1" mode="${2:-add}" c
  for c in "${CORE7[@]}"; do [[ "$name" == "$c" ]] && { err "'$name' is a canonical core profile (reserved)"; return 0; }; done
  if [[ "$mode" == "add" ]]; then
    local k
    while IFS= read -r k; do [[ -z "$k" ]] && continue; [[ "$name" == "$k" ]] && { err "'$name' already exists in models.yml kinds: (would collide)"; return 0; }; done < <(kinds_keys)
    while IFS= read -r k; do [[ -z "$k" ]] && continue; [[ "$name" == "$k" ]] && { err "'$name' already exists in models.yml assignments: (would collide)"; return 0; }; done < <(assign_keys)
  fi
  return 1
}

# ---------------------------------------------------------------------------
# OpenShell helpers (copied verbatim from lib/models.sh L393-404; dedup into
# lib/common.sh is a future cleanup — do NOT touch the working check 30 now).
# ---------------------------------------------------------------------------
osh_bin() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}

# sandbox_ready <name> — is the named sandbox present AND Phase=Ready?
sandbox_ready() {
  local osh name="$1"; osh="$(osh_bin)"
  [[ -n "$osh" ]] || return 1
  "$osh" sandbox list 2>/dev/null </dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -v s="$name" 'NR>1 && $1==s && $NF=="Ready" {ok=1} END{exit !ok}'
}
hermes_sandbox_ready() { sandbox_ready "$SANDBOX"; }

# ---------------------------------------------------------------------------
# Minimal SOUL template (shared byte-for-byte with 04f's universal seeder).
# Role is single-line; a newline is rejected upstream.
# ---------------------------------------------------------------------------
render_minimal_soul() {
  local role="$1"
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
'- Inventing facts, APIs, or behavior you did not verify.'
}

# write_soul <name> <role> — atomic temp+mv, 0644. Rejects a newline in role.
write_soul() {
  local name="$1" role="$2" f="$SOULS_DIR/${name}.md" tmp
  [[ "$role" == *$'\n'* ]] && { err "write_soul: refusing a newline in role for $name"; return 2; }
  mkdir -p "$SOULS_DIR"
  tmp="$(mktemp "${f}.XXXXXX")" || return 1
  chmod 0644 "$tmp"
  render_minimal_soul "$role" > "$tmp"
  mv -f "$tmp" "$f"
}

# _unlock — release the install lock + clear the EXIT/INT/TERM trap. Called
# BEFORE shelling out to vz-ai-stack.sh (each sub-invocation re-acquires its own
# lock; holding it across the shell-out would self-deadlock the child -> exit 3).
_unlock() { rm -rf "$LOCKDIR"; trap - EXIT INT TERM; }

# validate_models — run models.sh's fail-closed validate (matches how doctor 40
# validates). Exits with its code on failure.
validate_models() {
  bash "$AI_STACK/installer/lib/models.sh" list >/dev/null || exit $?
}

# ===========================================================================
# fleet add — grow the phase-04f fleet (hermes-fleet-v1)
# ===========================================================================
cmd_fleet_add() {
  local name="" role="" arg_model="" dry=0 nosync=0 expect_role=0 expect_model=0 a
  for a in "$@"; do
    if (( expect_role )); then role="$a"; expect_role=0; continue; fi
    if (( expect_model )); then arg_model="$a"; expect_model=0; continue; fi
    case "$a" in
      --role)    expect_role=1 ;;
      --model)   expect_model=1 ;;
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "fleet add: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$name" ]]; then name="$a"; else err "fleet add: unexpected arg '$a'"; exit 2; fi ;;
    esac
  done

  [[ -n "$name" ]] || { err "usage: vz-ai-stack.sh fleet add <name> --role \"<desc>\" [--model <m>] [--dry-run] [--no-sync]"; exit 2; }
  valid_name "$name" || exit 2
  [[ -n "$role" ]] || { err "fleet add: --role \"<description>\" is required"; exit 2; }
  [[ "$role" == *$'\n'* ]] && { err "fleet add: --role must be a single line"; exit 2; }

  validate_models

  # Resolve model: --model or models.yml .default (nemotron-3-nano:4b, ollama -> servable).
  local model; model="${arg_model:-$(my_q '.default')}"
  if [[ -n "$arg_model" ]] && ! model_exists "$model"; then
    err "fleet add: unknown model '$model'. Valid models:"
    my_q '.models | keys | .[]' | sed 's/^/    /' >&2
    exit 2
  fi

  # Idempotency FIRST — an existing fleet profile of the same name+model+role is
  # a no-op; same name with a different model/role refuses. (Checked before the
  # reserved/collision guard so a benign re-add isn't rejected as a collision.)
  if is_fleet_profile "$name"; then
    local cur_model cur_role
    cur_model="$(my_q ".assignments.\"$name\"")"
    cur_role="$(profile_desc "$name")"
    if [[ "$cur_model" == "$model" && "$cur_role" == "$role" ]]; then
      ok "fleet profile '$name' already present (model=$model); nothing to do"
      exit 0
    fi
    err "fleet profile '$name' exists with model=$cur_model role='$cur_role'; refusing to overwrite (remove it first)"
    exit 2
  fi

  # Reserved/collision guard (only reached when NOT an existing fleet profile):
  # refuse CORE7 + any other existing kinds/assignments key (pi/deerflow/ace/rlm).
  if is_reserved "$name" add; then exit 2; fi

  # Not a fleet profile, but a stray soul file exists -> collision.
  if [[ -e "$SOULS_DIR/${name}.md" ]]; then
    err "soul file $SOULS_DIR/${name}.md already exists but '$name' is not a fleet profile — refusing (collision)"
    exit 2
  fi

  if (( dry )); then
    hdr "fleet add $name --dry-run (NO writes)"
    note "planned soul: $SOULS_DIR/${name}.md"
    printf '%s\n' '    ---8<--- SOUL ---8<---'
    render_minimal_soul "$role" | sed 's/^/    /'
    printf '%s\n' '    ---8<--- /SOUL ---8<---'
    note "planned models.yml assignments.$name: $model"
    note "planned models.yml kinds.$name:"
    printf '    { kind: hermes-profile, profile: %s, key_env: HERMES_LITELLM_KEY, desc: %s }\n' "$name" "$role"
    note "re-render plan: rm phase_${STAMP}.done -> vz-ai-stack.sh install ${STAMP} -> vz-ai-stack.sh model sync"
    ok "dry-run complete — nothing written"
    exit 0
  fi

  # Serialize the models.yml mutation against model add/assign.
  lock_acquire

  # SOUL FIRST (a failed models.yml write then leaves only an orphan soul that
  # 04f ignores; a soul-write failure never touches models.yml).
  write_soul "$name" "$role" || { err "fleet add: failed to write soul for $name"; exit 1; }

  # ONE atomic yq write: assignments + kinds (+desc) together (no half-state).
  if ! AG="$name" M="$model" R="$role" yq -i \
      '.assignments[strenv(AG)]=strenv(M) | .kinds[strenv(AG)]={"kind":"hermes-profile","profile":strenv(AG),"key_env":"HERMES_LITELLM_KEY","desc":strenv(R)}' \
      "$MODELS_YML"; then
    err "fleet add: yq write to models.yml failed"
    exit 1
  fi
  ok "declared fleet profile '$name' -> $model"

  # Release BEFORE shelling out (the sub-invocations re-acquire their own lock).
  _unlock

  if (( nosync )); then
    note "--no-sync: sandbox-side render deferred. Apply with: vz-ai-stack.sh install ${STAMP} && vz-ai-stack.sh model sync"
    exit 0
  fi

  # FORCE the 04f re-render — do NOT rely on precheck (its stamp would
  # short-circuit and the new profile would never be created in-sandbox).
  stamp_clear "$STAMP"
  log "re-rendering Hermes fleet (install ${STAMP})..."
  bash "$AI_STACK/vz-ai-stack.sh" install "$STAMP" </dev/null || warn "install ${STAMP} returned non-zero (see above)"
  log "syncing model bindings (vz-ai-stack.sh model sync)..."
  bash "$AI_STACK/vz-ai-stack.sh" model sync </dev/null || warn "model sync returned non-zero (see above)"

  if ! hermes_sandbox_ready; then
    note "sandbox '$SANDBOX' not Ready — soul + models.yml are staged; intent recorded. Re-run 'vz-ai-stack.sh install ${STAMP}' once the sandbox is up."
  fi
  ok "fleet add '$name' complete"
}

# ===========================================================================
# fleet remove — shrink the phase-04f fleet
# ===========================================================================
cmd_fleet_remove() {
  local name="" dry=0 keep_soul=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run)   dry=1 ;;
      --keep-soul) keep_soul=1 ;;
      -*) err "fleet remove: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$name" ]]; then name="$a"; else err "fleet remove: unexpected arg '$a'"; exit 2; fi ;;
    esac
  done

  [[ -n "$name" ]] || { err "usage: vz-ai-stack.sh fleet remove <name> [--dry-run] [--keep-soul]"; exit 2; }
  valid_name "$name" || exit 2
  if is_reserved "$name" remove; then exit 2; fi

  validate_models

  if ! is_fleet_profile "$name"; then
    err "unknown fleet profile '$name'. Current fleet profiles:"
    fleet_profiles | sed 's/^/    /' >&2
    exit 2
  fi

  if (( dry )); then
    hdr "fleet remove $name --dry-run (NO writes)"
    note "would delete soul: $SOULS_DIR/${name}.md $([[ $keep_soul == 1 ]] && echo '(KEPT: --keep-soul)')"
    note "would remove models.yml: assignments.$name + kinds.$name"
    note "would best-effort remove in-sandbox profile dir ~/.hermes/profiles/$name (WARN-non-fatal)"
    note "then: vz-ai-stack.sh model sync"
    ok "dry-run complete — nothing written"
    exit 0
  fi

  lock_acquire

  # ONE atomic yq del (del on a missing key is a no-op -> double-remove safe).
  if ! AG="$name" yq -i 'del(.assignments[strenv(AG)]) | del(.kinds[strenv(AG)])' "$MODELS_YML"; then
    err "fleet remove: yq del from models.yml failed"
    exit 1
  fi
  ok "removed models.yml entries for '$name'"

  if (( ! keep_soul )); then
    rm -f "$SOULS_DIR/${name}.md"
    ok "removed soul $SOULS_DIR/${name}.md"
  fi

  _unlock

  # Best-effort in-sandbox cleanup (WARN-non-fatal). The hermes profile DELETE
  # verb is unverified for v0.15.2 — the profile DIR is the profile state, so we
  # rm the dir. A leftover sandbox profile is harmless (not in models.yml -> not
  # rendered, not counted by doctor 40).
  if hermes_sandbox_ready; then
    local osh; osh="$(osh_bin)"
    "$osh" sandbox exec -n "$SANDBOX" --no-tty -- \
      bash -c "rm -rf \"\$HOME/.hermes/profiles/$name\" /sandbox/fleet-souls/${name}.md" \
      </dev/null >/dev/null 2>&1 || warn "in-sandbox cleanup of '$name' returned non-zero (non-fatal; orphan is harmless)"
  else
    note "sandbox '$SANDBOX' not Ready — skipped in-sandbox profile cleanup (orphan is harmless)"
  fi

  log "syncing model bindings (vz-ai-stack.sh model sync)..."
  bash "$AI_STACK/vz-ai-stack.sh" model sync </dev/null || warn "model sync returned non-zero (see above)"
  ok "fleet remove '$name' complete"
}

# ===========================================================================
# fleet list — READ-ONLY: profiles in models.yml + in-sandbox presence
# ===========================================================================
cmd_fleet_list() {
  local json=0 a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      -*) err "fleet list: unknown flag '$a'"; exit 2 ;;
    esac
  done

  validate_models

  # Capture the in-sandbox profile set ONCE (advisory).
  local osh ready=0 plist=""
  osh="$(osh_bin)"
  if hermes_sandbox_ready; then
    ready=1
    plist="$("$osh" sandbox exec -n "$SANDBOX" --no-tty -- hermes profile list </dev/null 2>/dev/null \
             | sed $'s/\x1b\\[[0-9;]*m//g' | awk 'NR>1 && $1!="" {print $1}' || true)"
  fi

  if (( json )); then
    local entries="[]" n model role present
    entries="$( while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        model="$(my_q ".assignments.\"$n\"")"
        role="$(profile_desc "$n")"; [[ "$role" == "null" ]] && role=""
        if (( ready )); then present="$(grep -qxF "$n" <<<"$plist" && echo true || echo false)"; else present=null; fi
        N="$n" M="$model" R="$role" P="$present" python3 -c 'import json,os; print(json.dumps({"name":os.environ["N"],"model":os.environ["M"],"role":os.environ["R"],"present":(None if os.environ["P"]=="null" else os.environ["P"]=="true")}))'
      done < <(fleet_profiles) | python3 -c 'import sys,json; print(json.dumps({"profiles":[json.loads(l) for l in sys.stdin if l.strip()]}, indent=2))' )"
    printf '%s\n' "$entries"
    return 0
  fi

  hdr "Hermes fleet profiles ($SANDBOX)"
  printf '  %-26s %-18s %-8s %s\n' AGENT MODEL PRESENT ROLE
  local n model role present
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    model="$(my_q ".assignments.\"$n\"")"
    role="$(profile_desc "$n")"; [[ "$role" == "null" ]] && role=""
    [[ -z "$role" ]] && role="-"
    if (( ready )); then
      present="$(grep -qxF "$n" <<<"$plist" && echo yes || echo no)"
    else
      present="?"
    fi
    printf '  %-26s %-18s %-8s %s\n' "$n" "$model" "$present" "$role"
  done < <(fleet_profiles)
  if (( ! ready )); then
    note "sandbox '$SANDBOX' not Ready — PRESENT column is advisory ('?')"
  fi
  return 0
}

# ===========================================================================
# fleet new — a SEPARATE, isolated Hermes fleet sandbox <name>-v1
# ===========================================================================

# resolve_profile_model <profile> — per-profile model from models.yml,
# availability-gated. Copied from 04f (same env contract: HERMES_MODEL,
# HERMES_KEY, MODELS_YML, LITELLM_CFG). Falls back to HERMES_MODEL when
# models.yml absent OR the assigned model is an unservable lmstudio slug.
_lms_up() { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null; }
_meridian_up() { curl -sf --max-time 3 "http://127.0.0.1:${MERIDIAN_PORT:-3456}/v1/models" -H "Authorization: Bearer x" >/dev/null 2>&1; }
resolve_profile_model() {
  local profile="$1" declared rt
  [[ -f "$MODELS_YML" ]] && command -v yq >/dev/null 2>&1 || { echo "$HERMES_MODEL"; return; }
  declared="$(yq -r ".assignments.\"$profile\" // \"\"" "$MODELS_YML" 2>/dev/null)"
  [[ -z "$declared" || "$declared" == "null" ]] && { echo "$HERMES_MODEL"; return; }
  rt="$(yq -r ".models.\"$declared\".runtime" "$MODELS_YML" 2>/dev/null)"
  case "$rt" in
    lmstudio)
      # Capture-then-grep on the streaming /v1/models body (pipefail-EPIPE class;
      # this file's own header rule — the curl pipe predated it).
      local _mresp=""
      if _lms_up && grep -qF "model_name: ${declared}" "$LITELLM_CFG" 2>/dev/null; then
        _mresp="$(litellm_scoped_curl "$HERMES_KEY" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null)" || _mresp=""
        if grep -qF "\"$declared\"" <<<"$_mresp"; then
          echo "$declared"; return
        fi
      fi ;;
    meridian)
      # Claude subscription: gate on the Meridian daemon (:3456) being up + registered;
      # else fall back to the local default. Mirrors 04f + lib/models.sh.
      if _meridian_up && grep -qF "model_name: ${declared}" "$LITELLM_CFG" 2>/dev/null; then
        echo "$declared"; return
      fi ;;
    *)
      echo "$declared"; return ;;
  esac
  echo "$HERMES_MODEL"
}

# configure_fleet_profile <sandbox> <pflag> <model> — route a profile through
# LiteLLM. provider/base_url model-independent; api_key piped via STDIN only.
# (Mirrors 04f::configure_hermes_profile, parameterized on sandbox.)
configure_fleet_profile() {
  local sb="$1" pflag="$2" model="$3" osh; osh="$(osh_bin)"
  "$osh" sandbox exec -n "$sb" --no-tty -- bash -c \
    "hermes $pflag config set model.default $model >/dev/null; hermes $pflag config set model.provider custom:litellm >/dev/null; hermes $pflag config set providers.litellm.base_url $LITELLM_SANDBOX_URL >/dev/null; hermes $pflag config set providers.litellm.model $model >/dev/null" \
    </dev/null 2>&1 | tail -2 || warn "hermes ${pflag:-(default)} non-secret config returned non-zero"
  printf '%s' "$HERMES_KEY" | "$osh" sandbox exec -n "$sb" --no-tty -- bash -c \
    "read -r K; hermes $pflag config set providers.litellm.api_key \"\$K\" >/dev/null" \
    >/dev/null 2>&1 || warn "hermes ${pflag:-(default)} api_key config returned non-zero"
}

# write_fleet_policy <out_path> <sandbox_name> — minimal deny-by-default policy:
# litellm_proxy + package_registries only (tighter than hermes-fleet-v1's full
# set). Unquoted heredoc so $sandbox_name interpolates in the comment.
write_fleet_policy() {
  local out="$1" sb="$2"
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<EOF
# SPDX-FileCopyrightText: ai-stack installer (fleet new)
# OpenShell sandbox policy for $sb (minimal: litellm_proxy + package_registries).
version: 1

filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /etc
    - /app
    - /var/log
    - /proc
    - /dev/urandom
  read_write:
    - /sandbox
    - /tmp
    - /dev/null

landlock:
  compatibility: best_effort

process:
  run_as_user: sandbox
  run_as_group: sandbox

network_policies:
  litellm_proxy:
    name: litellm-proxy
    endpoints:
      - host: host.docker.internal
        port: 4000
    binaries:
      - { path: "/**" }

  package_registries:
    name: package-registries
    endpoints:
      - { host: pypi.org, port: 443 }
      - { host: files.pythonhosted.org, port: 443 }
      - { host: registry.npmjs.org, port: 443 }
      - { host: api.github.com, port: 443 }
      - { host: github.com, port: 443 }
      - { host: raw.githubusercontent.com, port: 443 }
      - { host: codeload.github.com, port: 443 }
    binaries:
      - { path: "/**" }
EOF
  return 0
}

# fleet_validate_name <name> — fleetname validator (hyphen convention, like a
# sandbox/DNS label). Reserved set refuses phase-managed sandboxes.
fleet_validate_name() {
  local name="$1"
  [[ -n "$name" ]] || { err "fleet new/destroy: <fleetname> is required"; return 2; }
  case "$name" in
    hermes-fleet|hermes-fleet-v1|pi|pi-v1)
      err "'$name' is reserved (managed by phases 04/04f/15) — use 'vz-ai-stack.sh install 04' / 'vz-ai-stack.sh reset'"; return 2 ;;
  esac
  if [[ "$name" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then return 0; fi
  err "invalid fleet name '$name' — must match ^[a-z][a-z0-9-]{0,30}\$"
  return 2
}

cmd_fleet_new() {
  local name="" profiles_csv="" mint=0 allow_mlx=0 dry=0 expect_profiles=0 a
  for a in "$@"; do
    if (( expect_profiles )); then profiles_csv="$a"; expect_profiles=0; continue; fi
    case "$a" in
      --profiles)  expect_profiles=1 ;;
      --mint-key)  mint=1 ;;
      --allow-mlx) allow_mlx=1 ;;
      --dry-run)   dry=1 ;;
      -*) err "fleet new: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$name" ]]; then name="$a"; else err "fleet new: unexpected arg '$a'"; exit 2; fi ;;
    esac
  done

  fleet_validate_name "$name" || exit 2
  local sb="${name}-v1"
  local osh; osh="$(osh_bin)"

  # Resolve the nemotron-3-nano:4b default (servable on a fresh box). Model is hard-pinned to
  # local unless --allow-mlx un-pins it to the availability-gated assignment.
  local HERMES_MODEL="local"
  if [[ -f "$MODELS_YML" ]] && command -v yq >/dev/null 2>&1; then
    local _hd; _hd="$(my_q '.default')"
    [[ -n "$_hd" && "$_hd" != "null" ]] && HERMES_MODEL="$_hd"
  fi
  export HERMES_MODEL MODELS_YML LITELLM_CFG LITELLM_SANDBOX_URL

  # Roster: default + valid --profiles entries (invalid ones warned + skipped).
  local PROFILES=(default) e
  if [[ -n "$profiles_csv" ]]; then
    local IFS_SAVE="$IFS"; IFS=','
    for e in $profiles_csv; do
      IFS="$IFS_SAVE"
      [[ -z "$e" ]] && continue
      if [[ "$e" == "default" ]]; then continue; fi
      if [[ "$e" =~ ^[a-z][a-z0-9_]{0,40}$ ]]; then PROFILES+=("$e"); else warn "skipping invalid profile '$e'"; fi
    done
    IFS="$IFS_SAVE"
  fi

  local POLICY="$POLICIES_DIR/${sb}.yaml"

  if (( dry )); then
    hdr "fleet new $name --dry-run (NO writes / NO sandbox)"
    note "new sandbox:   $sb (--from base)"
    note "policy:        $POLICY (minimal: litellm_proxy + package_registries)"
    note "profiles:      ${PROFILES[*]}"
    note "model bind:    $([[ $allow_mlx == 1 ]] && echo 'availability-gated (--allow-mlx un-pins nemotron-3-nano:4b)' || echo "$HERMES_MODEL (hard pin)")"
    if (( mint )); then
      local fkey; fkey="FLEET_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')_LITELLM_KEY"
      note "key:           mint $fkey scoped to the LiteLLM superset (value masked)"
    else
      note "key:           reuse HERMES_LITELLM_KEY (shared; --mint-key for a durable isolated fleet)"
    fi
    note "routing:       each profile -> provider=custom:litellm via $LITELLM_SANDBOX_URL"
    note "doctor:        checks 30/33 only cover hermes-fleet-v1 — $sb is NOT health-checked"
    ok "dry-run complete — nothing created"
    exit 0
  fi

  # Gateway must be up (no install/start dance).
  [[ -n "$osh" ]] && port_listening "$GATEWAY_PORT" || {
    err "OpenShell gateway not up on :$GATEWAY_PORT — run: vz-ai-stack.sh install 04"
    exit 1
  }

  # POLICY first (cheap, reversible).
  write_fleet_policy "$POLICY" "$sb"
  ok "wrote policy: $POLICY"

  # KEY: reuse HERMES_LITELLM_KEY, or mint a per-fleet scoped key.
  local HERMES_KEY; HERMES_KEY="$(get_env HERMES_LITELLM_KEY '')"
  local fkey=""
  if (( mint )) || [[ -z "$HERMES_KEY" ]]; then
    fkey="FLEET_$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')_LITELLM_KEY"
    # models.sh's remint_key handles the mint (scoped to the superset). ANY
    # non-zero (LiteLLM down / no master key / preflight) -> warn + continue.
    if bash "$AI_STACK/installer/lib/models.sh" superset >/dev/null 2>&1; then :; fi
    if ! ( set --; source "$AI_STACK/installer/lib/models.sh" >/dev/null 2>&1; remint_key "$fkey" "fleet-${name}" "fleet" ) </dev/null; then
      warn "fleet created but unrouted (LiteLLM mint failed: down / no LITELLM_MASTER_KEY / superset preflight). Re-run: vz-ai-stack.sh fleet new ${name} --mint-key once LiteLLM is up"
    fi
    HERMES_KEY="$(get_env "$fkey" '')"
  fi
  export HERMES_KEY

  # CREATE the sandbox (hang-resilient).
  if ! openshell_sandbox_ensure "$osh" "$sb" base; then
    warn "sandbox $sb did not reach Ready — reversible: re-run 'vz-ai-stack.sh fleet new $name'"
    exit 1
  fi

  # APPLY the policy.
  "$osh" policy set "$sb" --policy "$POLICY" --wait --timeout 60 </dev/null >/dev/null 2>&1 \
    || warn "policy set returned non-zero (sandbox up; re-apply manually with: $osh policy set $sb --policy $POLICY)"

  # MODEL bind: hard local unless --allow-mlx un-pins to the gated assignment.
  local MODEL="$HERMES_MODEL"
  if (( allow_mlx )); then MODEL="$(resolve_profile_model default)"; fi

  # PIP-install hermes-agent (mirror 04f's two-exec form + hard-abort pointer).
  if ! "$osh" sandbox exec -n "$sb" --no-tty -- bash -c 'command -v hermes >/dev/null && hermes --version' </dev/null >/dev/null 2>&1; then
    warn "Hermes not detected inside $sb. Installing from PyPI..."
    "$osh" sandbox exec -n "$sb" --no-tty -- bash -c 'python3 -m pip install --upgrade hermes-agent' </dev/null 2>&1 | tail -10 || true
  fi
  if ! "$osh" sandbox exec -n "$sb" --no-tty -- bash -c 'command -v hermes' </dev/null >/dev/null 2>&1; then
    err "hermes not on PATH after install (PyPI 403 through proxy?). Pre-stage hermes-agent like Phase 15."
    exit 1
  fi

  # CREATE + ROUTE each profile.
  local p pflag
  for p in "${PROFILES[@]}"; do
    if [[ "$p" != "default" ]]; then
      "$osh" sandbox exec -n "$sb" --no-tty -- \
        bash -c "hermes profile create $p --description 'fleet:$name' --no-alias" </dev/null 2>&1 | tail -2 \
        || warn "hermes profile create $p returned non-zero (non-fatal; treated as update)"
    fi
    pflag=""; [[ "$p" != "default" ]] && pflag="--profile $p"
    configure_fleet_profile "$sb" "$pflag" "$MODEL"
  done

  # VERIFY (non-fatal, no key echo).
  local V
  V="$("$osh" sandbox exec -n "$sb" --no-tty -- bash -c \
        'f="$HOME/.hermes/profiles/default/config.yaml"; [[ -f "$f" ]] || f="$HOME/.hermes/config.yaml"; grep -q "provider: custom:litellm" "$f" && echo WIRED || echo MISSING' \
        </dev/null 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]' || true)"
  if [[ "$V" == "WIRED" ]]; then ok "fleet '$name' default profile routes to LiteLLM (provider=custom:litellm)"; else warn "fleet '$name' routing not detected (got '${V:-none}')"; fi

  ok "fleet '$name' ready: sandbox $sb, ${#PROFILES[@]} profile(s) -> $MODEL"
  note "connect: $osh sandbox connect $sb"
  note "NOTE: vz-ai-stack.sh doctor checks 30/33 only cover hermes-fleet-v1 — $sb is NOT health-checked."
  if [[ -n "$fkey" ]]; then
    note "minted $fkey (masked) scoped to the LiteLLM superset."
  else
    note "shares HERMES_LITELLM_KEY — rotating it affects this fleet too; use --mint-key for an isolated, durable fleet."
  fi
}

# ===========================================================================
# fleet destroy — tear down a fleet created by `fleet new`
# ===========================================================================
cmd_fleet_destroy() {
  local name="" dry=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -*) err "fleet destroy: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$name" ]]; then name="$a"; else err "fleet destroy: unexpected arg '$a'"; exit 2; fi ;;
    esac
  done

  fleet_validate_name "$name" || exit 2
  local sb="${name}-v1" osh; osh="$(osh_bin)"
  local POLICY="$POLICIES_DIR/${sb}.yaml"

  if (( dry )); then
    hdr "fleet destroy $name --dry-run (NO changes)"
    note "would delete sandbox: $sb"
    note "would remove policy:  $POLICY"
    note "FLEET_<NAME>_LITELLM_KEY (if minted) is left in .env; LiteLLM key NOT revoked (manual /key/delete)"
    ok "dry-run complete — nothing changed"
    exit 0
  fi

  [[ -n "$osh" ]] || { err "openshell binary not found"; exit 1; }
  # H3 — CHECKPOINT before destroy (user fleet sandboxes hold real agent state and are
  # NOT covered by doctor checks 30/33). Fail-CLOSED: rc 2 = commit/verify failed → ABORT
  # unless AI_STACK_FORCE_WIPE=1. Restore later via bin/openshell-state-restore.sh.
  local _ck=0
  bash "$AI_STACK/bin/openshell-checkpoint.sh" "$sb" destroy >/dev/null || _ck=$?
  if (( _ck == 2 )) && [[ "${AI_STACK_FORCE_WIPE:-0}" != "1" ]]; then
    err "ABORTING destroy of '$sb': pre-delete checkpoint FAILED (would lose agent state). Set AI_STACK_FORCE_WIPE=1 to force."
    exit 1
  fi
  openshell_sandbox_delete "$osh" "$sb"
  ok "deleted sandbox $sb (checkpointed; best-effort delete)"
  rm -f "$POLICY"
  ok "removed policy $POLICY"
  note "FLEET_<NAME>_LITELLM_KEY (if minted) left in .env; LiteLLM key NOT revoked (manual /key/delete)."
  ok "fleet destroy '$name' complete"
}

# ===========================================================================
# run — drive ONE Hermes profile from the host (vz-ai-stack.sh hermes <role>)
# ===========================================================================
# _hermes_role <short|full> — map a short alias (techlead, backend, …) to its
# hermes_<role> profile; validate against CORE7 (custom full hermes_* allowed).
_hermes_role() {
  local r="$1" p
  case "$r" in
    hermes_*)                                      p="$r" ;;
    manager|mgr)                                   p="hermes_manager" ;;
    techlead|tech|lead|architect)                  p="hermes_techlead" ;;
    frontend|frontend_engineer|fe)                 p="hermes_frontend_engineer" ;;
    backend|backend_engineer|be)                   p="hermes_backend_engineer" ;;
    ml|ml_engineer|mle)                            p="hermes_ml_engineer" ;;
    qa|qa_test_engineer|test|tester)               p="hermes_qa_test_engineer" ;;
    review|reviewer|reviewing|reviewing_engineer)  p="hermes_reviewing_engineer" ;;
    sre|sre_engineer)                              p="hermes_sre_engineer" ;;
    incident|incident_manager|im)                  p="hermes_incident_manager" ;;
    *)                                             p="hermes_$r" ;;
  esac
  local c ok=0
  for c in "${CORE7[@]}"; do [[ "$c" == "$p" ]] && ok=1; done
  [[ "$r" == hermes_* ]] && ok=1   # allow a custom full profile name (fleet add)
  (( ok )) || { err "unknown role '$r' — valid: manager techlead frontend backend ml qa reviewing sre incident (or a full hermes_<name>)"; return 2; }
  printf '%s' "$p"
}

# cmd_run <role> ["prompt" | -m <model>] — interactive TUI when no prompt is
# given; one-shot (--yolo -z) when a prompt is. Routes through hermes-fleet-v1.
cmd_run() {
  local role="${1:-}"
  if [[ -z "$role" || "$role" == "-h" || "$role" == "--help" ]]; then
    cat <<'EOF'
vz-ai-stack.sh hermes <role> ["prompt"] [-m <model>]
  Run one Hermes agent in the hermes-fleet-v1 sandbox.
    (no prompt)  -> interactive TUI   (Ctrl-D / 'exit' to leave)
    "prompt"     -> one-shot          (--yolo -z)
  roles: manager techlead frontend backend ml qa reviewing sre incident  (or a full hermes_<name>)
  examples:
    vz-ai-stack.sh hermes techlead
    vz-ai-stack.sh hermes backend "Sketch a POST /tokens contract (JWT in an httpOnly cookie). Contract only."
    vz-ai-stack.sh hermes manager -m claude-opus-sub-max "Frame + route a /healthz endpoint to a reviewed diff."
EOF
    return 0
  fi
  shift
  local profile; profile="$(_hermes_role "$role")" || return 2
  local model="" prompt=""
  while (( $# )); do
    case "$1" in
      -m|--model) model="${2:-}"; [[ -n "$model" && "$model" != -* ]] || { err "-m/--model needs a model name"; return 2; }; shift 2 ;;
      *)          prompt="${prompt:+$prompt }$1"; shift ;;
    esac
  done
  local osh; osh="$(osh_bin)"; [[ -n "$osh" ]] || { err "openshell not on PATH — run: vz-ai-stack.sh install 04"; return 1; }
  if ! hermes_sandbox_ready; then
    err "sandbox $SANDBOX is not Ready — the OpenShell gateway/relay or Docker is down."
    note "1) Docker first:  docker ps   (if it HANGS, OrbStack is thrashing — free RAM; it recovers when pressure eases)"
    note "2) Gateway:       brew services restart openshell   (wait ~10s, then: openshell sandbox list)"
    note "3) Still Error:   vz-ai-stack.sh install 04 04f 15"
    return 1
  fi
  local margs=(); [[ -n "$model" ]] && margs=(-m "$model")
  if [[ -n "$prompt" ]]; then
    note "▶ hermes $profile — one-shot${model:+ (model=$model)}"
    "$osh" sandbox exec -n "$SANDBOX" --no-tty -- hermes --profile "$profile" "${margs[@]}" --yolo -z "$prompt"
  else
    note "▶ hermes $profile — interactive (Ctrl-D / 'exit' to leave)${model:+ [model=$model]}"
    "$osh" sandbox exec -n "$SANDBOX" --tty -- hermes --profile "$profile" "${margs[@]}"
  fi
}

# ===========================================================================
# usage + dispatch
# ===========================================================================
fleet_usage() {
  cat <<'EOF'
vz-ai-stack.sh fleet — Hermes fleet manager
  Grow/shrink the phase-04f fleet (sandbox hermes-fleet-v1):
    fleet list [--json]                                show profiles (models.yml + sandbox presence)
    fleet add <name> --role "<desc>" [--model <m>] [--dry-run] [--no-sync]
    fleet remove <name> [--dry-run] [--keep-soul]
  Stand up / tear down a SEPARATE isolated fleet (sandbox <name>-v1):
    fleet new <fleetname> [--profiles a,b,c] [--mint-key] [--allow-mlx] [--dry-run]
    fleet destroy <fleetname> [--dry-run]

  NB: `vz-ai-stack.sh install fleet|hermes` runs the PHASE (04f re-render).
      `vz-ai-stack.sh fleet <add|remove|list|new|destroy>` is the FLEET MANAGER (this).
EOF
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    run)               cmd_run "$@" ;;
    list)              cmd_fleet_list "$@" ;;
    add)               cmd_fleet_add "$@" ;;
    remove)            cmd_fleet_remove "$@" ;;
    new)               cmd_fleet_new "$@" ;;
    destroy)           cmd_fleet_destroy "$@" ;;
    ""|-h|--help|help) fleet_usage ;;
    *) err "fleet: unknown subcommand '$sub' (want run|list|add|remove|new|destroy)"; exit 2 ;;
  esac
}

main "$@"
