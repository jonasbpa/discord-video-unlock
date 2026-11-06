# discord-video-unlock

Re-enables camera / screen share / Go Live for Discord accounts restricted in Brazil. Discord decides the
restriction on its servers from the IP it sees at login, so logging in through a proxy outside Brazil and
then turning the proxy off unlocks the session.

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

**Browser (discord.com)**: use [FoxyProxy](https://github.com/foxyproxy/browser-extension) with a proxy
from the install page, as described in [Browser](#browser).

> **Risk.** The restriction comes from an ANPD order, and getting around it violates Discord's Terms of
> Service; accounts can be suspended. Proxies come from public free lists and no list can make them
> trustworthy: an operator sees your IP and which hosts you connect to (not the TLS content) and may log
> it. Their IPs may also trigger captcha or phone checks. While the proxy is on, the Windows variant sends
> **all** of Windows' HTTP traffic through it for a few seconds, and FoxyProxy sends all of the browser's.
> Prefer a proxy you control.

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

Proxies come straight from public providers, downloaded on your PC. Every 3 hours the watcher downloads
the lists in `proxyProviders` and keeps up to 10 proxies that pass a full check, in
`%LOCALAPPDATA%\DiscordVideoUnlock\proxies-cache.txt`, through the proxy and with anonymous requests only:

- `discord.com/api/v9/gateway` answers 200 over validated TLS, which rejects TLS interception and blocked IPs;
- Cloudflare's trace reports an exit country other than Brazil.

These checks cannot tell whether an operator logs traffic. When Discord starts, the cached proxies are
probed at once and the first to answer `CONNECT discord.com:443` is used. If none does, a new scan runs. If
that fails too, Discord is left alone (restricted) and the log says so.

### Configuration (`%LOCALAPPDATA%\DiscordVideoUnlock\app\config.json`)

| Key | Default | Meaning |
|---|---|---|
| `proxyServer` | empty | Your own proxy: `host:port` or any `ProxyServer` syntax Windows accepts. Set it to skip the list |
| `proxyProviders` | ProxyScrape, proxifly | URLs of plain-text lists with one `ip:port` per line |
| `proxyRefreshMinutes` | `180` | Time between scans |
| `proxyDownloadTimeoutSeconds` | `15` | Timeout per provider download |
| `proxyScanSeconds` | `45` | Maximum time for a scan |
| `proxyProbeTimeoutMs` | `3000` | Time allowed for the probe when Discord starts |
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
- If no proxy works, Discord boots restricted. Check `%LOCALAPPDATA%\DiscordVideoUnlock\watcher.log` or
  set `proxyServer`.
- Proxy left on after something went really wrong: **Settings → Network & Internet → Proxy → Manual
  proxy setup → Off**.

### Anti-cheat

The watcher only reads the process list, enumerates Discord's windows and writes your user's proxy
settings. It does not touch game or Discord memory, inject anything or install drivers, and it ships no
binaries.

---

## Browser

A page cannot change the browser's proxy and an installer cannot add an extension, so this variant is
manual, with [FoxyProxy](https://github.com/foxyproxy/browser-extension) (GPL-2.0).

1. On the install page, **Buscar proxy** downloads a list from ProxyScrape (proxifly as fallback) in your
   browser and picks one of the 20 most reliable HTTPS-capable proxies outside Brazil.
2. Add it to FoxyProxy with type **HTTP**.
3. Select it, then open or reload `discord.com/app`.
4. Once Discord has loaded, select **Disable**. Screen sharing does not work while the proxy is on.
5. Reloading the page reaches Discord from your real IP again: repeat from step 3.

A page cannot open raw sockets, so unlike the Windows variant it cannot test the proxy first. If Discord
does not load, get another one.

---

## Development

```powershell
# desktop: parses every script, tests proxy backup/restore on a throwaway registry key, the provider list
# handling against local fake servers, and detection
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\tests\smoke.ps1

# install page proxy picker, with no network access (Node 20+)
node --test "tests/*.test.mjs"

```

Neither touches your real proxy settings, Discord process or account. Running from a checkout instead of
the one-liner: `powershell -ExecutionPolicy Bypass -File desktop\install.ps1`.

The install page is `index.html` at the repo root, served by GitHub Pages from `main` (`.nojekyll`
keeps the files served as-is).

## License

MIT
