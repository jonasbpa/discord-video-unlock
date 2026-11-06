# Discord Video Unlock - instalador para Windows
#
#   irm https://raw.githubusercontent.com/jonasbpa/discord-video-unlock/main/install.ps1 | iex
#
# Instala (ou atualiza) em %LOCALAPPDATA%\DiscordVideoUnlock\app, sem admin, e reabre o Discord
# com vídeo e compartilhamento de tela liberados. Desinstalar:
#
#   irm https://raw.githubusercontent.com/jonasbpa/discord-video-unlock/main/uninstall.ps1 | iex

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is very slow with the progress bar on 5.1
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo = 'jonasbpa/discord-video-unlock'
    $ref = if ($env:DVU_REF) { $env:DVU_REF } else { 'main' }
    $base = Join-Path $env:LOCALAPPDATA 'DiscordVideoUnlock'
    $app = Join-Path $base 'app'
    $tmp = Join-Path $env:TEMP ('dvu-' + [guid]::NewGuid().ToString('N'))

    Write-Host ''
    Write-Host '  Discord Video Unlock' -ForegroundColor Cyan
    Write-Host '  Libera câmera e compartilhamento de tela do Discord no Brasil.' -ForegroundColor DarkGray
    Write-Host ''

    try {
        Write-Host '  [1/3] Baixando...'
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $zip = Join-Path $tmp 'src.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/$ref.zip" -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        $desktop = Join-Path $src.FullName 'desktop'
        if (-not (Test-Path (Join-Path $desktop 'install.ps1'))) { throw "pacote inválido: $desktop" }

        Write-Host '  [2/3] Instalando...'
        if (Test-Path (Join-Path $app 'uninstall.ps1')) {
            # Upgrade: stop the old watcher (and restore the proxy) before replacing its files.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'uninstall.ps1')
            if ($LASTEXITCODE) { throw 'falha ao parar a versão anterior' }
        }
        if (Test-Path $app) { Remove-Item -Recurse -Force $app }
        Copy-Item -Recurse -Path $desktop -Destination $app

        Write-Host '  [3/3] Ativando e abrindo o Discord...'
        # -File: the default execution policy (Restricted) would block calling the script directly.
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'install.ps1')
        if ($LASTEXITCODE) { throw 'falha ao registrar o watcher' }

        Write-Host ''
        Write-Host '  Pronto! O Discord vai reiniciar já liberado.' -ForegroundColor Green
        Write-Host '  Daqui pra frente funciona sozinho, sempre que o Discord abrir.' -ForegroundColor Green
        Write-Host ''
        Write-Host '  Se recarregar o Discord (Ctrl+R), feche pela bandeja (Sair) e abra de novo.' -ForegroundColor DarkGray
        Write-Host "  Log: $base\watcher.log" -ForegroundColor DarkGray
        Write-Host ''
    } catch {
        Write-Host ''
        Write-Host "  Erro: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Nada foi alterado no proxy do Windows. Tente de novo ou abra uma issue no GitHub.' -ForegroundColor Red
        Write-Host ''
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}
