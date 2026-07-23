# Model & Agent Console — resume/handoff prompt

A self-contained prompt to pick up this feature in a fresh agent or after context
compaction. Paste the fenced block below verbatim. The durable spec + the 7
council-locked design changes + progress live in the memory file referenced inside
it; this doc is the lean execution handoff that travels with the code.

Status when written (2026-06-24): **P1 (CLI foundation) complete + committed** on
branch `feat/model-console` (commits `90df125`, `255b575`, `306a068`); **not merged**.
Remaining: P2 (serve + proxy), P3 (MODELS.html UI), P4 (doctor + smoke + docs), §24
review, merge.

---

```
TASK: Finish the "Model & Agent Console" feature for the ai-stack repo
(/Users/mayssam.sayyadian/ai-stack). A web console served like `tutorial-serve`
to manage LiteLLM models + agent bindings via UI instead of hand-editing
litellm/config.yaml. This is a RESUME: the CLI foundation (P1) is done; you build
P2–P4, get it reviewed, and merge.

FIRST, GROUND YOURSELF (do this before touching anything):
1. Read the memory file: ~/.claude/projects/-Users-mayssam-sayyadian-ai-stack/memory/project_model_console.md
   It has the full council-locked spec, the 7 blocking design changes, the build
   plan, and progress. Treat it as the source of truth for scope.
2. `git -C /Users/mayssam.sayyadian/ai-stack log --oneline -5 feat/model-console`
   — confirm P1 commits 90df125 (edit/remove), 255b575 (park/unpark), 306a068
   (extended add + dynamic env). The branch is NOT merged.
3. Read installer/lib/models.sh (the `model` CLI you will WRAP — esp. cmd_edit,
   cmd_remove, cmd_park/unpark, cmd_add_remote, cmd_sync, resolve_effective) and
   installer/lib/tutorial_proxy.py + installer/lib/tutorial-serve.sh IN FULL (the
   security pattern to mirror exactly).

STATE: P1 = CLI foundation COMPLETE + verified offline + committed. New commands:
`model edit|remove|park|unpark`, `model add --runtime ollama|openai-compat|openrouter`,
and start-litellm.sh now injects every key_env declared in models.yml (scoped).

REMAINING WORK (build in the EXISTING worktree on branch feat/model-console; if the
worktree is gone, recreate one — never edit the branch in the shared main checkout):
- P2: installer/lib/models-serve.sh (mirror tutorial-serve.sh: port-preflight
  BEFORE mint, ephemeral budget-capped key to a 0600 file, trap-revoke on
  EXIT/INT/TERM, NOT exec) + installer/lib/models_proxy.py (mirror tutorial_proxy.py:
  loopback bind, host-pin, CORS, static allowlist that blocks .js/.json/.env/.sh,
  key from KEY_FILE, subprocess-hardened argv-list calls with env scrub + timeouts
  + single-flight lock). Routes: GET /api/state (model list --json + embedding list
  --json + parsed config.yaml fallbacks + agent matrix + pending), POST /api/stage
  (server-side dry-run -> unified diff of models.yml AND config.yaml + needs_recreate
  flag; trap models.sh exit 2 -> 400 JSON, never crash), POST /api/apply (run the
  staged change via the model CLI; confirm_recreate gate; pre-apply timestamped
  backups of models.yml/config.yaml/.env). WRAP the CLI — never reimplement model
  logic in Python. Wire `models-serve` into mayssam-ai-stack.sh dispatch + help.
- P3: doc/MODELS.html — fresh modern single-page UI, fully self-contained INLINE
  css/js (static server blocks .js). Sections: Models (catalog grouped by runtime +
  availability; add/edit/remove; alias), Fallbacks (view; guarded edit), Agents
  (list + change model + park/disable, state badge Assigned|Default|Parked), and a
  persistent staged-changes drawer (review both-file diff + needs_recreate banner +
  confirm-recreate modal). WCAG-AA, empty/loading/error states.
- P4: doctor check(s) (NO cold-start — liveness only: models.yml valid + resolves,
  config.yaml no orphans vs models.yml, declared key_env present-in-.env WARN,
  models-serve presence) + installer/smoke E2E + FULL doc sweep (EXPLORE card,
  TUTORIAL.md + regen via installer/lib/build_tutorial_html.py, USER-GUIDE link,
  ATTRIBUTION, CHANGELOG, service/check counts).
- THEN: SOUL §24 review of the full diff (adversarial + architect + qa/infra + PM),
  debate to consensus, fix, then pull→commit→merge to main→push.

HARD CONSTRAINTS / GOTCHAS (violating these has burned prior sessions):
- Edit ONLY in a git worktree; OPERATE the live stack (start/sync/recreate/doctor/
  the E2E browser test) ONLY from MAIN — containers bind-mount the workspace path,
  so running the stack from a worktree breaks it (feedback_worktree_breaks_live_stack).
- The Bash shell cwd RESETS to MAIN even when the session is "in" the worktree for
  file tools — always pass absolute worktree paths to bash, and run models.sh with
  --dry-run/--no-sync for OFFLINE verification (worktree has its own models.yml/
  config.yaml copies; restore with `git -C <wt> checkout -- ...`).
- models.yml is the source of truth; config.yaml is RENDERED by `model sync` (never
  hand-edit it) EXCEPT litellm_settings.fallbacks + openrouter routes which live only
  in config.yaml.
- Vendor API keys NEVER cross the HTTP layer — the proxy reads key_env from .env
  server-side; only the VAR NAME is posted. No in-console key entry in v1.
- mikefarah yq REJECTS `// empty` — use plain paths + skip "null" in shell.
- The static serve allowlist blocks .js, so MODELS.html must inline its JS.
- OpenRouter add is config.yaml-only + NOT agent-assignable in v1; validate the
  provider/model id format (hallucinated ids 404 at call time).
- --recreate drops the LiteLLM container the whole fleet routes through — gate it
  behind explicit confirm + a downtime warning; only when .env/env-set changed.
- Never rm/mutate the real ~/ai-stack/.env (feedback_never_rm_real_env).

DEFINITION OF DONE: feature works E2E from a real browser over http://127.0.0.1
(launched from MAIN), full `doctor` green from MAIN, smoke passes, docs swept in the
same change, §24 review cleared, branch merged to main + pushed, memory updated.
Report (not ask) the assumed decision points at the end (see the memory file's list).
```
