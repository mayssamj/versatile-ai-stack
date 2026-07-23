# Bootstrap — Pi

Pi is a minimal, extensible harness. A persona is `SYSTEM.md` (replaces/appends the system prompt) plus
`AGENTS.md` (project context). Skills load on demand from `~/.pi/agent/skills/`.

## Steps
```bash
curl -fsSL https://pi.dev/install.sh | sh
# one project dir per role (or a single dir you switch SYSTEM.md in):
mkdir -p ~/agents/backend-engineer && cd ~/agents/backend-engineer
# save the role's SYSTEM.md here; put shared repo rules in AGENTS.md
pi install <skill-or-package>     # install the role's skills (agentskills.io-compatible)
pi                                # run Pi in this directory
```

## Important: Pi has no native fleet
Pi deliberately ships **no subagents and no plan mode**. So:
- **Phase 1 (now):** each role is its own Pi session with its `SYSTEM.md` + skills. You "switch hats" by
  switching project dir / SYSTEM.md, or run several Pi sessions side by side.
- **Phase 2 (build):** a real multi-agent fleet (roles delegating to each other, an orchestrator) is built on
  Pi's SDK (`createAgentSession`, `AgentSessionRuntime`) or RPC mode — Pi gives you the runtime, not the team.

This is the one place the three frameworks are genuinely asymmetric — don't expect a live Pi team out of the box.

## In ai-stack (automated phase-1)
`mayssam-ai-stack.sh install agent_fleet` uploads all 9 role `SYSTEM.md` into the `pi-v1` sandbox at
`/sandbox/agents/<role>/`. Switch hats with `bin/pi-as <role>` (lists roles with no arg). Each role's model
is pinned per-launch via `pi --model`; the shared `team-protocol` skill governs handoffs even when you're
switching hats manually.
