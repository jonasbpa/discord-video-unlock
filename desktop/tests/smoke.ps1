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
    $bad = foreach ($f in Get-ChildItem (Split-Path $root -Parent) -Recurse -Include *.ps1, *.psm1 | Where-Object FullName -notmatch '\\\.git\\') {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if ($errs) { "$($f.Name): $($errs[0].Message)" }
    }
    if ($bad) { Write-Host ($bad -join "`n") }
    -not $bad
}

Import-Module (Join-Path $root 'src\DiscordVideoUnlock.psm1') -Force
$config = Get-DvuConfig -Path (Join-Path $root 'config.json')

Check 'config loads with UTF-8 toast text' { $config.proxyListUrl -and $config.toast.title -match 'conclu.do' }

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

# One-shot local TCP server answering every connection with a fixed reply.
function Start-FakeServer([string]$Reply) {
    $listener = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($listener, $reply)
        while ($true) {
            $client = $listener.AcceptTcpClient()
            $stream = $client.GetStream()
            $buffer = New-Object byte[] 4096
            [void]$stream.Read($buffer, 0, $buffer.Length)
            if ($reply) {
                $bytes = [Text.Encoding]::ASCII.GetBytes($reply)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            $client.Close()
        }
    }).AddArgument($listener).AddArgument($Reply)
    [void]$ps.BeginInvoke()
    [pscustomobject]@{ Listener = $listener; Shell = $ps; Port = $listener.LocalEndpoint.Port }
}
function Stop-FakeServer($Server) { $Server.Listener.Stop(); $Server.Shell.Dispose() }

$goodProxy = Start-FakeServer "HTTP/1.1 200 Connection established`r`n`r`n"
$deniedProxy = Start-FakeServer "HTTP/1.1 403 Forbidden`r`n`r`n"
$listJson = '{"proxies":[{"server":"127.0.0.1:' + $goodProxy.Port + '"},{"server":"evil; rm -rf"},{"server":"127.0.0.1:1;x"}]}'
$listServer = Start-FakeServer ("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: " + $listJson.Length + "`r`nConnection: close`r`n`r`n" + $listJson)
$cache = Join-Path $env:TEMP "dvu-smoke-cache-$PID.json"
$listConfig = [pscustomobject]@{
    proxyServer = ''; proxyListUrl = "http://127.0.0.1:$($listServer.Port)/proxies.json"
    proxyListTimeoutSeconds = 5; proxyProbeTimeoutMs = 2000
}
$deadConfig = [pscustomobject]@{
    proxyServer = ''; proxyListUrl = 'http://127.0.0.1:1/proxies.json'
    proxyListTimeoutSeconds = 2; proxyProbeTimeoutMs = 1000
}
try {
    Check 'list parsing keeps only ip:port entries' {
        $servers = @(ConvertFrom-DvuProxyList -Json $listJson)
        $servers.Count -eq 1 -and $servers[0] -eq "127.0.0.1:$($goodProxy.Port)"
    }
    Check 'probe skips dead and refusing proxies' {
        $found = [DiscordVideoUnlock.ProxyProbe]::FirstWorking(
            [string[]]@('127.0.0.1:1', "127.0.0.1:$($deniedProxy.Port)", "127.0.0.1:$($goodProxy.Port)"), 'discord.com', 2000)
        $found -eq "127.0.0.1:$($goodProxy.Port)"
    }
    Check 'probe returns null when nothing works' {
        $null -eq [DiscordVideoUnlock.ProxyProbe]::FirstWorking(
            [string[]]@('127.0.0.1:1', "127.0.0.1:$($deniedProxy.Port)"), 'discord.com', 1000)
    }
    Check 'configured proxyServer wins and skips the list' {
        (Select-DvuProxy -Config ([pscustomobject]@{ proxyServer = 'socks=127.0.0.1:1080' }) -CachePath $cache) -eq 'socks=127.0.0.1:1080'
    }
    Check 'no cache and no list means no proxy' {
        $null -eq (Select-DvuProxy -Config $deadConfig -CachePath $cache)
    }
    Check 'missing cache is downloaded and probed' {
        (Select-DvuProxy -Config $listConfig -CachePath $cache) -eq "127.0.0.1:$($goodProxy.Port)" -and (Test-Path $cache)
    }
    Check 'failed update keeps the cached list' {
        $updated = Update-DvuProxyCache -Config $deadConfig -CachePath $cache
        -not $updated -and (Select-DvuProxy -Config $deadConfig -CachePath $cache) -eq "127.0.0.1:$($goodProxy.Port)"
    }
} finally {
    foreach ($server in $goodProxy, $deniedProxy, $listServer) { Stop-FakeServer $server }
    Remove-Item -Path $cache, "$cache.tmp" -Force -ErrorAction SilentlyContinue
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
