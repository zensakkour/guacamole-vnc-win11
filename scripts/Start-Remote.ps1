#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(10, 900)][int]$DockerTimeoutSeconds = 180,
    [ValidateRange(10, 900)][int]$WebTimeoutSeconds = 180,
    [string]$DockerDesktopPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Remote.Common.ps1')

try {
    Assert-RemoteAdministrator
    $service = Get-UltraVncService
    Assert-LocalDockerContext
    # Validate .env and Compose before enabling remote access.
    [void](Invoke-RemoteCompose -Arguments @('config', '--quiet'))

    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        $desktopPath = Get-DockerDesktopExecutable -Override $DockerDesktopPath
        Write-Host 'Starting Docker Desktop...'
        Start-Process -FilePath $desktopPath -WindowStyle Hidden | Out-Null
    }
    if (-not (Test-DockerEngine)) {
        Write-Host 'Waiting for the Docker Engine (Linux containers)...'
        Wait-RemoteCondition -Test { Test-DockerEngine } -TimeoutSeconds $DockerTimeoutSeconds -Description 'the Docker Engine; check Docker Desktop and the WSL 2 backend'
    }

    if ($service.Status -ne 'Running') {
        # A leftover listener should be handled by Stop-Remote, never by starting a second server.
        if (@(Get-VncListeners).Count -gt 0) { throw 'Port 5900 is already occupied while UltraVNC is stopped. Run Stop-Remote.ps1 and inspect its results first.' }
        Start-Service -Name uvnc_service -ErrorAction Stop
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    Wait-RemoteCondition -Test { Test-UltraVncListener } -TimeoutSeconds 30 -Description 'the registered UltraVNC executable on TCP 5900'

    Write-Host 'Starting this repository''s Compose stack...'
    [void](Invoke-RemoteCompose -Arguments @('up', '-d') -TimeoutSeconds 300)
    Wait-RemoteCondition -Test { Test-RemoteContainers } -TimeoutSeconds $WebTimeoutSeconds -Description 'db, guacd and guacamole containers'
    Wait-RemoteCondition -Test {
        try {
            [void](Invoke-RemoteCompose -Arguments @('exec', '-T', 'db', 'pg_isready', '-U', 'guacamole_user', '-d', 'guacamole_db') -TimeoutSeconds 5)
            return $true
        } catch { return $false }
    } -TimeoutSeconds 60 -Description 'PostgreSQL readiness'

    $binding = @(Get-RemoteBindings)[0]
    $webHost = $binding.host_ip
    if ($webHost -eq '::') { $webHost = '::1' }
    elseif (-not $webHost -or $webHost -in @('0.0.0.0', '127.0.0.1')) { $webHost = '127.0.0.1' }
    if ($webHost -match ':') { $webHost = "[$webHost]" }
    $webUrl = "http://${webHost}:$($binding.published)/guacamole/"
    Wait-RemoteCondition -Test {
        try {
            $response = Invoke-WebRequest -Uri $webUrl -UseBasicParsing -TimeoutSec 5
            return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
        } catch { return $false }
    } -TimeoutSeconds $WebTimeoutSeconds -Description "Guacamole at $webUrl; inspect docker compose logs guacamole db if it does not respond"

    if (-not (Test-RemoteContainers)) { throw 'A container stopped while Guacamole was starting. Inspect docker compose ps --all and logs.' }
    $service.Refresh()
    if ($service.Status -ne 'Running' -or -not (Test-UltraVncListener)) { throw 'UltraVNC stopped or lost its listener while Guacamole was starting.' }
    Show-RemoteUrls
    Write-Host 'Ready: Docker Engine, UltraVNC (5900), db, guacd and Guacamole web interface.'
} catch {
    Write-Error "Startup failed: $($_.Exception.Message) Components already started remain running; use Stop-Remote.ps1 to shut them down." -ErrorAction Continue
    exit 1
}
