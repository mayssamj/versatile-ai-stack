#!/usr/bin/env bash
# stop-chatdev.sh — stop BOTH ChatDev containers (Phase 35).
# Symmetric counterpart to start-chatdev.sh; backs the `Stop:` line cmd_start advertises.
#
# WHY THIS EXISTS: ChatDev runs TWO docker-run containers — `chatdev` (Vite frontend) and
# `chatdev-backend` (FastAPI). Only the FRONTEND's name == the svc key `chatdev`, so the
# generic cmd_stop fallback (`docker stop chatdev`) stops the frontend but ORPHANS
# chatdev-backend (it keeps running + holding RAM). Like stop-aitown.sh, we ship a dedicated
# stop script that delegates to start-chatdev.sh's `stop` (which does `docker stop` on BOTH),
# so there is ONE teardown path and `vz-ai-stack.sh stop chatdev` actually stops everything.
#
# Non-destructive: `docker stop` (NOT rm) — both containers + the image + the cloned repo are
# PRESERVED; `vz-ai-stack.sh start chatdev` brings them back. Full teardown:
# `bash bin/start-chatdev.sh uninstall`. Idempotent: harmless on an already-stopped/absent stack.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

# Installed sentinel: the install-written Dockerfile (mirrors stop-aitown.sh's -f docker-compose.yml;
# present once the build descriptor exists, i.e. far enough that the containers could be running).
[[ -f "$AI_STACK/chatdev/Dockerfile" ]] || { ok "chatdev not installed; nothing to stop."; exit 0; }

exec bash "$AI_STACK/bin/start-chatdev.sh" stop
