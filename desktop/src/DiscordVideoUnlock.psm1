Set-StrictMode -Version 2.0

$script:InternetSettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'DiscordVideoUnlock'
$script:LogPath = Join-Path $script:StateDir 'watcher.log'
$script:BackupPath = Join-Path $script:StateDir 'proxy-backup.json'
$script:ProxyCachePath = Join-Path $script:StateDir 'proxies-cache.txt'
$script:LogMaxBytes = 1MB

# Hidden windows are invisible to Process.MainWindowTitle, and Discord started with
# --start-inactive keeps its main window hidden, so windows are enumerated directly.
if (-not ('DiscordVideoUnlock.Win32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace DiscordVideoUnlock {
    public static class Win32 {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);

        public static string[] GetWindowTitles(uint pid, string className) {
            var titles = new List<string>();
            EnumWindows((h, l) => {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                if (owner == pid) {
                    var cls = new StringBuilder(256);
                    GetClassName(h, cls, cls.Capacity);
                    if (cls.ToString() == className) {
                        var title = new StringBuilder(512);
                        GetWindowText(h, title, title.Capacity);
                        titles.Add(title.ToString());
                    }
                }
                return true;
            }, IntPtr.Zero);
            return titles.ToArray();
        }
    }

    // Everything runs concurrently: Discord may already be on its splash screen, and most free
    // proxies are dead, so testing them one by one would take minutes.
    public static class ProxyProbe {
        // Fast check used at boot, on proxies that passed Verify earlier.
        public static string FirstWorking(string[] proxies, string host, int timeoutMs) {
            var pending = new List<Task<string>>();
            foreach (var proxy in proxies) pending.Add(Probe(proxy, host, timeoutMs));
            var started = DateTime.UtcNow;
            while (pending.Count > 0) {
                var left = timeoutMs + 250 - (int)(DateTime.UtcNow - started).TotalMilliseconds;
                if (left <= 0) return null;
                var tasks = pending.ToArray();
                var i = Task.WaitAny(tasks, left);
                if (i < 0) return null;
                if (tasks[i].Result != null) return tasks[i].Result;
                pending.RemoveAt(i);
            }
            return null;
        }

        // Full check of provider candidates. Stops as soon as enough proxies pass.
        public static string[] FindVerified(string[] candidates, int want, int concurrency, int timeoutMs, int deadlineMs) {
            var found = new List<string>();
            var running = new List<Task<string>>();
            var next = 0;
            var started = DateTime.UtcNow;
            while (found.Count < want && (next < candidates.Length || running.Count > 0)) {
                var left = deadlineMs - (int)(DateTime.UtcNow - started).TotalMilliseconds;
                if (left <= 0) break;
                while (running.Count < concurrency && next < candidates.Length) running.Add(Verify(candidates[next++], timeoutMs));
                var tasks = running.ToArray();
                var i = Task.WaitAny(tasks, left);
                if (i < 0) break;
                if (tasks[i].Result != null) found.Add(tasks[i].Result);
                running.RemoveAt(i);
            }
            return found.ToArray();
        }

        // Discord must accept the exit IP (blocked proxies get a 403 or 429) and the exit must not be
        // in Brazil. TLS validation rejects proxies that intercept traffic. Requests are anonymous.
        private static async Task<string> Verify(string proxy, int timeoutMs) {
            var api = await Get(proxy, "discord.com", "/api/v9/gateway", timeoutMs);
            if (api == null || !IsOk(api) || !api.Contains("gateway.discord.gg")) return null;
            // discord.com answers 403 on /cdn-cgi/trace. Same Cloudflare geolocation, different zone.
            var trace = await Get(proxy, "www.cloudflare.com", "/cdn-cgi/trace", timeoutMs);
            if (trace == null) return null;
            var loc = Regex.Match(trace, "(?m)^loc=([A-Z0-9]{2})\\s*$");
            return loc.Success && loc.Groups[1].Value != "BR" ? proxy : null;
        }

        private static bool IsOk(string head) {
            return head.StartsWith("HTTP/1.1 200") || head.StartsWith("HTTP/1.0 200");
        }

        private static async Task<string> Probe(string proxy, string host, int timeoutMs) {
            var client = new TcpClient();
            try {
                var work = OpenTunnel(client, proxy, host);
                if (await Task.WhenAny(work, Task.Delay(timeoutMs)) != work) return null;
                return await work ? proxy : null;
            } catch (Exception) {
                return null;
            } finally {
                client.Close();
            }
        }

        private static async Task<string> Get(string proxy, string host, string path, int timeoutMs) {
            var client = new TcpClient();
            try {
                var work = GetThroughTunnel(client, proxy, host, path);
                if (await Task.WhenAny(work, Task.Delay(timeoutMs)) != work) return null;
                return await work;
            } catch (Exception) {
                return null;
            } finally {
                client.Close();
            }
        }

        private static async Task<bool> OpenTunnel(TcpClient client, string proxy, string host) {
            var sep = proxy.LastIndexOf(':');
            await client.ConnectAsync(proxy.Substring(0, sep), int.Parse(proxy.Substring(sep + 1)));
            var stream = client.GetStream();
            var request = Encoding.ASCII.GetBytes("CONNECT " + host + ":443 HTTP/1.1\r\nHost: " + host + ":443\r\n\r\n");
            await stream.WriteAsync(request, 0, request.Length);
            // One byte at a time: anything read past the header would belong to the TLS handshake.
            var head = new StringBuilder();
            var one = new byte[1];
            while (head.Length < 8192) {
                if (await stream.ReadAsync(one, 0, 1) == 0) return false;
                head.Append((char)one[0]);
                if (one[0] == 10 && head.ToString().EndsWith("\r\n\r\n")) return IsOk(head.ToString());
            }
            return false;
        }

        private static async Task<string> GetThroughTunnel(TcpClient client, string proxy, string host, string path) {
            if (!await OpenTunnel(client, proxy, host)) return null;
            using (var tls = new SslStream(client.GetStream())) {
                await tls.AuthenticateAsClientAsync(host, null, SslProtocols.Tls12, false);
                var request = Encoding.ASCII.GetBytes("GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n");
                await tls.WriteAsync(request, 0, request.Length);
                var body = new StringBuilder();
                var buffer = new byte[4096];
                while (body.Length < 65536) {
                    var n = await tls.ReadAsync(buffer, 0, buffer.Length);
                    if (n == 0) break;
                    body.Append(Encoding.ASCII.GetString(buffer, 0, n));
                }
                return body.ToString();
            }
        }
    }
}
'@
}

function Write-DvuLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Path = $script:LogPath)
    try {
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $script:LogMaxBytes) {
            Move-Item -Force $Path "$Path.old"
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        Add-Content -Path $Path -Value $line -Encoding UTF8
        Write-Verbose $line
    } catch { }
}

function Get-DvuConfig {
    param([Parameter(Mandatory)][string]$Path)
    # -Encoding UTF8 is required on PowerShell 5.1 for the non-ASCII toast strings.
    Get-Content -Raw -Encoding UTF8 -Path $Path | ConvertFrom-Json
}

# ---------------------------------------------------------------- proxy

function Get-ProxySnapshot {
    param([string]$KeyPath = $script:InternetSettingsKey)
    $props = Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue
    $snap = [ordered]@{}
    foreach ($name in 'ProxyEnable', 'ProxyServer') {
        $hasValue = $props -and ($props.PSObject.Properties.Name -contains $name)
        $snap[$name] = if ($hasValue) { $props.$name } else { $null }
    }
    [pscustomobject]$snap
}

function Set-ProxyValue {
    param([string]$KeyPath, [string]$Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    if ($null -eq $Value) {
        Remove-ItemProperty -Path $KeyPath -Name $Name -ErrorAction SilentlyContinue
    } else {
        New-ItemProperty -Path $KeyPath -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
    }
}

function Enable-BootProxy {
    param(
        [Parameter(Mandatory)][string]$ProxyServer,
        [string]$KeyPath = $script:InternetSettingsKey,
        [string]$BackupPath = $script:BackupPath
    )
    # An existing backup means a previous run died mid-bypass: the registry currently holds
    # OUR proxy, so the backup on disk is the only copy of the user's real settings. Keep it.
    if (-not (Test-Path $BackupPath)) {
        $dir = Split-Path $BackupPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        Get-ProxySnapshot -KeyPath $KeyPath | ConvertTo-Json | Set-Content -Path $BackupPath -Encoding UTF8
    }
    Set-ProxyValue -KeyPath $KeyPath -Name 'ProxyServer' -Value $ProxyServer -Kind String
    Set-ProxyValue -KeyPath $KeyPath -Name 'ProxyEnable' -Value 1 -Kind DWord
}

function Restore-BootProxy {
    param(
        [string]$KeyPath = $script:InternetSettingsKey,
        [string]$BackupPath = $script:BackupPath
    )
    if (-not (Test-Path $BackupPath)) { return $false }
    $snap = Get-Content -Raw -Encoding UTF8 -Path $BackupPath | ConvertFrom-Json
    Set-ProxyValue -KeyPath $KeyPath -Name 'ProxyServer' -Value $snap.ProxyServer -Kind String
    Set-ProxyValue -KeyPath $KeyPath -Name 'ProxyEnable' -Value $snap.ProxyEnable -Kind DWord
    Remove-Item -Force $BackupPath
    $true
}

# ---------------------------------------------------------------- proxy list

function ConvertFrom-DvuProxyText {
    # Provider data is untrusted and ends up in the registry, and a private address here would make
    # the probes scan the user's own network. Only public ip:port values get through.
    param([AllowEmptyString()][string]$Text)
    $seen = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^(?:https?://)?(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3}):(\d{1,5})\s*$')) {
        $o = 1..4 | ForEach-Object { [int]$m.Groups[$_].Value }
        $port = [int]$m.Groups[5].Value
        if (($o | Where-Object { $_ -gt 255 }) -or $port -lt 1 -or $port -gt 65535) { continue }
        $a = $o[0]; $b = $o[1]
        if ($a -eq 0 -or $a -eq 10 -or $a -eq 127 -or $a -ge 224) { continue }
        if ($a -eq 100 -and $b -ge 64 -and $b -le 127) { continue }
        if ($a -eq 169 -and $b -eq 254) { continue }
        if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { continue }
        if ($a -eq 192 -and ($b -eq 0 -or $b -eq 168)) { continue }
        if ($a -eq 198 -and ($b -eq 18 -or $b -eq 19)) { continue }
        $server = '{0}.{1}.{2}.{3}:{4}' -f $o[0], $o[1], $o[2], $o[3], $port
        if (-not $seen.ContainsKey($server)) { $seen[$server] = $true; $server }
    }
}

function Get-DvuProviderProxies {
    param([Parameter(Mandatory)]$Config)
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $all = foreach ($url in $Config.proxyProviders) {
        try {
            $content = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec $Config.proxyDownloadTimeoutSeconds).Content
            if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
            ConvertFrom-DvuProxyText -Text $content
        } catch {
            Write-DvuLog "proxy provider failed ($url): $($_.Exception.Message)"
        }
    }
    @($all | Select-Object -Unique | Sort-Object { Get-Random })
}

function Update-DvuProxyCache {
    <#
      Downloads the provider lists and caches the proxies that pass a full check. A failed run keeps
      the previous cache. -Verify exists so tests stay off the network.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$CachePath = $script:ProxyCachePath,
        [scriptblock]$Verify = {
            param([string[]]$Candidates, $Config)
            [DiscordVideoUnlock.ProxyProbe]::FindVerified($Candidates, 10, 100, 8000, $Config.proxyScanSeconds * 1000)
        }
    )
    try {
        $candidates = @(Get-DvuProviderProxies -Config $Config)
        if (-not $candidates.Count) { throw 'no candidates from any provider' }
        $working = @(& $Verify $candidates $Config)
        Write-DvuLog "proxy scan: $($working.Count) working out of $($candidates.Count) candidates"
        if (-not $working.Count) { return $false }
        $dir = Split-Path $CachePath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $tmp = "$CachePath.tmp"
        [IO.File]::WriteAllLines($tmp, [string[]]$working)
        Move-Item -Force $tmp $CachePath
        $true
    } catch {
        Write-DvuLog "proxy list update failed: $($_.Exception.Message)"
        $false
    }
}

function Select-DvuProxy {
    <#
      Returns the proxy to boot through, or $null. A configured proxyServer always wins and is not
      probed, since it may use any syntax Windows accepts. Otherwise cached proxies are tried first:
      a provider scan takes too long to win the race against Discord's splash screen.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$CachePath = $script:ProxyCachePath,
        [scriptblock]$Probe = {
            param([string[]]$Servers, $Config)
            [DiscordVideoUnlock.ProxyProbe]::FirstWorking($Servers, 'discord.com', $Config.proxyProbeTimeoutMs)
        },
        [scriptblock]$Verify
    )
    if ($Config.proxyServer) { return $Config.proxyServer }

    $probeCache = {
        if (-not (Test-Path $CachePath)) { return $null }
        $servers = @(ConvertFrom-DvuProxyText -Text ([IO.File]::ReadAllText($CachePath)))
        if (-not $servers.Count) { return $null }
        & $Probe $servers $Config
    }

    $proxy = & $probeCache
    if ($proxy) { return $proxy }
    $update = @{ Config = $Config; CachePath = $CachePath }
    if ($Verify) { $update.Verify = $Verify }
    if (Update-DvuProxyCache @update) { return (& $probeCache) }
    $null
}

# ---------------------------------------------------------------- discord

function Get-AppVersion {
    param([string]$Dir)
    Get-ChildItem -Path $Dir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        ForEach-Object { $v = $null; if ([version]::TryParse($_.Name.Substring(4), [ref]$v)) { $v } } |
        Sort-Object -Descending | Select-Object -First 1
}

function Resolve-DiscordInstall {
    param([Parameter(Mandatory)][string]$Build)
    # Per-user installs live in %LOCALAPPDATA%; the machine-wide installer puts each user's copy
    # in %ProgramData%\<user>. Both can coexist (one stale), so take the newest app-* version.
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA $Build),
        (Join-Path (Join-Path $env:ProgramData $env:USERNAME) $Build)
    ) | Where-Object { Test-Path (Join-Path $_ 'Update.exe') }

    $best = $candidates |
        ForEach-Object { [pscustomobject]@{ Dir = $_; Version = Get-AppVersion $_ } } |
        Where-Object { $_.Version } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $best) { return $null }

    [pscustomobject]@{
        Build     = $Build
        Dir       = $best.Dir
        Version   = $best.Version
        UpdateExe = Join-Path $best.Dir 'Update.exe'
        ExeName   = "$Build.exe"
    }
}

function Get-DiscordPids {
    param([Parameter(Mandatory)][string[]]$Builds)
    @(Get-Process -Name $Builds -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
}

function Get-DiscordMainProcesses {
    param([Parameter(Mandatory)][string[]]$Builds)
    $filter = ($Builds | ForEach-Object { "Name='$_.exe'" }) -join ' OR '
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue)
    $ids = @{}
    foreach ($p in $procs) { $ids[[int]$p.ProcessId] = $true }
    # Electron children (renderer/gpu/utility) are parented by the main process; the main
    # process is parented by Update.exe, explorer or nothing.
    foreach ($p in $procs) {
        if (-not $ids.ContainsKey([int]$p.ParentProcessId)) {
            [pscustomobject]@{
                ProcessId   = [int]$p.ProcessId
                Build       = [IO.Path]::GetFileNameWithoutExtension($p.Name)
                CommandLine = $p.CommandLine
            }
        }
    }
}

function Test-DiscordReady {
    param([Parameter(Mandatory)][int]$ProcessId)
    $titles = [DiscordVideoUnlock.Win32]::GetWindowTitles([uint32]$ProcessId, 'Chrome_WidgetWin_1')
    [bool]($titles | Where-Object { $_ -match 'Discord' -and $_ -notmatch 'Update|Updater' })
}

function Wait-DiscordReady {
    param(
        [Parameter(Mandatory)][string]$Build,
        [int]$TimeoutSeconds = 120,
        [int]$GoneSeconds = 15,
        [int]$PollMs = 500
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastSeen = Get-Date
    while ((Get-Date) -lt $deadline) {
        $mains = @(Get-DiscordMainProcesses -Builds $Build)
        if ($mains.Count) {
            $lastSeen = Get-Date
            foreach ($m in $mains) {
                if (Test-DiscordReady -ProcessId $m.ProcessId) { return 'ready' }
            }
        } elseif (((Get-Date) - $lastSeen).TotalSeconds -gt $GoneSeconds) {
            # Splash closed or an update restart never came back.
            return 'gone'
        }
        Start-Sleep -Milliseconds $PollMs
    }
    'timeout'
}

function Start-Discord {
    param([Parameter(Mandatory)]$Install, [switch]$Inactive)
    $argList = @('--processStart', $Install.ExeName)
    if ($Inactive) { $argList += @('--process-start-args', '"--start-inactive"') }
    Start-Process -FilePath $Install.UpdateExe -ArgumentList $argList
}

function Stop-DiscordBuild {
    param([Parameter(Mandatory)][string]$Build, [int]$TimeoutSeconds = 15)
    Get-Process -Name $Build -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Process -Name $Build -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
}

function Show-DvuToast {
    param([Parameter(Mandatory)][string]$Build, [string]$Title, [string]$Body)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $app = Get-StartApps -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^$Build" -or $_.AppID -match $Build } | Select-Object -First 1
        $appId = if ($app) { $app.AppID } else { "com.squirrel.$Build.$Build" }
        $tmpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $text = $tmpl.GetElementsByTagName('text')
        [void]$text.Item(0).AppendChild($tmpl.CreateTextNode($Title))
        [void]$text.Item(1).AppendChild($tmpl.CreateTextNode($Body))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tmpl)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-DvuLog "toast failed: $($_.Exception.Message)"
    }
}

function Stop-DvuWatcher {
    # Matches both the installed copy (%LOCALAPPDATA%\DiscordVideoUnlock\app) and a repo checkout.
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)(DiscordVideoUnlock|discord-video-unlock).*\\src\\watcher\.ps1' })
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    # A watcher killed mid-boot leaves the proxy on.
    [void](Restore-BootProxy)
    $procs.Count
}

# ---------------------------------------------------------------- bypass

function Invoke-Bypass {
    <#
      Holds the system proxy on while Discord boots, then restores the user's settings.
      -Mode Attach   : Discord is already booting (splash); only flip the proxy.
      -Mode Launch   : start Discord ourselves.
      -Mode Relaunch : Discord finished booting without the proxy; kill and start it again.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Build,
        [ValidateSet('Attach', 'Launch', 'Relaunch')][string]$Mode = 'Attach',
        [switch]$Inactive
    )
    $install = Resolve-DiscordInstall -Build $Build
    if ($Mode -ne 'Attach' -and -not $install) {
        Write-DvuLog "[$Build] install not found, cannot $Mode"
        return $false
    }

    # Before anything else: with no working proxy, a running Discord must not be killed for nothing.
    $proxy = Select-DvuProxy -Config $Config
    if (-not $proxy) {
        Write-DvuLog "[$Build] no working proxy, Discord stays restricted"
        return $false
    }

    Write-DvuLog "[$Build] bypass start (mode=$Mode, proxy=$proxy)"
    $result = 'error'
    try {
        Enable-BootProxy -ProxyServer $proxy
        if ($Mode -eq 'Relaunch') { Stop-DiscordBuild -Build $Build }
        if ($Mode -ne 'Attach') { Start-Discord -Install $install -Inactive:$Inactive }

        $result = Wait-DiscordReady -Build $Build -TimeoutSeconds $Config.readyTimeoutSeconds -PollMs $Config.pollIntervalMs
        if ($result -eq 'ready') { Start-Sleep -Seconds $Config.settleSeconds }
    } catch {
        Write-DvuLog "[$Build] bypass error: $($_.Exception.Message)"
    } finally {
        [void](Restore-BootProxy)
        Write-DvuLog "[$Build] bypass end (result=$result), proxy restored"
    }

    if ($result -eq 'ready' -and $Config.toast.enabled) {
        Show-DvuToast -Build $Build -Title $Config.toast.title -Body $Config.toast.body
    }
    $result -eq 'ready'
}

Export-ModuleMember -Function Write-DvuLog, Get-DvuConfig, Get-ProxySnapshot, Enable-BootProxy, Restore-BootProxy,
    ConvertFrom-DvuProxyText, Get-DvuProviderProxies, Update-DvuProxyCache, Select-DvuProxy,
    Resolve-DiscordInstall, Get-DiscordPids, Get-DiscordMainProcesses, Test-DiscordReady, Wait-DiscordReady,
    Start-Discord, Stop-DiscordBuild, Show-DvuToast, Stop-DvuWatcher, Invoke-Bypass
