# Bootstrap — Hermes

The persona unit is the **profile** — a fully isolated instance with its own config, memory, sessions, skills
and SOUL.md. One profile per role (your choice) maps perfectly and gives real credential isolation.

## Steps
```bash
# create one profile per role
for r in manager techlead frontend-engineer backend-engineer ml-engineer \
         qa-test-engineer reviewing-engineer sre-engineer incident-manager; do
  hermes profile create "$r"
done

# Or, in ai-stack, do all of this automatically (rebuilds hermes-fleet-v1 to these 9 roles,
# wires models from installer/models.yml, installs the team-protocol + discipline skills):
#   install.sh install agent_fleet

# for each profile: write its SOUL.md (from the Hermes tab), set its toolset in config.yaml,
# add MCP servers, then install its skills:
hermes -p backend-engineer skills install official/<category>/<skill>   # per skill
hermes -p backend-engineer mcp add ...                                  # connectors (OAuth supported)
hermes -p backend-engineer skills inspect                               # confirm tool IDs for your version
```

## Orchestration
The **manager** profile drives the shared SQLite **kanban board** to dispatch work; a dispatcher spawns the
other profiles as workers (each pinned to the board). See `hermes kanban`.

## Notes
- SOUL.md is slot #1 of the system prompt — keep it persona/voice + standing rules; it's scanned for prompt
  injection, so don't smuggle meta-instructions into it.
- Put durable facts in MEMORY.md / USER.md; procedures live in skills.
- Isolate prod credentials to the sre-engineer / incident-manager profiles (token locks prevent collisions).
