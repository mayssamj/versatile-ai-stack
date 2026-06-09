# Fleet Durability — Guardrails Reference

How the ai-stack guarantees that **fleet/agent containers and their data never become
corrupt-and-unrecoverable**. This is the evergreen reference for the safety model and the
concrete guardrails; for the point-in-time incident that motivated it, see
[`doc/specs/2026-06-08-fleet-durability-hardening.md`](specs/2026-06-08-fleet-durability-hardening.md).

> **Core principle — "always reconstructable" > "never corrupt."**
> Corruption cannot be made impossible (power loss, SIGKILL mid-write, disk faults). The real,
> achievable guarantee is that corruption is **never catastrophic** because state can always be
> rebuilt from persisted, verified copies. Every guardrail below either **lowers the probability**
> of corruption or **guarantees recoverability**. The durability promise lives in the recovery
> layers, not in hoping corruption never happens.

Legend:  ✅ shipped · ⚠️ gap / roadmap

---

## Layer 0 — Decouple data lifetime from container lifetime
The root cause of the 2026-06-08 P0 was agent state living **only** in the container's writable
layer, so destroying the container destroyed the data.

- **State must not live only in the writable layer** — treat containers as disposable ("cattle,
  not pets"); the durable state is captured/restorable independently. ⚠️ OpenShell's CLI exposes
  **no volume-mount flag**, so we substitute **checkpoint/restore** (Layer 3). A real persistent
  mount (custom sandbox image or upstream feature) would be the strongest version → roadmap.
- **Declarative, version-controlled source** — souls/profiles/policies live in `agent-profiles/` +
  git and are re-rendered by the idempotent installer, so only true runtime state
  (`kanban.db`, `state.db`/messages, `memories/`, `sessions/`) ever needs *restoring*. ✅

## Layer 1 — Prevent corruption (lower the probability)
- ✅ **Resource caps** — every sandbox is created with `--cpu`/`--memory` (gateway-honored,
  verified live) so a runaway/storm can't thrash or OOM the host into torn writes.
  Tunable: `OPENSHELL_SANDBOX_CPU` (default `1.5`), `OPENSHELL_SANDBOX_MEM` (default `3Gi`); `0` = unlimited.
- ✅ **Consistent DB snapshots, never a live `cp`** — use `sqlite3 .backup` (identity DB),
  `PRAGMA wal_checkpoint(TRUNCATE)` when folding a WAL on extract. ⚠️ the other service volumes
  (honcho/qdrant/phoenix) are still `cp -R`'d on `reset` (torn) → use `pg_dump`/`BGSAVE`/snapshot API (roadmap).
- ✅ **Quiesce before mutating** — e.g. `openshell-identity-backup.sh enable-wal` stops the gateway
  before changing journal mode (gated behind `AI_STACK_CONFIRM_WAL=1`).
- ✅ **No storm-resurrection** — `docker update --restart=no` post-create: a credential-dead
  container does not auto-restart-loop into an expired token after a reboot.
- **RAM headroom** — keep the OrbStack VM cap below physical RAM so the box never swap-thrashes
  into a lockup (see [`project-cpu-gotchas`] in memory). ✅ RAM-budget preflight on big MLX loads.

## Layer 2 — Contain blast radius (corruption stays local)
- ✅ **Fail-closed before every delete** — `bin/openshell-checkpoint.sh` runs a verified
  `docker commit` and **the delete is refused (exit 2) if the snapshot can't be taken**. Wired into
  all four delete sites: `openshell.sh` storm branch, `openshell-watchdog.sh`, `reset.sh`,
  `fleet.sh cmd_fleet_destroy`. Bypass only via the explicit `AI_STACK_FORCE_WIPE=1`.
- ✅ **Guardrails on dangerous commands** — `reset` aborts the wipe on a failed/unverified backup;
  `doctor --fix` hard-pins `AI_STACK_WATCHDOG_RECREATE=0` (can't inherit an ambient destructive
  env); Tier-3 gateway restart refuses when another sandbox is healthy; stopped sandboxes are
  surfaced as prune-vulnerable.
- ✅ **Protect the control/identity plane** — the gateway DB (`openshell.db`) + Ed25519 signing key
  are a single SPOF whose loss bricks every token; `openshell-identity-backup.sh guard-regen`
  refuses key rotation while any sandbox token exists (fail-safe).
- ✅ **Per-unit isolation** — caps + the watchdog mean one sandbox's storm can't starve the host or
  corrupt a sibling.

## Layer 3 — Recover / reconstruct (the actual guarantee)
- ✅ **Checkpoint before every risky op** (storm, heal, reset, destroy). ⚠️ **Add a periodic
  checkpoint timer** to bound RPO between events (roadmap — highest-leverage gap).
- ✅ **Multiple independent copies** — checkpoint image (`openshell-checkpoint/<name>:<ts>`,
  `ai-stack.keep` label) + extracted host tarball + identity-plane backup + git-tracked declarative
  source. Any one layer can fail.
- ✅ **Retention / roll-back** — `OPENSHELL_CHECKPOINT_KEEP` (default 5) keeps N historical
  checkpoints so you can roll back *past* a corruption that was itself snapshotted.
- ✅ **Tested restore (RTO)** — the extract→recreate→restore→boot round-trip was validated live
  (file **and** dotfile state). ⚠️ make it a **scheduled restore drill** (roadmap).
- ⚠️ **3-2-1 (offsite)** — all backups are currently **local-only**; a disk/VM loss takes them all.
  Push checkpoints + identity backups to a remote (S3/B2/another host) → roadmap.

## Layer 4 — Verify & observe (so you *know* it works)
- ✅ **Integrity-check before trusting** — identity backups run `PRAGMA integrity_check` and write an
  `INVALID` sentinel on failure; checkpoint verifies the image via `docker image inspect`.
- ✅ **Monitor + alert** — doctor checks (39 storm, 43 watchdog-alert), the launchd watchdog, and the
  lifecycle event log → Phoenix/OTLP via `bin/fleet-trace.sh export-otlp`.
- ✅ **Lifecycle audit log** — every checkpoint/extract/restore/storm/halt event is appended to
  `installer/state/fleet-lifecycle.jsonl` (canonical logger: `installer/lib/fleet-events.sh`).

---

## Status at a glance

| Capability | State |
|---|---|
| CPU/mem caps on sandboxes | ✅ shipped |
| `restart=no` (no storm resurrection) | ✅ shipped |
| Checkpoint-before-delete, fail-closed (all 4 sites) | ✅ shipped |
| Tested extract→restore round-trip | ✅ validated |
| Gateway identity-plane backup + regen guard | ✅ shipped |
| `reset` aborts on unverified backup + named-volume backup | ✅ shipped |
| Watchdog HALT-by-default + checkpoint on recreate | ✅ shipped |
| Lifecycle tracing + changelog mechanism | ✅ shipped |
| **Periodic checkpoint timer (bounded RPO)** | ⚠️ roadmap |
| **Offsite/remote backups (3-2-1)** | ⚠️ roadmap |
| **Real persistent volume for `/sandbox` (RPO→0)** | ⚠️ roadmap (needs custom image/upstream) |
| **DB-native backups for service volumes + scheduled restore drills** | ⚠️ roadmap |
| **Host-side token re-mint (avoid recreate entirely)** | ⚠️ experimental — live-mint disabled pending security review |

---

## Operator runbook

```bash
# Snapshot a sandbox before anything risky (verified docker commit; fail-closed)
bash bin/openshell-checkpoint.sh <name> [reason]      # e.g. hermes-fleet-v1 manual
bash bin/openshell-checkpoint.sh list <name>          # list checkpoints

# Reclaim state WITHOUT recreate (works on stopped containers + checkpoint images)
bash bin/openshell-state-restore.sh extract <name|image-ref> <dest>
bash bin/openshell-state-restore.sh verify  <dest>    # assert artifacts present/readable
bash bin/openshell-state-restore.sh into    <name> <src>   # restore into a fresh sandbox

# Protect the master key + gateway DB (the SPOF); install the daily timer
bash bin/openshell-identity-backup.sh backup
bash bin/openshell-identity-backup.sh install         # daily launchd timer
bash bin/openshell-identity-backup.sh guard-regen     # exit 0 only if key rotation is safe

# Observe the fleet lifecycle
bash bin/fleet-trace.sh tail | stats | export-otlp

# Changelog mechanism
bash bin/ai-stack-changelog.sh add <type> "<message>"   # types: feat|fix|docs|chore|security|incident
bash bin/ai-stack-changelog.sh render
```

## Environment knobs

| Variable | Default | Effect |
|---|---|---|
| `OPENSHELL_SANDBOX_CPU` | `1.5` | per-sandbox CPU cap (`0` = unlimited) |
| `OPENSHELL_SANDBOX_MEM` | `3Gi` | per-sandbox memory cap (`0` = unlimited) |
| `OPENSHELL_CHECKPOINT_KEEP` | `5` | checkpoints retained per sandbox |
| `AI_STACK_WATCHDOG_HALT` | `1` | watchdog caps+stops a storming sandbox (non-destructive) |
| `AI_STACK_WATCHDOG_RECREATE` | `0` | opt-in auto-recreate (checkpoints first, fail-closed) |
| `AI_STACK_FORCE_WIPE` | `0` | explicit escape to delete/wipe when a backup fails (use deliberately) |
| `OPENSHELL_FORCE_GATEWAY_RESTART` | `0` | allow Tier-3 restart even when other sandboxes are healthy |
| `AI_STACK_CONFIRM_WAL` | `0` | allow the gated, quiesced gateway-DB WAL conversion |

## Golden rules (decision aids)

1. **Never delete/recreate/prune fleet state without a verified checkpoint first.** The tooling
   enforces this (fail-closed) — don't set `AI_STACK_FORCE_WIPE=1` to route around a *failing*
   backup; fix the backup.
2. **During an incident, do NOT run** `docker container prune` / `docker system prune` /
   `brew services restart openshell` before checkpointing — stopped sandbox containers are
   prune-vulnerable (the gateway does **not** put `ai-stack.keep` on the container, only on
   checkpoint *images*).
3. **A backup you've never restored is a hope, not a backup** — keep the round-trip drill green.
4. **`cp` is not a backup for a live database** — use `.backup` / `pg_dump` / `BGSAVE` / snapshot API.
5. **The gateway DB + signing key are the master SPOF** — back them up before any reset or key op;
   never regenerate the key while tokens are outstanding.

## References
- Incident + remediation record: [`doc/specs/2026-06-08-fleet-durability-hardening.md`](specs/2026-06-08-fleet-durability-hardening.md)
- Code: `bin/openshell-{checkpoint,state-restore,identity-backup,token-refresh,watchdog}.sh`,
  `bin/{fleet-trace,ai-stack-changelog}.sh`, `installer/lib/{openshell,reset,fleet,fleet-events}.sh`,
  `installer/doctor/checks/{39_openshell_storm,43_watchdog_alert}.sh`
- Doctor: checks 39 (storm) + 43 (watchdog alert) — see [`doc/DOCTOR.md`](DOCTOR.md)
