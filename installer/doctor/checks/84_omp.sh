# omp / oh-my-pi (Phase 42): host coding agent (Pi hard fork) over LiteLLM. OPT-IN — skips
# clean when Phase 42 hasn't run. PASS requires: the binary runs + bin/omp wrapper + the
# STACK profile configs present WITH the hardening posture (approvalMode not omp's shipped
# `yolo`; disabledProviders keeps direct-local out — single-hub; checkUpdate/autoqa off) +
# a scoped key that actually lists models. Wiring/presence ONLY — no inference, no local
# model load (never-load-local + doctor-no-coldstart rules; the real path is `test 42`).
#
# Numbered 84 (next free after 83_pipefail_grep_epipe_guard). doctor keys checks by NAME and
# the count auto-derives from the file set, so adding this file ticks the count by one.
CHECKS+=(omp)
CHECK_TITLE[omp]="omp (oh-my-pi) binary + profile hardening + scoped LiteLLM key (Phase 42)"

omp_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_42*.done" >/dev/null 2>&1; then
    echo "omp not installed in this stack — Phase 42 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local bin="$AI_STACK/omp/omp-darwin-arm64"
  [[ -x "$bin" ]] || { echo "omp binary missing ($bin) — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  "$bin" --version >/dev/null 2>&1 || { echo "omp binary present but --version fails — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  [[ -x "$AI_STACK/bin/omp" ]] || { echo "bin/omp wrapper missing — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }

  # Hardening posture — the point of the stack profile. A drifted/hand-edited profile that
  # re-enables yolo, direct-local providers, or the npm phone-home is a RED, not a shrug.
  local prof="$HOME/.omp/profiles/ai-stack/agent"
  [[ -f "$prof/models.yml" && -f "$prof/config.yml" ]] \
    || { echo "stack omp profile configs missing ($prof) — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  grep -q 'baseUrl: http://127.0.0.1:4000/v1' "$prof/models.yml" \
    || { echo "profile models.yml no longer points at LiteLLM :4000 — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  grep -q 'approvalMode: write' "$prof/config.yml" \
    || { echo "profile approvalMode drifted from 'write' (omp ships yolo = auto-approve exec) — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  grep -q '^    bash: prompt' "$prof/config.yml" \
    || { echo "profile tools.approval.bash policy lost 'prompt' (the backstop that keeps bash prompting even under a project-level yolo flip) — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  grep -q '^  - ollama' "$prof/config.yml" \
    || { echo "profile disabledProviders lost 'ollama' — direct-local bypasses the LiteLLM hub — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  grep -q 'checkUpdate: false' "$prof/config.yml" \
    || { echo "profile startup.checkUpdate drifted from 'false' (npm phone-home) — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }

  local key; key="$(get_env OMP_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "OMP_LITELLM_KEY missing from .env — re-run 'mayssam-ai-stack.sh install 42'"; return 1; }
  local models
  models="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'mayssam-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "OMP_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'mayssam-ai-stack.sh install 42'"
    return 1
  fi
  # Allow-list drift assertion (shared helper): omp has no models.yml assignment (registry-
  # only consumer), so this resolves the fallback 'local' — which the omp allow-list carries.
  _doctor_assert_key_allowlist "$key" OMP_LITELLM_KEY omp "the model omp calls" 42 || return 1
  echo "omp ready (binary + wrapper + hardened profile + scoped key lists models). Boundary: project-local .omp/ in a repo you open can relax approvals — trusted repos only. Prove the real path: mayssam-ai-stack.sh test 42"
  return 0
}

omp_fix() {
  echo "mayssam-ai-stack.sh install 42   # re-fetch digest-verified binary + re-render hardened profile + re-mint scoped key"
}
