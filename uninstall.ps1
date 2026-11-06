# Discord Video Unlock - desinstalador para Windows
#
#   irm https://raw.githubusercontent.com/jonasbpa/discord-video-unlock/main/uninstall.ps1 | iex

& {
    $ErrorActionPreference = 'Stop'
    $base = Join-Path $env:LOCALAPPDATA 'DiscordVideoUnlock'
    $app = Join-Path $base 'app'

    Write-Host ''
    if (-not (Test-Path (Join-Path $app 'uninstall.ps1'))) {
        Write-Host '  Discord Video Unlock não está instalado.' -ForegroundColor Yellow
        Write-Host ''
        return
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'uninstall.ps1')
    if ($LASTEXITCODE) {
        # Keep the folder: it may still hold the backup of the user's proxy settings.
        Write-Host "  Erro ao desinstalar. Arquivos mantidos em $base" -ForegroundColor Red
        Write-Host '  Se o proxy ficou ligado: Configurações > Rede e Internet > Proxy > desligar.' -ForegroundColor Red
        Write-Host ''
        return
    }
    Remove-Item -Recurse -Force $base
    Write-Host '  Discord Video Unlock removido. O proxy do Windows está como antes.' -ForegroundColor Green
    Write-Host '  O Discord continua aberto; da próxima vez que abrir, volta ao normal.' -ForegroundColor DarkGray
    Write-Host ''
}
