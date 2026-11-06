Set-StrictMode -Version 2.0

$script:InternetSettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:StateDir = Join-Path $env:LOCALAPPDATA 'DiscordVideoUnlock'
$script:LogPath = Join-Path $script:StateDir 'watcher.log'
$script:BackupPath = Join-Path $script:StateDir 'proxy-backup.json'
$script:LogMaxBytes = 1MB

# Hidden windows are invisible to Process.MainWindowTitle, and Discord started with
# --start-inactive keeps its main window hidden, so windows are enumerated directly.
if (-not ('DiscordVideoUnlock.Win32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

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

    Write-DvuLog "[$Build] bypass start (mode=$Mode, proxy=$($Config.proxyServer))"
    $result = 'error'
    try {
        Enable-BootProxy -ProxyServer $Config.proxyServer
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
    Resolve-DiscordInstall, Get-DiscordPids, Get-DiscordMainProcesses, Test-DiscordReady, Wait-DiscordReady,
    Start-Discord, Stop-DiscordBuild, Show-DvuToast, Invoke-Bypass
