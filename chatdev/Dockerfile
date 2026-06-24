# ai-stack/chatdev:local — one derived image for ChatDev 2.0 "DevAll", run as
# TWO containers (backend uvicorn :6400 + frontend Vite :5173) by bin/start-chatdev.sh.
#
# Build context = $AI_STACK/chatdev (so `repo/` is COPY-able). The source tree is
# ALSO bind-mounted at runtime (-v repo:/app) so edits + the .env are live; the COPY
# here is what makes the image self-contained for `uv sync` / `npm install` at build
# time (the slow steps run ONCE, baked into a layer, not on every container start).
#
# VERIFIED (research, 2026-06-23): ChatDev 2.0 hard-pins requires-python>=3.12,<3.13
# (NOT 3.11); `uv sync` installs clean on arm64 in ~6s (prebuilt wheels, zero build
# blockers). Frontend needs Node 18+; the deps install with `npm install`.
FROM python:3.12-slim

# uv (fast resolver/installer) + Node 20 (>=18) + build basics + curl (healthchecks).
# NodeSource for a current Node on the slim base.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git build-essential \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

WORKDIR /app
# Copy the cloned ChatDev 2.0 source (repo/ under the build context).
COPY repo/ /app/

# Python deps via uv into the SYSTEM interpreter (NOT a /app/.venv). At runtime
# start-chatdev.sh bind-mounts the host repo over /app, which would MASK any
# /app/.venv — installing --system puts the deps under /usr/local where the mount
# does not reach, so `uvicorn` resolves regardless of the bind mount. ChatDev 2.0
# ships pyproject.toml (+ uv.lock); fall back to requirements.txt if that's the shape.
RUN if [ -f /app/pyproject.toml ]; then \
        uv pip install --system . ; \
    elif [ -f /app/requirements.txt ]; then \
        uv pip install --system -r /app/requirements.txt ; \
    fi \
    && uv pip install --system uvicorn fastapi

# Frontend deps: node_modules CANNOT be baked under /app/frontend because the runtime
# bind mount (-v repo:/app) masks it. The PHASE (35) instead runs `npm install` on the
# HOST repo (chatdev/repo/frontend, host Node 22) so frontend/node_modules exists in
# the bind-mounted tree and the Vite container sees it. This image only guarantees the
# node RUNTIME is present (installed above) — not the deps.

# Backend default port. The frontend is started with its own CMD by start-chatdev.sh.
EXPOSE 6400 5173
# Default CMD = the backend (start-chatdev.sh overrides per container).
CMD ["uvicorn", "server_main:app", "--host", "0.0.0.0", "--port", "6400"]
