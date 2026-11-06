<#
.SYNOPSIS
    Background watcher: every time Discord starts, holds the system proxy on until it has booted.

.PARAMETER AtLogon
    Set by the logon entry. Launches Discord through the bypass when config.launchAtLogon is true.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'),
    [switch]$AtLogon
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DiscordVideoUnlock.psm1') -Force

$mutex = New-Object System.Threading.Mutex($false, 'Local\DiscordVideoUnlockWatcher')
if (-not $mutex.WaitOne(0)) {
    Write-DvuLog 'watcher already running, exiting'
    return
}

try {
    $config = Get-DvuConfig -Path $ConfigPath
    Write-DvuLog "watcher started (pid=$PID, atLogon=$AtLogon)"

    if (Restore-BootProxy) { Write-DvuLog 'restored proxy settings left behind by a previous run' }

    # Every Discord pid already handled (main + children). A pid outside this set triggers the
    # more expensive parent lookup.
    $known = @{}
    $markKnown = {
        $known.Clear()
        foreach ($id in (Get-DiscordPids -Builds $config.builds)) { $known[$id] = $true }
    }

    $running = @(Get-DiscordMainProcesses -Builds $config.builds)
    if ($running.Count) {
        # Started before us (e.g. Discord's own autostart won the race). If it is still on the
        # splash we can catch it; otherwise it booted without the proxy and must be restarted.
        foreach ($m in $running) {
            if (Test-DiscordReady -ProcessId $m.ProcessId) {
                if ($AtLogon) {
                    $inactive = $m.CommandLine -match '--start-(inactive|minimized)'
                    [void](Invoke-Bypass -Config $config -Build $m.Build -Mode Relaunch -Inactive:$inactive)
                } else {
                    Write-DvuLog "[$($m.Build)] already running at watcher start, left alone"
                }
            } else {
                [void](Invoke-Bypass -Config $config -Build $m.Build -Mode Attach)
            }
        }
    } elseif ($AtLogon -and $config.launchAtLogon) {
        [void](Invoke-Bypass -Config $config -Build $config.launchBuild -Mode Launch -Inactive:([bool]$config.startInactive))
    }
    & $markKnown

    while ($true) {
        Start-Sleep -Milliseconds $config.pollIntervalMs

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
