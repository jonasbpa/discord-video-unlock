<#
.SYNOPSIS
    Non-destructive checks. Never touches the real Internet Settings key and never starts or kills Discord.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$failures = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $ok = & $Test
        if ($ok) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:failures++ }
    } catch {
        Write-Host "FAIL  $Name : $($_.Exception.Message)"; $script:failures++
    }
}

Check 'all scripts parse' {
    $bad = foreach ($f in Get-ChildItem $root -Recurse -Include *.ps1, *.psm1) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if ($errs) { "$($f.Name): $($errs[0].Message)" }
    }
    if ($bad) { Write-Host ($bad -join "`n") }
    -not $bad
}

Import-Module (Join-Path $root 'src\DiscordVideoUnlock.psm1') -Force
$config = Get-DvuConfig -Path (Join-Path $root 'config.json')

Check 'config loads with UTF-8 toast text' { $config.proxyServer -and $config.toast.title -match 'conclu.do' }

$key = 'HKCU:\Software\DiscordVideoUnlockSmokeTest'
$backup = Join-Path $env:TEMP "dvu-smoke-$PID.json"
try {
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name ProxyEnable -Value 0 -PropertyType DWord | Out-Null
    # ProxyServer deliberately absent: restore must delete it again, not leave an empty value.

    Check 'enable sets proxy and writes backup' {
        Enable-BootProxy -ProxyServer '1.2.3.4:8080' -KeyPath $key -BackupPath $backup
        $p = Get-ItemProperty $key
        $p.ProxyEnable -eq 1 -and $p.ProxyServer -eq '1.2.3.4:8080' -and (Test-Path $backup)
    }
    Check 'second enable keeps the original backup' {
        Enable-BootProxy -ProxyServer '5.6.7.8:8080' -KeyPath $key -BackupPath $backup
        (Get-Content -Raw $backup | ConvertFrom-Json).ProxyEnable -eq 0
    }
    Check 'restore brings back original values and removes backup' {
        $restored = Restore-BootProxy -KeyPath $key -BackupPath $backup
        $p = Get-ItemProperty $key
        $restored -and $p.ProxyEnable -eq 0 -and -not ($p.PSObject.Properties.Name -contains 'ProxyServer') -and -not (Test-Path $backup)
    }
    Check 'restore without backup is a no-op' { -not (Restore-BootProxy -KeyPath $key -BackupPath $backup) }
} finally {
    Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $backup -Force -ErrorAction SilentlyContinue
}

$install = Resolve-DiscordInstall -Build 'Discord'
if ($install) {
    Write-Host "INFO  Discord install: $($install.Dir) (app-$($install.Version))"
    $mains = @(Get-DiscordMainProcesses -Builds $config.builds)
    if ($mains.Count) {
        Check 'exactly one main process per running build' { @($mains | Group-Object Build | Where-Object Count -gt 1).Count -eq 0 }
        Check 'running Discord detected as booted' { Test-DiscordReady -ProcessId $mains[0].ProcessId }
    } else {
        Write-Host 'SKIP  process checks (Discord not running)'
    }
} else {
    Write-Host 'SKIP  install checks (Discord not installed)'
}

Write-Host ("{0} failure(s)" -f $failures)
exit $failures
