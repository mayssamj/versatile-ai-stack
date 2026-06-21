#!/usr/bin/env bash
# 05a — LiteLLM key-store (honcho Postgres) reachable, with SAFE AUTO-HEAL.
#
# WHY (incident 2026-06-20): LiteLLM's virtual-key store is Postgres — the
# honcho-database container (honcho/docker-compose.yml), reached at
# host.docker.internal:5432/litellm. When it's down, LiteLLM returns HTTP 503
# `no_db_connection` for the MASTER key AND every virtual key. The per-phase key
# checks (24/26 pi, 29 ace, 30 hermes, 31 rlm, 44 mempalace) then MISREAD that as
# "key rejected — re-mint" — sending you in circles, because you can't mint a key
# against a down DB. This check runs BEFORE those, detects the DB-down signature
# at its source, and AUTO-HEALS the database (idempotent `compose up -d database`)
# so the key checks pass naturally.
#
# RESILIENT by design: non-destructive (never rm/volume-wipe), worktree-guarded
# (never "recovers" into a git worktree — the incident's root cause), fail-open
# when honcho isn't installed, bounded waits, and a verified end-state.
#
# AUTOHEAL=1 ⇒ doctor applies the heal AUTOMATICALLY (no Y/n prompt): you asked
# for this class to self-resolve, and `compose up -d database` is safe+idempotent.

CHECKS+=(litellm_keystore)
CHECK_TITLE[litellm_keystore]="LiteLLM key-store (Postgres) reachable + self-heal"
AUTOHEAL[litellm_keystore]=1

# _keystore_pg_reachable — is Postgres listening on the host loopback :5432?
_keystore_pg_reachable() {
  (exec 3<>/dev/tcp/127.0.0.1/5432) 2>/dev/null && { exec 3>&- 3<&- 2>/dev/null; return 0; }
  return 1
}

# litellm_db_down — SHARED helper (used here AND by the per-phase key checks 29/30/
# 31/44): returns 0 iff the LiteLLM key-store is down. Two signals, in order:
#   1. If LiteLLM ANSWERS, it is authoritative — down iff it reports HTTP 503
#      `no_db_connection`.
#   2. If LiteLLM is UNREACHABLE (curl empty — container down OR, crucially, the
#      `litellm` /etc/hosts alias missing — the exact degraded state where this
#      runs), the curl signal is BLIND. Fall back to the host-loopback Postgres
#      probe, which needs no alias: PG not listening on 127.0.0.1:5432 ⇒ down.
# Without the fallback an absent alias gave a false "DB up", so checks 29/30/31/44
# misread a down key-store as "bad key → re-mint" — the very loop this prevents.
litellm_db_down() {
  local body
  body="$(curl -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  if [[ -n "$body" ]]; then
    grep -q 'no_db_connection' <<<"$body"   # LiteLLM answered → authoritative
    return
  fi
  ! _keystore_pg_reachable                   # LiteLLM unreachable → trust the loopback PG probe
}

litellm_keystore_diagnose() {
  # Fail-open: if honcho (the Postgres provider) isn't part of this stack, skip.
  [[ -f "$AI_STACK/honcho/docker-compose.yml" ]] || { echo "honcho not installed — no LiteLLM key-store here (skip)"; return 0; }
  if litellm_db_down; then
    echo "LiteLLM key-store DOWN — /v1/models returns 503 no_db_connection (Postgres unreachable)."
    echo "Effect: master + ALL virtual keys look 'rejected'. The fix is to heal the DB — do NOT re-mint keys."
    return 1
  fi
  if ! _keystore_pg_reachable; then
    echo "Postgres (honcho-database) not reachable on 127.0.0.1:5432 — the LiteLLM key-store is down."
    return 1
  fi
  return 0
}

litellm_keystore_fix() {
  # (1) worktree guard — never "recover" into a worktree (the 2026-06-20 root cause).
  worktree_guard_soft "litellm key-store recovery" || return 1
  # (2) fail-open if honcho isn't installed.
  [[ -f "$AI_STACK/honcho/docker-compose.yml" ]] || { warn "honcho/docker-compose.yml missing — cannot heal"; return 1; }
  # (3) NON-destructive heal: just (re)start the database service. Idempotent;
  #     preserves the data volume/bind — never rm, never wipe.
  log "Healing LiteLLM key-store: starting honcho-database (Postgres), idempotent…"
  if ! ( cd "$AI_STACK/honcho" && docker compose up -d database ) >/dev/null 2>&1; then
    err "docker compose up -d database failed — inspect: docker logs honcho-database-1"
    return 1
  fi
  # (4) bounded wait for Postgres to accept connections.
  local i
  for i in $(seq 1 30); do _keystore_pg_reachable && break; sleep 1; done
  if ! _keystore_pg_reachable; then
    err "Postgres still unreachable after 30s — inspect honcho-database-1."
    return 1
  fi
  # (5) verify LiteLLM can reach the DB again (401 auth-required or 200 ⇒ DB
  #     healthy; 503 ⇒ still down). LiteLLM reconnects on its own once PG is up.
  for i in $(seq 1 20); do
    local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://litellm:4000/v1/models 2>/dev/null || echo 000)"
    if [[ "$code" == "401" || "$code" == "200" ]]; then
      ok "LiteLLM key-store recovered (HTTP $code) — keys validate again."
      return 0
    fi
    sleep 1
  done
  warn "Postgres is up but LiteLLM still can't reach it — restart LiteLLM:"
  warn "    bash $AI_STACK/bin/start-litellm.sh --recreate"
  return 1
}
