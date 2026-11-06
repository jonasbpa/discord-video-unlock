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

**Browser (discord.com)**: load the extension in `extension/`, as described in [Browser](#browser).

> **Risk.** The restriction comes from an ANPD order, and getting around it violates Discord's Terms of
> Service; accounts can be suspended. Proxies come from public free lists and no list can make them
> trustworthy: an operator sees your IP and which hosts you connect to (not the TLS content) and may log
> it. Their IPs may also trigger captcha or phone checks. While the proxy is on, the Windows variant sends
> **all** of Windows' HTTP traffic through it for a few seconds. The extension only sends Discord's, during
> login. Prefer a proxy you control.

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

`extension/` is a Manifest V3 extension with no dependencies. It is not in any store yet, so it is loaded
unpacked: enable developer mode in `edge://extensions`, choose **Load unpacked** and select the folder.
Tested on Edge. It also has a Firefox code path (`proxy.onRequest`) that has not been tested.

### How it works

1. **Opening Discord** (`/app`, `/channels`, `/login`...) turns the proxy on through a PAC that only routes
   `discord.com`, `discord.gg`, `discordapp.com` and the country check host. Voice, CDN and every other site
   stay direct.
2. **A chain of up to 8 proxies** is applied, so the browser skips dead ones by itself. The chain is checked
   with anonymous requests: `discord.com/api/v9/gateway` must answer over valid TLS and Cloudflare's trace
   must report an exit outside Brazil. If it fails, the next batch is tried, up to 12.
3. **The gateway handshake** (`101` on `wss://gateway*.discord.gg`) starts a 10-second timer, then the proxy
   goes off and the icon shows `ok`.

A working chain is saved for the next load, and one is searched for in advance when the browser starts.
Proxies come straight from ProxyScrape and proxifly, downloaded in your browser and refreshed every 3 hours.
Reliable ones come first, then the nearest countries. If nothing works, the proxy goes off and the icon shows
`x`. A 2-minute alarm turns it off if anything else goes wrong.

| Icon | Meaning |
|---|---|
| `...` | Logging in through the proxy |
| `ok` | Unlocked, proxy off |
| `x` | No proxy worked |
| `F5` | Discord reconnected from your real IP: reload the page |
| `off` | Disabled in the popup |

The popup can also set your own proxy (`ip:port`).

### Limits

- Logging in on an open `/login` page can take longer than the 2-minute alarm. Reload after logging in.
- With a channel's region on automatic, Discord can pick a voice server near the proxy, which means high
  ping. Set **Region Override** to Brazil in the channel settings.
- Only one extension can control the proxy. The popup warns if another one, such as FoxyProxy, holds it.

---

## Development

```powershell
# desktop: parses every script, tests proxy backup/restore on a throwaway registry key, the provider list
# handling against local fake servers, and detection
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\tests\smoke.ps1

# extension: proxy selection and the login state machine, with no network access (Node 22+)
node --test "tests/*.test.mjs"

```

Neither touches your real proxy settings, Discord process or account. Running from a checkout instead of
the one-liner: `powershell -ExecutionPolicy Bypass -File desktop\install.ps1`.

The install page is `index.html` at the repo root, served by GitHub Pages from `main` (`.nojekyll`
keeps the files served as-is).

## License

MIT
