# discord-video-unlock

Re-enables camera / screen share / Go Live for Discord accounts restricted in Brazil, automatically.

**Install page (pt-BR, one click / one command): https://jonasbpa.github.io/discord-video-unlock/**

## Quick start

**Windows app**: open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/jonasbpa/discord-video-unlock/main/install.ps1 | iex
```

No admin needed. Discord restarts unlocked and stays unlocked on every launch after that. Run the
same command again to update. To uninstall:

```powershell
irm https://raw.githubusercontent.com/jonasbpa/discord-video-unlock/main/uninstall.ps1 | iex
```

> **Risk.** The restriction comes from an ANPD order, and getting around it violates Discord's Terms of
> Service; accounts can be suspended. The Windows variant uses a free public proxy by default: it sees
> which hosts you connect to (not the TLS content) and it affects **all** of Windows' HTTP traffic for
> the few seconds it is on. Prefer a proxy you control.

Based on the findings in
[guilhermedecastrogt/unlock-screen-discord-brasil](https://github.com/guilhermedecastrogt/unlock-screen-discord-brasil).

## Windows

### What the one-liner does

`install.ps1` (repo root) downloads the repo zip, copies `desktop/` to
`%LOCALAPPDATA%\DiscordVideoUnlock\app` (stopping an older watcher first when updating) and runs
`desktop/install.ps1`, which:

- registers `HKCU\...\Run\DiscordVideoUnlock`: the watcher, run through `conhost --headless` (no
  window), with `-Takeover`;
- starts the watcher now with `-Takeover -Launch`, so a running Discord is restarted through the bypass
  and a closed one is opened.

Set `DVU_REF` to a branch or tag to install something other than `main`.

### How the watcher works

Discord decides the restriction while it boots, from the IP it sees. The watcher polls for new
Discord main processes every 500 ms and:

1. **Still booting** (splash / update check): saves your proxy settings, turns the system proxy on.
2. **Already booted** (detected too late): kills Discord and starts it again with the proxy on, keeping
   `--start-inactive` if it had it.
3. Waits until the main window exists (hidden windows included), plus `settleSeconds`.
4. Restores your previous proxy settings and shows a toast.

Discord's own "Open Discord" autostart can stay on: at logon the watcher either catches it on the
splash or, with `-Takeover`, restarts it if it already booted.

The backup of your settings lives in `%LOCALAPPDATA%\DiscordVideoUnlock\proxy-backup.json` until the
restore succeeds, so a crash or kill mid-boot is undone the next time the watcher starts, on update or
on uninstall.

Install location is detected automatically: both `%LOCALAPPDATA%\<Build>` and the machine-wide
`%ProgramData%\<user>\<Build>` are checked, and the newest `app-*` wins. Stable, PTB and Canary are
watched.

### Configuration (`%LOCALAPPDATA%\DiscordVideoUnlock\app\config.json`)

| Key | Default | Meaning |
|---|---|---|
| `proxyServer` | `181.39.25.196:8118` | `host:port`; any `ProxyServer` syntax Windows accepts |
| `builds` | all three | Builds to watch |
| `pollIntervalMs` | `500` | Process polling interval |
| `readyTimeoutSeconds` | `120` | Give up and restore the proxy after this |
| `settleSeconds` | `3` | Extra time with the proxy on after the main window appears |
| `toast` | on, pt-BR | Notification after a successful boot |

Updating with the one-liner replaces this file. After editing it, restart the watcher with
`powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\DiscordVideoUnlock\app\install.ps1"`.

### Limits

- `Ctrl+R` and reconnects that re-identify reach Discord from your real IP and can bring the restriction
  back. Fully quit Discord (tray → Quit) and open it again.
- If the public proxy is down, Discord boots restricted. Check
  `%LOCALAPPDATA%\DiscordVideoUnlock\watcher.log` and change `proxyServer`.
- Proxy left on after something went really wrong: **Settings → Network & Internet → Proxy → Manual
  proxy setup → Off**.

### Anti-cheat

The watcher only reads the process list, enumerates Discord's windows and writes your user's proxy
settings. It does not touch game or Discord memory, inject anything or install drivers, and it ships no
binaries.

---

## Development

```powershell
# desktop: parses every script, tests proxy backup/restore on a throwaway registry key, checks detection
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\tests\smoke.ps1

```

This never touches your real proxy settings, Discord process or account. Running from a checkout instead of
the one-liner: `powershell -ExecutionPolicy Bypass -File desktop\install.ps1`.

The install page is `index.html` at the repo root, served by GitHub Pages from `main` (`.nojekyll`
keeps the files served as-is).

## License

MIT
