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

Check 'config loads with UTF-8 toast text' { $config.proxyProviders.Count -and $config.toast.title -match 'conclu.do' }

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
$listText = "http://8.8.8.8:80`n1.1.1.1:3128`r`n127.0.0.1:80`n10.0.0.1:80`n192.168.0.1:80`n8.8.8.8:80`n8.8.4.4:70000`n999.1.1.1:80`nevil; rm -rf:80`n"
$listServer = Start-FakeServer ("HTTP/1.1 200 OK`r`nContent-Type: text/plain`r`nContent-Length: " + $listText.Length + "`r`nConnection: close`r`n`r`n" + $listText)
$cache = Join-Path $env:TEMP "dvu-smoke-cache-$PID.txt"
$listConfig = [pscustomobject]@{
    proxyServer = ''; proxyProviders = @('http://127.0.0.1:1/dead.txt', "http://127.0.0.1:$($listServer.Port)/list.txt")
    proxyDownloadTimeoutSeconds = 5; proxyScanSeconds = 5; proxyProbeTimeoutMs = 1000
}
$deadConfig = [pscustomobject]@{
    proxyServer = ''; proxyProviders = @('http://127.0.0.1:1/dead.txt')
    proxyDownloadTimeoutSeconds = 2; proxyScanSeconds = 5; proxyProbeTimeoutMs = 1000
}
$noNetwork = { param([string[]]$Candidates, $Config) $Candidates | Where-Object { $_ -eq '8.8.8.8:80' } }
$firstCached = { param([string[]]$Servers, $Config) $Servers[0] }
try {
    Check 'list parsing keeps only public ip:port entries' {
        $servers = @(ConvertFrom-DvuProxyText -Text $listText)
        $servers.Count -eq 2 -and $servers[0] -eq '8.8.8.8:80' -and $servers[1] -eq '1.1.1.1:3128'
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
    Check 'full check rejects a proxy without valid TLS' {
        @([DiscordVideoUnlock.ProxyProbe]::FindVerified(
            [string[]]@('127.0.0.1:1', "127.0.0.1:$($goodProxy.Port)"), 1, 10, 2000, 4000)).Count -eq 0
    }
    Check 'configured proxyServer wins and skips the list' {
        (Select-DvuProxy -Config ([pscustomobject]@{ proxyServer = 'socks=127.0.0.1:1080' }) -CachePath $cache) -eq 'socks=127.0.0.1:1080'
    }
    Check 'no cache and no provider means no proxy' {
        $null -eq (Select-DvuProxy -Config $deadConfig -CachePath $cache -Probe $firstCached)
    }
    Check 'missing cache is filled from the providers' {
        (Select-DvuProxy -Config $listConfig -CachePath $cache -Probe $firstCached -Verify $noNetwork) -eq '8.8.8.8:80'
    }
    Check 'failed update keeps the cached list' {
        $updated = Update-DvuProxyCache -Config $deadConfig -CachePath $cache
        -not $updated -and (Select-DvuProxy -Config $deadConfig -CachePath $cache -Probe $firstCached) -eq '8.8.8.8:80'
    }
    Check 'scan with no working proxy keeps the cached list' {
        $updated = Update-DvuProxyCache -Config $listConfig -CachePath $cache -Verify { param($Candidates, $Config) }
        -not $updated -and ([IO.File]::ReadAllText($cache)).Trim() -eq '8.8.8.8:80'
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
