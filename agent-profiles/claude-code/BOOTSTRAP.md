# Bootstrap — Claude Code

Subagents are markdown files in `.claude/agents/` (project) or `~/.claude/agents/` (user). The body is the
system prompt; the frontmatter scopes tools, model and skills.

## Steps
```bash
mkdir -p .claude/agents .claude/skills
# 1) drop each <role>.md (from the Claude Code tab) into .claude/agents/
# 2) drop each shared SKILL.md (from the Shared Skills tab) into .claude/skills/<name>/SKILL.md
# 3) default subagents to Sonnet, run the main session on Opus:
export CLAUDE_CODE_SUBAGENT_MODEL="sonnet"
claude --model opus
# 4) verify they loaded:
/agents            # Library tab lists them; Running tab shows live ones
```

## Notes
- Use model **aliases** (`opus`/`sonnet`/`haiku`), not pinned dated model IDs — aliases don't go stale.
- Read-only roles (reviewing-engineer, incident-manager, manager) omit Edit/Write in `tools`.
- Build-tier roles get write tools via the `tools` allowlist (that grant overrides session policy for the call).
- Wire MCP servers (github, postgres, slack, pagerduty) via the `mcpServers` frontmatter field per role.
- Multi-agent coordination: the manager orchestrates; for true peer-to-peer, enable Agent Teams
  (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`).

## In ai-stack (automated, GLOBAL install)
`vz-ai-stack.sh install agent_fleet` copies all 9 agents → `~/.claude/agents/` and the 6 shared skills →
`~/.claude/skills/<name>/SKILL.md` (USER-global — active in every Claude Code session on this machine). It is
idempotent and will NOT clobber a file you've edited (it writes `<name>.md.ai-stack-new` beside it and warns).
Claude Code runs on your native `claude login` subscription, so agents keep `model: opus`/`sonnet` aliases —
no Meridian/LiteLLM involved on this platform.
