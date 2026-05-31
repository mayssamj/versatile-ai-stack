# Operations

Daily commands and common recipes. For initial install, see [INSTALL.md](INSTALL.md).

---

## The `stack` command

After install, `~/ai-stack/bin/stack` is a thin wrapper around `install.sh`
subcommands. Add `~/ai-stack/bin` to your `$PATH` (the installer prints the
exact line to add):

```bash
echo 'export PATH="$HOME/ai-stack/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Then everywhere below, `stack <cmd>` is equivalent to `bash ~/ai-stack/install.sh <cmd>`.

---

## The 11 commands you'll actually use

```bash
stack                                   # interactive install/resume
stack verify                            # Phase 00·V — 6 runtime probes; no install
stack status                            # declared vs actual table
stack doctor                            # 32 health checks + auto-fix offers
stack doctor <filter>                   # only checks whose name contains <filter>
stack test <phase>                      # smoke test for one phase
stack adopt <svc>                       # take ownership of a foreign container
stack apply-restarts                    # drain the queued-restart list
stack logs <container> [-f]             # docker logs wrapper
stack gc                                # remove partial container orphans
stack reset --confirm soft|hard|nuke    # tiered destructive reset
```

`stack verify` is the cheapest health probe in the toolbox — it does not
install or restart anything; it just confirms the alias chain
(lo0 + /etc/hosts + Docker DNS + `--add-host=ollama:host-gateway` +
end-to-end routing) still works. Run it after any networking change
(VPN connect/disconnect, OrbStack restart) before assuming the stack
is healthy.

---

## Recipes

### Send a chat request through LiteLLM

```bash
KEY="$(grep ^LITELLM_MASTER_KEY= ~/ai-stack/.env | cut -d= -f2-)"

curl -s http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"hello"}]}' \
  | jq -r ".choices[0].message.content"
```

Mac and container both dial `http://litellm:4000` — the URL form is
identical on both sides (each HTTP service publishes on its native
container port; see [CHANGELOG.md 2026-05-28 entry](../CHANGELOG.md) for
why we don't use port 80 anymore).

Use any model from `~/ai-stack/services.yml` (or `curl /v1/models | jq`).
Verified models: `local`, `local-heavy`, `claude-sonnet`, `claude-opus`,
`openai-gpt-5.5`, `openrouter-claude-opus-4.7`, `google-gemini-3.1-pro`,
plus 16 more.

### Watch traces stream

```bash
docker exec litellm tail -f /traces/litellm.jsonl
```

Each line is one chat call: `ts`, `kind` (success/failure), `model`,
`messages`, `response`, `latency_ms`, `cost`.

### Open the Phoenix dashboard

```bash
open http://phoenix:6006
```

Log in as `admin@localhost` / (your password). Click the **ai-stack** project
(not `default` — that's the catch-all for untagged traces).

### Working with aliases

After install, services are reached by name on both the Mac and from within
containers. Concrete examples:

```bash
# Mac side — same URL form as container side
curl -sf http://litellm:4000/health
curl -sf http://phoenix:6006/healthz
curl -sf http://qdrant:6333/collections
open http://openwebui:8080

# Redis-protocol services use their native port form
redis-cli -h falkordb -p 6379 PING

# Resolve from the Mac to confirm /etc/hosts is correct
dscacheutil -q host -a name litellm     # → ip_address: 127.0.10.1
host litellm                            # same answer via mDNSResponder
awk '$2=="litellm"{print $1}' /etc/hosts # fallback if DNS layer is unhappy

# Verify lo0 is bound (required because macOS does not auto-route 127.0.0.0/8)
ifconfig lo0 | grep 127.0.10            # one line per alias from aliases.tsv

# Container side — bare names via Docker DNS, same explicit container port
docker run --rm --network ai-stack alpine getent hosts litellm
docker exec litellm wget -qO- http://phoenix:6006/healthz
docker exec litellm wget -qO- http://ollama:11434/api/tags

# List who's on the ai-stack network
docker network inspect ai-stack --format '{{range .Containers}}{{.Name}} {{end}}'
```

If an `http://<alias>:<port>` curl returns "connection refused" or hangs,
run `bash install.sh verify` — Phase 00·V's probes pinpoint which layer
broke (lo0 binding, /etc/hosts, DNS, host-gateway, end-to-end). See
[TROUBLESHOOTING.md § Connection refused](TROUBLESHOOTING.md) for the
manual diagnosis sequence.

### Flip a service on/off

```bash
# Disable Open WebUI (don't stop, just declare disabled — `apply` then stops it)
yq -i '.services.openwebui.enabled = false' ~/ai-stack/services.yml

# Then either run the doctor (reports drift) or stop manually:
docker stop openwebui

# Re-enable
yq -i '.services.openwebui.enabled = true' ~/ai-stack/services.yml
bash ~/ai-stack/bin/start-openwebui.sh
```

### Recreate one container (drift detected)

```bash
stack apply-restarts                  # drains the queue (recommended)

# Or one-off:
bash ~/ai-stack/bin/start-litellm.sh --recreate   # backup → docker rm -f → start
```

Conservative: `--recreate` is the only way to silently destroy a managed
container.

### Ingest a doc into the RAG (phase 06)

```bash
# Drop a file
cp ~/Downloads/manual.pdf ~/ai-stack/ingestor/inbox/

# Run the ingester (one-off; not a daemon by default)
cd ~/ai-stack/ingestor
source .venv/bin/activate
python ingest.py

# Or serve the MCP server for agents
python mcp_server.py        # binds :8765
```

The MCP server exposes a `search_documents(query, top_k)` tool that Hermes
profiles (especially `hermes_researcher`) can call.

### Run the 4/4 security audit

```bash
bash ~/ai-stack/bin/audit.sh
```

Checks: 127.0.10.x loopback-only binds; `.env` is 0600; guardrails.handler
loaded without ImportError; obvious-bad prompt is denied with HTTP 400.

### Switch memory-mode profile

`services.yml` declares 4 profiles (`fleet`, `coding`, `research`, `paranoid`)
that bulk-enable / bulk-disable services. To switch:

```bash
# What's in each profile:
yq '.profiles' ~/ai-stack/services.yml

# Apply (currently manual — flip enabled flags then re-apply):
# (No `stack profile <name>` shortcut yet; mutate services.yml then run install)
```

### See what you decided when

```bash
stack history
```

Assembles `CHANGELOG.d/<run-id>.md` files into one timeline. Useful when "wait,
when did I change that?"

---

## Restart vs recreate

Important distinction:

- **`docker restart <c>`** restarts the process but **keeps the original env
  vars** (set at `docker run` time). If you edited `.env` after the container
  was created, `docker restart` will NOT pick up the new value.
- **`bin/start-<svc>.sh --recreate`** runs `docker rm -f` + `docker run` with
  the current `--env-file`. This is the only way to pick up `.env` changes.

The doctor's `litellm_env_loaded` check detects this drift by inspecting the
running container's env via `docker exec litellm env`.

The installer's `apply-restarts` command exists for exactly this reason —
it does the recreate path, not `docker restart`.

---

## Updating LiteLLM's model list

```bash
# Edit
$EDITOR ~/ai-stack/litellm/config.yaml

# Validate YAML parses
yq -e '.model_list[0]' ~/ai-stack/litellm/config.yaml

# Recreate to pick up new entries
bash ~/ai-stack/bin/start-litellm.sh --recreate

# Verify
stack test 01            # /v1/models lists new entry; per-model ping
```

If a per-model ping fails (provider deprecated, key invalid, slug typo):

```bash
cat ~/ai-stack/installer/state/model-ping-results.txt
```

Shows `<model>\t<PASS|FAIL(code)|SKIP>` so you can decide what to remove or fix.

---

## Adding a new doctor check

Drop a new file in `installer/doctor/checks/` named
`<NN>_<short_name>.sh`. Follow the existing pattern:

```bash
# installer/doctor/checks/14_my_new_check.sh
CHECKS+=(my_new_check)
CHECK_TITLE[my_new_check]="What this checks, in one line"

my_new_check_diagnose() {
  # Return 0 on PASS, non-zero on FAIL.
  # Write diagnostic detail to stdout (re-run by doctor on failure to show user).
  [[ -f some/file ]] || { echo "missing some/file"; return 1; }
}

my_new_check_fix() {
  # Optional. If defined, doctor offers Y/N to run it after a failed diagnose.
  echo "default content" > some/file
}
```

Variable naming discipline: if your function uses a `for` loop or similar that
might shadow doctor.sh's iteration variable, declare it `local`. (The doctor
itself uses `__check` to minimize collision risk.)

---

## Adding a new managed service

1. Add an entry to `services.yml`:

   ```yaml
   services:
     my_service:
       enabled: true
       type: docker
       image: someorg/something:tag
       alias: my-service           # add to installer/lib/aliases.tsv too
       host_ip: 127.0.10.99        # pick the next free .x (see PORTS.md)
       host_port: 80               # HTTP-on-80 is the default
       container_port: 9999
       network: ai-stack
       health: http://my-service/health
       depends_on: [litellm]
       phase: "XX"
       consumes_env: [MY_SERVICE_API_KEY]
   ```

2. Write `bin/start-my_service.sh` following the canonical flag order (copy
   from `bin/start-qdrant.sh` for the simplest template).

3. If it's a new phase, add a phase script. If it belongs to an existing
   phase, edit that phase script to call `bash bin/start-my_service.sh`.

4. Add a smoke test in `installer/smoke/<phase>.sh`.

5. Add a doctor check in `installer/doctor/checks/`.

6. Re-run: `bash install.sh install <phase>`.

---

## Common questions

**Q: Will `install.sh install all` mess with my running containers?**
A: No, not in conservative mode (the default). It detects foreign containers,
flags them in `status`, and tells you to `adopt` when you're ready. It will
start NEW containers for services that aren't running.

**Q: I edited `.env`. Did the running containers pick it up?**
A: No. `docker restart` doesn't reload `--env-file`. Run `stack doctor` —
the `litellm_env_loaded` check compares declared vs container env. Then
`stack apply-restarts`.

**Q: Phoenix is showing 'Waiting for traces to arrive…' forever.**
A: Most likely `PHOENIX_API_KEY` is empty in `.env`. See INSTALL.md § 3.1.
Verify: `docker logs litellm | grep "Failed to export"`.

**Q: I want to nuke everything and start fresh.**
A: `stack reset --confirm nuke` (requires typing `nuke ai-stack` literally).
This backs up `.env` and `data/` first, then removes containers + ollama
models + `.env`.

**Q: A phase keeps re-running every time even though the work is done.**
A: That phase's `precheck()` is returning non-zero. Read the precheck function
in `installer/phases/<NN>_*.sh` to see what it checks. Fix the underlying
state, or (last resort) `touch installer/state/phase_<NN>.done` to manually
stamp.

**Q: How do I see what the installer decided?**
A: `cat CHANGELOG.md` for the architecture-level decisions. `stack history`
for per-run logs. `installer/state/` for current state files.
