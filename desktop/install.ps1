<#
.SYNOPSIS
    Registers the watcher to start hidden at logon (HKCU Run, no admin), replaces any running
    watcher and starts the new one, which (re)starts Discord through the bypass.

.PARAMETER NoStart
    Only register the logon entry.
#>
[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\DiscordVideoUnlock.psm1') -Force

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$watcher = Join-Path $PSScriptRoot 'src\watcher.ps1'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$powershell = Join-Path $PSHOME 'powershell.exe'

# conhost --headless runs the console app with no window at all, even when Windows Terminal is
# the default terminal (where -WindowStyle Hidden still flashes a window).
$watcherArgs = "--headless `"$powershell`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$watcher`" -Takeover"

# At logon Discord's own autostart (if enabled) starts it; -Takeover restarts it if it won the race.
New-ItemProperty -Path $runKey -Name 'DiscordVideoUnlock' -Value "`"$conhost`" $watcherArgs" -PropertyType String -Force | Out-Null
Write-Verbose "Logon entry registered: $runKey\DiscordVideoUnlock"

$stopped = Stop-DvuWatcher
Write-Verbose "Stopped $stopped previous watcher(s)."

if (-not $NoStart) {
    Start-Process -FilePath $conhost -ArgumentList "$watcherArgs -Launch"
    Write-Verbose "Watcher started. Log: $env:LOCALAPPDATA\DiscordVideoUnlock\watcher.log"
}
