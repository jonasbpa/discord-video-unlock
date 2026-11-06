# CLAUDE.md

Re-enables Discord's video features restricted in Brazil (`2026-08-video-guard`). Two independent
variants; see README.md for user-facing docs.

## Layout

- `desktop/` - Windows, PowerShell 5.1. Boots Discord behind a system proxy outside Brazil, then
  restores the user's proxy settings.
  - `src/DiscordVideoUnlock.psm1` - all logic (proxy backup/restore, install discovery, process and
    window detection, `Invoke-Bypass`).
  - `src/watcher.ps1` - single-instance polling loop; `-AtLogon` launches Discord per config.
  - `install.ps1` / `uninstall.ps1` - HKCU Run entry via `conhost --headless`.
  - `config.json` - proxy, builds, timings, toast text.
- `browser/` - userscript applying the experiment override through webpack's require, re-applied on
  every `CONNECTION_OPEN`.

## Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\tests\smoke.ps1
node --test "browser/tests/*.test.mjs"   # Node 24 needs a glob, not a folder
```

Run both before committing. Neither may touch the real proxy settings, Discord or an account.

## Rules

- Target Windows PowerShell 5.1 (built in), not pwsh 7. No external modules, no compiled binaries.
- Keep `.ps1`/`.psm1` ASCII-only: 5.1 reads BOM-less UTF-8 as ANSI. Non-ASCII text goes in
  `config.json`, read with `Get-Content -Encoding UTF8`.
- User-facing strings (toast) are pt-BR; code, comments, docs and commits are English.
- Never write to the real `Internet Settings` key in tests; module functions take `-KeyPath` and
  `-BackupPath` for that.
- Desktop must never leave the proxy on: every enable goes through `Invoke-Bypass`'s `finally`, and an
  existing backup file is never overwritten (it is the only copy of the user's settings after a crash).
- No runtime dependencies for the userscript (`@grant none`, page realm).

## Gotchas

- The active install may be `%ProgramData%\<user>\Discord` with a stale copy in `%LOCALAPPDATA%`;
  `Resolve-DiscordInstall` picks the newest `app-*`.
- Discord autostart uses `--start-inactive`: the main window is hidden, so readiness uses
  `EnumWindows` (class `Chrome_WidgetWin_1`), not `MainWindowTitle`. The splash title is
  `Discord Updater` and must not count as ready.
- Discord rewrites its own HKCU Run entry on every launch; do not try to hijack it.
- PowerShell `-f` binds tighter than `+`; parenthesize concatenated format strings.
- Flux refuses a dispatch inside another dispatch; the userscript defers with `setTimeout`.
- Objects from `vm.runInNewContext` have another `Object.prototype`; spread them before `deepEqual`.
- If Discord renames the experiment, update `EXPERIMENT` in the userscript and the README.
