# CLAUDE.md

Archived on 2026-11-06: Discord added a server-side block, so this no longer works (see README.md). It
re-enabled Discord's video features restricted in Brazil by logging in through a proxy outside Brazil.

## Layout

- `install.ps1` / `uninstall.ps1` (root) - `irm ... | iex` bootstraps for end users. They download the
  repo zip into `%LOCALAPPDATA%\DiscordVideoUnlock\app` and call the `desktop/` scripts with
  `powershell -ExecutionPolicy Bypass -File` (the default policy blocks calling them directly).
- `index.html` + `.nojekyll` - pt-BR install page on GitHub Pages (from `main`, root).
- `desktop/` - Windows, PowerShell 5.1. Boots Discord behind a system proxy outside Brazil, then
  restores the user's proxy settings.
  - `src/DiscordVideoUnlock.psm1` - all logic (proxy backup/restore, install discovery, process and
    window detection, `Stop-DvuWatcher`, `Invoke-Bypass`).
  - `src/watcher.ps1` - single-instance polling loop. `-Takeover` restarts an already booted Discord
    (logon + install), `-Launch` opens it if closed (install only).
  - `install.ps1` / `uninstall.ps1` - HKCU Run entry via `conhost --headless`; replace/stop watcher.
  - `config.json` - provider URLs or own proxy, builds, timings, toast text.
- `extension/` - MV3 browser extension, no dependencies, no build step. Bump `version` in `manifest.json`
  on every change.
  - `lib.js` - pure: providers, ranking, PAC, URL checks.
  - `controller.js` - login state machine with injected browser APIs (tested in `tests/`).
  - `background.js` - wires `controller.js` to the browser, including the Firefox `proxy.onRequest` path.
  - `popup.html` / `popup.js` - pt-BR status and settings.

## Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\tests\smoke.ps1
node --test "tests/*.test.mjs"   # Node 24 needs a glob, not a folder
```

Run both before committing. Neither may touch the real proxy settings, Discord or an account.

## Rules

- Target Windows PowerShell 5.1 (built in), not pwsh 7. No external modules, no compiled binaries.
- Keep `desktop/` `.ps1`/`.psm1` ASCII-only: 5.1 reads BOM-less UTF-8 as ANSI. Non-ASCII text goes in
  `config.json`, read with `Get-Content -Encoding UTF8`. Exception: the root bootstraps, which arrive
  via `irm` (decoded as UTF-8) and print pt-BR. Never add a BOM to them (breaks `iex`).
- Root bootstraps must stay self-contained (no dot-sourcing, no params) and wrap everything in `& { }`
  so `iex` does not leak variables into the user's session.
- User-facing strings (toast, bootstrap output, install page) are pt-BR; code,
  comments, docs and commits are English. `desktop/` scripts only use `Write-Verbose`.
- Never write to the real `Internet Settings` key in tests; module functions take `-KeyPath` and
  `-BackupPath` for that.
- Desktop must never leave the proxy on: every enable goes through `Invoke-Bypass`'s `finally`, and an
  existing backup file is never overwritten (it is the only copy of the user's settings after a crash).
- Clients fetch proxies directly from public providers. Do not add a server or a CI job that builds a list.
- Provider data is untrusted. Only validated public `ip:port` values may reach a PAC or the registry
  (`extension/lib.js`, `ConvertFrom-DvuProxyText`). Private addresses must never be probed.
- Desktop provider downloads and scans never run while the proxy is on.
- The extension must never leave the proxy on: every path out of `arm` ends in `disarm`, with an alarm as a
  backstop, and browser start clears it. The PAC has no `DIRECT` fallback for Discord hosts.

## Gotchas

- High voice ping after a proxied login is usually region, not the proxy path: with a channel's region on
  automatic, Discord picks a voice server near the proxy's location.
- `wss://remote-auth-gateway.discord.gg` is the QR login socket, not the gateway; `isGatewayUrl` excludes it.
- `discord.com/cdn-cgi/trace` answers 403; the country check uses `www.cloudflare.com`.

- The active install may be `%ProgramData%\<user>\Discord` with a stale copy in `%LOCALAPPDATA%`;
  `Resolve-DiscordInstall` picks the newest `app-*`.
- Discord autostart uses `--start-inactive`: the main window is hidden, so readiness uses
  `EnumWindows` (class `Chrome_WidgetWin_1`), not `MainWindowTitle`. The splash title is
  `Discord Updater` and must not count as ready.
- Discord rewrites its own HKCU Run entry on every launch; do not try to hijack it. The watcher
  coexists with it instead (`-Takeover` at logon).
- A watcher killed by `Stop-DvuWatcher` abandons its mutex; the next one gets
  `AbandonedMutexException` from `WaitOne` and must treat it as acquired.
- PowerShell `-f` binds tighter than `+`; parenthesize concatenated format strings.
