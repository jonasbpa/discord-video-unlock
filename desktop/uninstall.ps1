<#
.SYNOPSIS
    Removes the logon entry, stops the watcher and restores proxy settings if a bypass was cut short.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$watcher = Join-Path $PSScriptRoot 'src\watcher.ps1'

Remove-ItemProperty -Path $runKey -Name 'DiscordVideoUnlock' -ErrorAction SilentlyContinue
Write-Host 'Logon entry removed.'

$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($watcher) })
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host "Stopped $($procs.Count) watcher process(es)."

Import-Module (Join-Path $PSScriptRoot 'src\DiscordVideoUnlock.psm1') -Force
if (Restore-BootProxy) { Write-Host 'Proxy settings restored from backup.' }
