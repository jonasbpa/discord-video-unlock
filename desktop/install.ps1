<#
.SYNOPSIS
    Registers the watcher to start hidden at logon (HKCU Run, no admin) and starts it now.
#>
[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$watcher = Join-Path $PSScriptRoot 'src\watcher.ps1'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$powershell = Join-Path $PSHOME 'powershell.exe'

# conhost --headless runs the console app with no window at all, even when Windows Terminal is
# the default terminal (where -WindowStyle Hidden still flashes a window).
$watcherArgs = "--headless `"$powershell`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$watcher`""

New-ItemProperty -Path $runKey -Name 'DiscordVideoUnlock' -Value "`"$conhost`" $watcherArgs -AtLogon" -PropertyType String -Force | Out-Null
Write-Host "Logon entry registered: $runKey\DiscordVideoUnlock"

$runValues = (Get-ItemProperty -Path $runKey).PSObject.Properties.Name
$conflicts = @('Discord', 'DiscordPTB', 'DiscordCanary') | Where-Object { $runValues -contains $_ }
if ($conflicts) {
    # -f binds tighter than +, so the concatenation needs its own parentheses.
    Write-Warning (("Discord's own autostart is enabled ({0}). It races with the watcher and may cost an " +
        "extra restart at logon. Turn off 'Open Discord' in Discord > User Settings > Windows Settings; the " +
        "watcher launches Discord itself (config.launchAtLogon). Discord rewrites its Run entry on every " +
        "launch, so deleting it here would not stick.") -f ($conflicts -join ', '))
}

if (-not $NoStart) {
    Start-Process -FilePath $conhost -ArgumentList $watcherArgs
    Write-Host "Watcher started. Log: $env:LOCALAPPDATA\DiscordVideoUnlock\watcher.log"
}
