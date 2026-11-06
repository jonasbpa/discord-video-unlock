<#
.SYNOPSIS
    Background watcher: every time Discord starts, holds the system proxy on until it has booted.

.PARAMETER Takeover
    Restart any Discord that already finished booting without the proxy when the watcher starts.
    Used at logon (Discord's own autostart may win the race) and right after install.

.PARAMETER Launch
    Start Discord through the bypass if it is not running. Used right after install.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),
    [switch]$Takeover,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DiscordVideoUnlock.psm1') -Force

$mutex = New-Object System.Threading.Mutex($false, 'Local\DiscordVideoUnlockWatcher')
try {
    $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # Previous watcher was killed (update/uninstall) without releasing it; we own it now.
    $owned = $true
}
if (-not $owned) {
    Write-DvuLog 'watcher already running, exiting'
    return
}

try {
    $config = Get-DvuConfig -Path $ConfigPath
    Write-DvuLog "watcher started (pid=$PID, takeover=$Takeover, launch=$Launch)"

    if (Restore-BootProxy) { Write-DvuLog 'restored proxy settings left behind by a previous run' }

    # Every Discord pid already handled (main + children). A pid outside this set triggers the
    # more expensive parent lookup.
    $known = @{}
    $markKnown = {
        $known.Clear()
        foreach ($id in (Get-DiscordPids -Builds $config.builds)) { $known[$id] = $true }
    }

    $running = @(Get-DiscordMainProcesses -Builds $config.builds)
    foreach ($m in $running) {
        if (-not (Test-DiscordReady -ProcessId $m.ProcessId)) {
            [void](Invoke-Bypass -Config $config -Build $m.Build -Mode Attach)
        } elseif ($Takeover) {
            $inactive = $m.CommandLine -match '--start-(inactive|minimized)'
            [void](Invoke-Bypass -Config $config -Build $m.Build -Mode Relaunch -Inactive:$inactive)
        } else {
            Write-DvuLog "[$($m.Build)] already running at watcher start, left alone"
        }
    }
    if ($Launch -and -not $running.Count) {
        $build = $config.builds | Where-Object { Resolve-DiscordInstall -Build $_ } | Select-Object -First 1
        if ($build) {
            [void](Invoke-Bypass -Config $config -Build $build -Mode Launch)
        } else {
            Write-DvuLog 'no Discord install found to launch'
        }
    }
    & $markKnown

    # Refreshed between boots only: the download must not run while the proxy is on.
    $nextListUpdate = Get-Date

    while ($true) {
        Start-Sleep -Milliseconds $config.pollIntervalMs

        if ((Get-Date) -ge $nextListUpdate) {
            $minutes = if (Update-DvuProxyCache -Config $config) { $config.proxyListRefreshMinutes } else { 5 }
            $nextListUpdate = (Get-Date).AddMinutes($minutes)
        }

        $pids = Get-DiscordPids -Builds $config.builds
        $fresh = @($pids | Where-Object { -not $known.ContainsKey($_) })
        if (-not $fresh.Count) {
            if ($known.Count -ne @($pids).Count) { & $markKnown }  # something exited
            continue
        }

        foreach ($m in (Get-DiscordMainProcesses -Builds $config.builds)) {
            if ($known.ContainsKey($m.ProcessId)) { continue }
            if (Test-DiscordReady -ProcessId $m.ProcessId) {
                # Detected too late: already past the boot, so the proxy would be useless now.
                $inactive = $m.CommandLine -match '--start-(inactive|minimized)'
                Write-DvuLog "[$($m.Build)] pid $($m.ProcessId) already booted, relaunching"
                [void](Invoke-Bypass -Config $config -Build $m.Build -Mode Relaunch -Inactive:$inactive)
            } else {
                Write-DvuLog "[$($m.Build)] new main process pid $($m.ProcessId)"
                [void](Invoke-Bypass -Config $config -Build $m.Build -Mode Attach)
            }
        }
        & $markKnown
    }
} catch {
    Write-DvuLog "watcher crashed: $($_.Exception.Message)"
    [void](Restore-BootProxy)
    throw
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
