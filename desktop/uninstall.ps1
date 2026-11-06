<#
.SYNOPSIS
    Removes the logon entry, stops the watcher and restores proxy settings if a bypass was cut short.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\DiscordVideoUnlock.psm1') -Force

Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'DiscordVideoUnlock' -ErrorAction SilentlyContinue
Write-Verbose 'Logon entry removed.'

$stopped = Stop-DvuWatcher
Write-Verbose "Stopped $stopped watcher(s); proxy settings restored if needed."
