# Vendored MemPalace hook scripts

These two scripts are copied **verbatim** from upstream MemPalace so the stack
controls the exact version Claude Code executes (no surprise drift on `uv tool
upgrade`).

| Field | Value |
|---|---|
| Upstream | https://github.com/MemPalace/mempalace |
| Branch | develop |
| Commit | 02b8753d9759e7c17eca58ba5162e5d2a39ca3d2 |
| Vendored on | (see git history of this dir) |
| Files | hooks/mempal_save_hook.sh, hooks/mempal_precompact_hook.sh |

They are NOT wired into Claude Code by `install 26`. Opt in explicitly and
reversibly with: `bin/mempalace-hooks install --apply` (writes a backed-up
settings.local.json block) / `bin/mempalace-hooks uninstall`.

The hooks call bare `mempalace mine …`; the stack invokes them through
`bin/mempalace-hook-{save,precompact}` launchers that fix PATH (~/.local/bin)
and inject the LiteLLM + on-device-embedding env (key read from .env at
runtime — never embedded here).

To refresh: re-copy from a newer upstream checkout and update the commit above.
