# Handoff — latest state + where to go next

> **This is NOT the onboarding doc, and not "read me first."** It's a short, *perishable* "what
> just happened / what's next" note for an agent continuing very recent work. Keep it short; the
> moment a fact here outlives the work, delete it.

**If you're a fresh agent or human taking over development**, go to
**[`AGENT-ONBOARDING.md`](AGENT-ONBOARDING.md)** (the deep map + constitution + recipes), and paste
**[`ONBOARDING-PROMPT.md`](ONBOARDING-PROMPT.md)** to bootstrap a brand-new agent.

**Live truth beats this file** — counts, health, and bindings drift, so always derive them live:

| For… | Run (from the MAIN checkout) |
|---|---|
| Is it healthy? (source of truth) | `bash vz-ai-stack.sh doctor` |
| Declared vs actual, per service | `bash vz-ai-stack.sh status` |
| Phases / model↔agent bindings | `bash vz-ai-stack.sh phases` · `model list` |
| Recovery from a known failure mode | **[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)** |
| Full history + the *why* behind every change | **[`../CHANGELOG.md`](../CHANGELOG.md)** (newest at top) |

---

## Snapshot (perishable — re-derive with the commands above)

| Property | Value |
|---|---|
| Stack root / entry | `~/ai-stack` · `bash vz-ai-stack.sh` (alias `bin/stack`) |
| Host | M4 MacBook Pro, 24 GB, macOS, OrbStack, Homebrew, brew bash 5.x |
| Scale | ~**50** services · **67** doctor checks · **45** phases (~30 core / ~15 opt-in) — `doctor`/`phases` are authoritative |
| Platform default model | `claude-opus-sub-max` (fleet + unassigned agents); the opt-in sims + HALO stay on `claude-opus-sub-xhigh` (lighter for many-agent runs); `default: local-gemma4` is the keyless last-resort net. **No model SILENTLY uses a local one** — a cloud/Meridian outage surfaces a visible 503. |

## Most recent work (newest first — full detail in CHANGELOG.md)

- **Concordia — Phase 37 (opt-in agent-sim #6)** — DeepMind generative agent-based modeling (GABM) with a Game Master; host-venv (py3.12), default `claude-opus-sub-xhigh`, install/`test` gate on the faster `claude-sonnet-sub-high`. Hands-on in `doc/TUTORIAL.md` L20½; doctor check 66.
- **Model-default policy → `claude-opus-sub-max`** — platform default repointed (fleet + unassigned); LiteLLM cloud→`local-qwen3` fallbacks removed so a cloud outage is a visible 503, not a silent local degrade. Opt-in sims/HALO kept on `-xhigh`.
- Anything older: read **CHANGELOG.md** top-to-bottom.

## Open threads / what's next

- `~/.claude/.../memory/MEMORY.md` (the session memory index) is near its read-size cap — a *lossless* index trim is pending (owner's call; a lossy compaction that drops entries is a §5 action, not done unprompted).
- _Add the next handoff note above this line, dated, and keep it short — durable how-to-recover content belongs in `TROUBLESHOOTING.md`, durable design rationale in `CHANGELOG.md`, and onboarding in `AGENT-ONBOARDING.md`._

---

*Doc roles, so a new agent never wonders which to read: **ONBOARDING.md** = end-user ("installed it,
now use it"); **AGENT-ONBOARDING.md** = the developer/owner deep map (start here to take over);
**ONBOARDING-PROMPT.md** = the paste-into-a-fresh-agent bootstrap prompt; **this file** = the
perishable latest-state pointer; **TROUBLESHOOTING.md** = recovery; **CHANGELOG.md** = history.*
