# discord-video-unlock

Re-enables camera / screen share / Go Live for Discord accounts restricted in Brazil, automatically,
on every launch. Two independent variants:

| | Desktop (`desktop/`) | Browser (`browser/`) |
|---|---|---|
| Mechanism | System proxy outside Brazil **only while Discord boots** | Client-side experiment override (`2026-08-video-guard` → control bucket) |
| Runs as | Hidden PowerShell watcher started at logon | Userscript (Tampermonkey / Violentmonkey) |
| Covers | Logon autostart, manual open, close & reopen, update restarts | Every page load, reloads and gateway reconnects |
| Does **not** cover | In-app reloads (`Ctrl+R`) and some reconnects | Experiment renames (update the constant) |
| Needs | Windows 10/11, nothing to install | A userscript manager |

Based on the findings in
[guilhermedecastrogt/unlock-screen-discord-brasil](https://github.com/guilhermedecastrogt/unlock-screen-discord-brasil).

> **Risk.** The restriction comes from an ANPD order, and getting around it violates Discord's Terms of
> Service; accounts can be suspended. The default proxy is a free public one: it sees which hosts you
> connect to (not the TLS content) and it affects **all** of Windows' HTTP traffic for the few seconds it
> is on. Prefer a proxy you control.

---

## Desktop (Windows)

### How it works

Discord decides the restriction while it boots, from the IP it sees. The watcher polls for new
Discord main processes every 500 ms and:

1. **Still booting** (splash / update check): saves your proxy settings, turns the system proxy on.
2. **Already booted** (detected too late): kills Discord and starts it again with the proxy on.
3. Waits until the main window exists (hidden windows included, so `--start-inactive` works), plus
   `settleSeconds`.
4. Restores your previous proxy settings and shows a toast.

The backup of your settings lives in `%LOCALAPPDATA%\DiscordVideoUnlock\proxy-backup.json` until the
restore succeeds, so a crash or a kill mid-boot is undone the next time the watcher starts (or by the
uninstaller).

Install location is detected automatically: both `%LOCALAPPDATA%\<Build>` and the machine-wide
`%ProgramData%\<user>\<Build>` are checked, and the newest `app-*` wins. Stable, PTB and Canary are
watched.

### Install

```powershell
powershell -ExecutionPolicy Bypass -File desktop\install.ps1
```

This registers `HKCU\...\Run\DiscordVideoUnlock` (no admin) running the watcher through
`conhost --headless` (no window), and starts it right away.

Then turn off **Discord → User Settings → Windows Settings → Open Discord**. Otherwise Discord's own
autostart races the watcher at logon and usually costs one extra restart. The watcher launches Discord
itself (`launchAtLogon`).

### Configuration (`desktop/config.json`)

| Key | Default | Meaning |
|---|---|---|
| `proxyServer` | `181.39.25.196:8118` | `host:port`; any `ProxyServer` syntax Windows accepts |
| `builds` | all three | Builds to watch |
| `launchAtLogon` | `true` | Start Discord at logon through the bypass |
| `launchBuild` | `Discord` | Which build to start at logon |
| `startInactive` | `true` | Start minimized to tray at logon |
| `pollIntervalMs` | `500` | Process polling interval |
| `readyTimeoutSeconds` | `120` | Give up and restore the proxy after this |
| `settleSeconds` | `3` | Extra time with the proxy on after the main window appears |
| `toast` | on, pt-BR | Notification after a successful boot |

Restart the watcher after editing (run `install.ps1` again, or log off and on).

### Limits

- `Ctrl+R` and reconnects that re-identify reach Discord from your real IP and can bring the restriction
  back. Fully quit Discord (tray → Quit) and open it again.
- If the public proxy is down, Discord boots restricted. Check the log at
  `%LOCALAPPDATA%\DiscordVideoUnlock\watcher.log` and change `proxyServer`.

### Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File desktop\uninstall.ps1
```

Removes the logon entry, stops the watcher and restores any proxy settings left behind. Manual fallback:
**Settings → Network & Internet → Proxy → Manual proxy setup → Off**.

### Anti-cheat

The watcher only reads the process list, enumerates Discord's windows and writes your user's proxy
settings. It does not touch game or Discord memory, inject anything or install drivers, and it ships no
binaries.

---

## Browser (discord.com)

The browser variant does not use a proxy. It applies Discord's own experiment override from the page:

1. Gets webpack's `require` by pushing a fake chunk into `webpackChunkdiscord_app` (no Vencord).
2. Finds the Flux dispatcher among the loaded modules.
3. Dispatches `APEX_EXPERIMENT_SESSION_OVERRIDE_CREATE` for `2026-08-video-guard`, variant `0`, right
   away and after every `CONNECTION_OPEN` (the experiment store is filled after the gateway
   authenticates, which would otherwise overwrite it).

### Install

1. Install [Tampermonkey](https://www.tampermonkey.net/) or [Violentmonkey](https://violentmonkey.github.io/).
   On Chrome/Edge (Manifest V3) also enable **Allow User Scripts** in the extension's details page.
2. Create a new script and paste `browser/discord-video-unlock.user.js`, or open the raw file URL once
   the repo is hosted.
3. Open discord.com. The console shows `[DiscordVideoUnlock] override applied to 2026-08-video-guard`.

If the button is still disabled, leave and rejoin the voice channel (the component was mounted with the
old value).

If the console warns that the experiment was not found, Discord renamed it. Update `EXPERIMENT` in the
script; see the original repo's troubleshooting section for how to find the new name.

---

## Development

```powershell
# desktop: parses every script, tests proxy backup/restore on a throwaway registry key, checks detection
powershell -NoProfile -ExecutionPolicy Bypass -File desktop\tests\smoke.ps1

# browser: runs the userscript against a fake webpack + Flux dispatcher (Node 20+)
node --test "browser/tests/*.test.mjs"
```

Neither touches your real proxy settings, Discord process or account.

## License

MIT
