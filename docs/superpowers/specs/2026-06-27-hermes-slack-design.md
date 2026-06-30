# Hermes ↔ Slack integration — design spec

**Date:** 2026-06-27
**Branch:** `codex/slack-role-missions`
**Status:** Milestones 1/2 implemented in the Slack role-router branch; live Slack E2E still requires a healthy OpenShell runtime and an explicit Slack test.
**Decisions (user):** personal Slack workspace · two-way (drive-the-fleet).

## Revised decision — virtual roles + mission threads

After the native Slack channel landed, the user explicitly chose Milestones 1 and
2 from the follow-up Slack UX design: keep one Slack app, expose the Hermes fleet
as virtual addressable roles, and make multi-role work visible in Slack mission
threads. This supersedes the v1 "Slack is only a native Hermes gateway channel"
implementation detail for Slack traffic while preserving its security posture:
Socket Mode remains outbound-only from `hermes-fleet-v1`, no public URL is added,
and the same allowlist gates every incoming Slack request.

**New default:** Phase 38 disables Hermes' native Slack adapter
(`platforms.slack.enabled=false`) and starts ai-stack's in-sandbox Slack role
router. The upstream Hermes gateway still serves Telegram and any other native
Hermes channels. The role router owns Slack Socket Mode and shells each routed
turn to the real Hermes profile (`hermes --profile hermes_<role>`), preserving
Slack `thread_ts` and local audit metadata.

**Rollback:** set `HERMES_SLACK_ROLE_ROUTER=false` and re-run Phase 38. The start
script must stop the ai-stack role router before enabling upstream-native Slack,
so there is never an intentional duplicate Slack Socket Mode consumer.

**Acceptance additions:** role prefixes (`techlead:`, `backend:`, `qa:`, `sre:`),
built-in groups (`delivery`, `review`, `release`), active-thread human
interjections, bot-message suppression, durable event/job/interjection state,
strict config validation, channel whitelist/home-channel gating for non-DM posts,
and doctor 67 asserting the router process plus structured health. Allowlisted
Slack users are Hermes operators; `HERMES_SLACK_ALLOW_ALL` does not grant operator
authority in role-router mode. `HERMES_SLACK_HOME_CHANNEL=C0BDEMEM19R` allows
`hermes_notification` to host mission threads; proactive notification broadcasts
remain out of scope for Milestones 1/2.

## Problem
The ai-stack runs Nous Research `hermes-agent` as a 9-role fleet ("hermes-fleet-v1")
inside an OpenShell sandbox. The fleet is already reachable from **Telegram** (Phase 20,
`@vz_hermes_controller_bot`). The user wants the same fleet reachable from **Slack**:
DM (or @mention) a bot and a fleet profile answers.

## Base v1 approach — native channel, superseded for Slack traffic by the role router
Nous Hermes' messaging gateway runs **one process, many channels**. Slack is a *native*
channel via **Socket Mode** (outbound WebSocket → no inbound webhook / public URL — ideal
for a laptop behind NAT). The first Slack landing used that native channel model.
Milestones 1/2 keep the same Socket Mode and egress/security foundation, but Slack
traffic is now owned by the ai-stack role router so one app can address multiple
Hermes role targets.

Mirrors the proven **Phase 20 (Telegram)** template: secrets piped via STDIN into the
sandbox `~/.hermes/.env`; channel config + allowlist in `~/.hermes/config.yaml`;
secure-by-default (no allowlist → deny all); in-sandbox self-persisting daemon; doctor
health check; `services.yml` entry; full doc sweep.

### Rejected alternatives
- **B — separate Slack gateway instance/sandbox.** Hermes is designed for one
  gateway/many channels; a 2nd instance doubles processes + egress surface. YAGNI.
- **C — custom host-side Slack Bolt app → fleet.** Throws away native support and
  reintroduces the host daemon Phase 20 deliberately avoided. Large surface. YAGNI.

## §24 council — required changes adopted
1. **Phase 38** (`38_hermes_slack.sh`) — `21` is taken (`21_portless.sh`); phases run 00→37.
   Doctor check **67** (`67_hermes_slack.sh`); checks run to 66.
2. **Egress rule belongs in the generator.** `installer/phases/04_openshell.sh:81` regenerates
   `openshell/policies/hermes-fleet-v1.yaml` from a heredoc and live-applies it (`:455`). The
   `slack:` stanza must be added to the **heredoc** (source of truth) AND live-applied by
   Phase 38 (`openshell policy set … --wait`, the Phase-27 backstop pattern) — else it reverts
   on the next `install 04`/recreate (the Sourcegraph-MCP incident, CHANGELOG 2026-06-20).
3. **Close the allowlist bypass.** Force `unauthorized_dm_behavior: ignore` — the doc's default
   `"pair"` lets an unknown user self-pair past `SLACK_ALLOWED_USERS`. Secure-by-default = deny-all.
4. **Don't let a bad Slack token kill Telegram.** Validate both Slack token shapes (`xoxb-`/`xapp-`)
   **before** the shared-gateway `run --replace`. Extract `installer/lib/hermes.sh`
   (`_hermes_gateway_restart`) sourced by both Phase 20 and Phase 38; update Phase 20 in the
   same commit so re-running it can't clobber Slack. Keep Telegram-specific 409-suppression in
   the Telegram path only.
5. **Truthful doctor check.** Assert the Slack Socket-Mode `hello` handshake event actually
   landed (not just "token present"); never print `xoxb-`/`xapp-`; filter benign reconnect noise
   (reconnect/ping/pong/429); catch real auth errors (invalid_auth/token_revoked/missing_scope/
   not_allowed_token_type). No external Slack API call.
6. **Trim blast radius for v1.** Drop `files:read`/`files:write` scopes. Defer channel-prompts,
   skill-bindings, STT, home-channel proactive, multi-workspace. MVP = DM-the-bot (+ @mention in
   channels), secure allowlist.

## Build-time verifications (before/while writing code, with tokens present)
- Exact `hermes config set` key names for Slack + whether `config.yaml` is flat (`SLACK_*:`) or
  nested (`platforms.slack.*`) in the installed binary (`nousresearch/hermes-agent:v2026.6.19`).
  Probe with **single-line** `openshell sandbox exec` (gRPC exec rejects newlines).
- Authoritative scopes/events via `hermes slack manifest` from the live binary.
- Empirical egress host discovery: seed `api.slack.com:443`, `slack.com:443`,
  `wss-primary.slack.com:443`, `wss-backup.slack.com:443`; restart; grep
  `/sandbox/.hermes-gateway.log` for `policy_denied`/403 + the `hello` success event; add any
  missing host to the heredoc; re-apply.
- Confirm hermes does not log the `Authorization: Bearer xoxb-…` header; scrub if it does.

## What the user creates (two-way, personal workspace)
A Slack app (from the provided manifest) → **bot token `xoxb-…`** + **app-level token `xapp-…`**
(scope `connections:write`, Socket Mode) + their **member ID `U…`** (allowlist) + optional
**channel ID `C…`** (mission-room mentions/threads). Host `.env` keys: `HERMES_SLACK_BOT_TOKEN`,
`HERMES_SLACK_APP_TOKEN`, `HERMES_SLACK_ALLOWED_USERS` (+ optional `HERMES_SLACK_HOME_CHANNEL`,
`HERMES_SLACK_ALLOW_ALL`).

## Live-stack rule
Edit all code in this worktree; **operate** the stack (install 38, `policy set`, gateway
restart, doctor) only from the **MAIN** checkout (containers bind-mount the workspace path).

## Definition of done
Phase 38 + check 67 + `lib/hermes.sh` + egress heredoc + `services.yml` `hermes_slack` +
doc sweep (EXPLORE/TUTORIAL→regen/HERMES-HANDSON/OPERATIONS/TROUBLESHOOTING/DOCTOR/
ATTRIBUTION/CHANGELOG + counts) all landed; **full `doctor` green from MAIN** incl. check 33
(Telegram not regressed) + check 67; a **real message from a Slack client** gets a fleet reply
(SOUL §5 E2E); CHANGELOG updated; merged + pushed.
