# Fleet durability hardening — P0 incident + remediation (2026-06-08)

Status: implemented on branch `worktree-fleet-hardening`; validated live; pending merge.
Method: 4-member council (adversarial + SRE + AI-domain + orchestrator) → debate → consensus
→ 10-item plan (H1–H10) → 2 independent auditors → implementation → live validation.

## Incident
A clean install that passed doctor degraded into a **host hang requiring a hard reboot**.
Root mechanism (evidence-confirmed):

1. OpenShell mints each sandbox a **1-hour, read-only bootstrap JWT** (decoded: `exp−iat = 3600s`).
   It cannot self-refresh (no `openshell sandbox refresh`; token is a RO bind-mount).
2. The hard reboot restarted the gateway daemon, wiping its in-memory session state; the relay
   re-bootstrapped with the long-expired JWT → `invalid token: ExpiredSignature`.
3. The relay **hot-loops with no backoff** (pi-v1 reconnect attempt **3586**, hermes **2973**).
4. Sandboxes had **no CPU/RAM caps** (`NanoCpus=0, Memory=0`) inside a 6 GB / 5-CPU OrbStack VM
   → CPU + memory pressure → host hang.
5. `RestartPolicy=unless-stopped` **resurrected the storm** on every restart (RestartCount 5–6).
6. The only documented cure was **delete + recreate**, which `openshell.sh` itself admitted
   "discards in-sandbox state" — **the remediation was the data-loss event.**

It was **auth-expiry mistaken for corruption, with a destructive default cure.** No filesystem
corruption occurred; all data was recoverable via `docker cp` from the stopped (not removed) containers.

## Consensus root causes (ranked)
| # | Cause |
|---|---|
| 1 | RC5 — no persistent volume / checkpoint; agent state lives only in the writable layer |
| 2 | RC6 — every storm/heal/reset path deletes with no verified backup first |
| 3 | Gateway identity-plane SPOF — `openshell.db` (journal_mode=delete) + live signing-key rotation, no backup |
| 4 | RC1 — 1 h read-only JWT, no in-place refresh |
| 5 | RC3 — no CPU/mem caps → one runaway storms the host |
| 6 | RC2 — no-backoff relay retry loop (upstream openshell-sandbox defect) |
| 7 | RC4 — `unless-stopped` resurrects the storm post-reboot |
| 8 | Amplifiers — Tier-3 gateway restart errors ALL sandboxes; watchdog plist never carried HALT/RECREATE; `doctor --fix` inherited ambient RECREATE=1; `docker container prune`; reset.sh torn-backup-then-wipe |

## What shipped (H1–H10 + mechanisms)
- **H1** `installer/lib/openshell.sh` — native `--cpu/--memory` caps + labels at create (before `--`).
  *Live-verified:* gateway honors caps (NanoCpus=1000000000, Memory=2 Gi). Tunable `OPENSHELL_SANDBOX_CPU/_MEM` (0=unlimited).
- **H3** `bin/openshell-checkpoint.sh` — verified `docker commit` **before every delete** (fail-closed:
  rc 2 ⇒ delete refused), retain-N, `ai-stack.keep` label, lifecycle event. Wired into openshell.sh
  storm branch, watchdog (HALT + RECREATE), `reset.sh`, `fleet.sh`.
- **H4** `bin/openshell-watchdog.sh` — **HALT-by-default** (cap 0.5cpu/2g then `docker stop`), plist now
  exports `HALT`/`RECREATE`, interval 600→180 s, RECREATE path checkpoints fail-closed.
- **H5** openshell.sh — `docker update --restart=no` post-create (no storm resurrection on reboot). *Live-verified.*
- **H6** `doctor/checks/39` — hard-pins `AI_STACK_WATCHDOG_RECREATE=0` in the fix path (closes the
  2026-06-03 repeat vector); `43` reframed; both reference the restore command.
- **H7** `bin/openshell-identity-backup.sh` — consistent `sqlite3 .backup` of `openshell.db` + signing
  key, integrity-verified, retain-N, daily launchd timer; `guard-regen` refuses key rotation while
  tokens outstanding; `enable-wal` gated behind `AI_STACK_CONFIRM_WAL` (quiesce-then-convert). *Ran live: backup verified OK.*
- **H8** `installer/lib/reset.sh` — verified backups that **ABORT** the wipe on failure (`AI_STACK_FORCE_WIPE=1`
  escape), named-volume tar-backup before `docker volume rm`, brew-resolved openshell, orphan-token sweep,
  checkpoint before each sandbox delete, identity snapshot first.
- **H9** `bin/openshell-state-restore.sh` (+ experimental `bin/openshell-token-refresh.sh`) — extract /
  into / verify. *Live round-trip PASSES:* file **and** dotfile state survives checkpoint→delete→recreate→restore.
- **H10** openshell.sh — Tier-3 gateway restart refuses to knock out healthy sandboxes (`OPENSHELL_FORCE_GATEWAY_RESTART=1`
  override), snapshots identity first; doctor surfaces prune-vulnerable stopped sandboxes.
- **Mechanisms (operator ask):** `bin/ai-stack-changelog.sh` (typed CHANGELOG.d fragments), `installer/lib/fleet-events.sh`
  + `bin/fleet-trace.sh` (canonical lifecycle JSONL logger + tail/stats/export-otlp to Phoenix).

## Validation evidence (live, this host)
- Caps honored + restart=no applied on create (throwaway sandbox, inspected).
- Full restore round-trip PASS (file + dotfile).
- Real fleet reclaim: hermes 9 profiles + kanban.db + state.db verified readable; pi reclaimed.
- Identity-plane backup verified OK; checkpoint primitive verified on real stopped containers.
- All scripts pass `bash -n`.

## Residual risks (honest)
- **`--label` does NOT propagate to the docker container** (gateway limitation, verified). Container-level
  `docker container prune` is guarded by restart=no + the doctor stopped-sandbox warning; the keep label
  protects checkpoint/forensic **images**, not live containers.
- **Host-side JWT re-mint is UNPROVEN** — `openshell-token-refresh.sh` is experimental, gated, not auto-wired;
  needs a security review (reads the signing key + mints bearer tokens) before any promotion.
- **1 h TTL is not extendable** via any exposed `settings` key — we mitigate consequences, not the trigger.
- **A live-DB `cp -R` (phoenix/qdrant) is a torn snapshot** — identity DB uses `sqlite3 .backup`; the other
  service volumes get a tar snapshot but consistency for actively-written DBs is best-effort.
- **RC2 (no-backoff relay loop)** is an upstream binary defect — contained by caps + HALT, not fixed.

## Operator runbook
- Checkpoint a sandbox:        `bash bin/openshell-checkpoint.sh <name> [reason]`
- Reclaim state (no recreate): `bash bin/openshell-state-restore.sh extract <name|image> <dest>`
- Restore into a sandbox:      `bash bin/openshell-state-restore.sh into <name> <src>`
- Back up gateway identity:    `bash bin/openshell-identity-backup.sh backup` (daily timer via `… install`)
- See fleet lifecycle:         `bash bin/fleet-trace.sh tail` / `stats` / `export-otlp`
- DO NOT during an incident:   `docker container prune` / `docker system prune` / `brew services restart openshell`
  before checkpointing — stopped sandbox containers are prune-vulnerable.
