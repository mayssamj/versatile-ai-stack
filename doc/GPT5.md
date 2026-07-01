# Use GPT-5.5 (and 5.4) — the one-liners

OpenAI GPT-5.x runs in the stack two ways, and both are **assignable** — pick a
model id and point any agent (or the whole fleet) at it with one command. Live
catalog any time: `vz-ai-stack.sh model list`.

## The model ids (type these with `model assign`)

| id | route | cost | reasoning |
|----|-------|------|-----------|
| `openai-gpt-5.5`     | metered API key (`OPENAI_API_KEY`) | per-token | **xhigh** (max) |
| `openai-gpt-5.5-pro` | metered API key | per-token (premium) | inherent max-accuracy |
| `openai-gpt-5.4`     | metered API key | per-token | high |
| `openai-gpt-5.5-sub` | your **ChatGPT subscription** (codex-bridge) | $0 (plan) | xhigh\* |
| `openai-gpt-5.4-sub` | your ChatGPT subscription (codex-bridge) | $0 (plan) | high\* |

\* `reasoning_effort` is *accepted* on the subscription route (no error) but its
honoring by the Codex backend is unverified; the **metered** route is the
verified max-reasoning path.

## A) Metered — works right now (your `OPENAI_API_KEY` is set)

```bash
# whole fleet on GPT-5.5 at max reasoning:
vz-ai-stack.sh model assign all openai-gpt-5.5
# or one agent / a premium model:
vz-ai-stack.sh model assign hermes_manager openai-gpt-5.5-pro
```
`model assign` registers the model in LiteLLM, widens the scoped keys, and
re-points the agent(s) — nothing else to run. In Open WebUI, just pick
`openai-gpt-5.5` from the dropdown.

## B) Subscription (no metered cost) — one command to enable the bridge

```bash
bash ~/ai-stack/bin/start-codex-bridge.sh enable      # codex login (browser) + daemon + LiteLLM reload
vz-ai-stack.sh model assign all openai-gpt-5.5-sub    # whole fleet on your ChatGPT plan
```
`enable` is idempotent (skips the login if you're already signed in) and shows a
one-time risk banner. ⚠ The subscription route uses the ChatGPT **product**
backend (unofficial automated use, **single personal account only**, real
account-suspension risk — see [models.md](models.md) §"Codex bridge" and
`bin/start-codex-bridge.sh`). It's **rate-limited by your plan** (Plus ≈ 15–80
GPT-5.5 msgs / 5h), so treat it as a secondary route; the metered path stays the
reliable default. If the bridge is down it **gates to `local`** (never a
hard fail, never a surprise metered bill).

## Make GPT-5.5 the default for *unassigned* agents

```bash
# in installer/models.yml set:  primary: openai-gpt-5.5    (or openai-gpt-5.5-sub)
vz-ai-stack.sh model sync
```
`default:` must stay an Ollama model (the always-on offline fallback); `primary`
is what an unassigned agent renders and it availability-gates to `default`.

## What `model assign` covers (and what it doesn't)
`model assign` / `model sync` operate on the **fleet** — the agents in
`installer/models.yml` `kinds:` (the 9 hermes roles + pi/deerflow/ace/rlm). The
**opt-in sims** (mempalace, metagpt, agentscope, oasis, chatdev, aitown, aionui,
openwork) are per-phase consumers, **not** assignable agents — `model assign <sim> …`
would write an assignment that fails `models.yml` validation (no `kinds:` entry).
To point a sim at a different model, set its model in that phase's config and re-run
`vz-ai-stack.sh install <NN>` for the sim; the phase reconciles the sim's scoped LiteLLM
key allow-list automatically (so the rename doesn't silent-403). The sim doctor checks
(57–61) read `.assignments.<sim>` defensively and default to `local`, so an
unassigned sim's key is verified against `local` — exactly the model it calls.

## Cost / safety
- Metered models spend your real OpenAI bill — there's no per-key `max_budget` cap
  yet (tracked follow-up), so prefer the `-sub` models for cost-conscious fleet use.
- A missing `OPENAI_API_KEY` (metered) or a down bridge (subscription) gates the
  agent to `local` with a pending line — surfaced by `vz-ai-stack.sh model list`.
- Health: `vz-ai-stack.sh doctor codex` (bridge), `vz-ai-stack.sh doctor 40` (binding).
