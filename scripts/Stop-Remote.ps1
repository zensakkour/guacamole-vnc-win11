#Requires -Version 5.1
[CmdletBinding()]
param([ValidateRange(10, 600)][int]$DockerShutdownTimeoutSeconds = 120)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Remote.Common.ps1')

try { Assert-RemoteAdministrator } catch { Write-Error $_ -ErrorAction Continue; exit 1 }

$containersInactive = 'Unknown'
$serviceInactive = 'Unknown'
$portInactive = 'Unknown'
$shutdownFailed = $false
$desktopStatus = 'Not stopped'
$desktopReason = 'Project container shutdown has not been confirmed.'

# Keep shutting down UltraVNC even when Docker or Compose is unavailable.
try {
    Assert-LocalDockerContext
    if (Test-DockerEngine) {
        [void](Invoke-RemoteCompose -Arguments @('down') -TimeoutSeconds 120)
        $remaining = @(Get-RemoteContainers)
        if ($remaining.Count -gt 0) { throw 'Compose still reports project containers after shutdown.' }
    } elseif (Test-DockerDesktopStopped) {
        $desktopStatus = 'Already stopped'
        $desktopReason = 'Engine unavailable and no Desktop/backend processes; project containers are inactive.'
    } else {
        throw 'Docker Engine unavailable while Desktop/backend processes remain. Workloads and container shutdown cannot be verified; Docker Desktop will be left alone.'
    }
    $containersInactive = 'Yes'
} catch {
    $shutdownFailed = $true
    Write-Warning "Container shutdown: $($_.Exception.Message)"
}

try { Stop-RemoteVnc } catch { $shutdownFailed = $true; Write-Warning $_.Exception.Message }
try {
    $service = Get-Service -Name uvnc_service -ErrorAction SilentlyContinue
    $serviceInactive = if (-not $service -or $service.Status -eq 'Stopped') { 'Yes' } else { 'No' }
    $portInactive = if (@(Get-VncListeners).Count -eq 0) { 'Yes' } else { 'No' }
} catch { $shutdownFailed = $true; Write-Warning "Status check: $($_.Exception.Message)" }

if ($containersInactive -eq 'Yes' -and $desktopStatus -ne 'Already stopped') {
    try {
        $desktopResult = Stop-IdleDockerDesktop -TimeoutSeconds $DockerShutdownTimeoutSeconds
        $desktopStatus = $desktopResult.Status
        $desktopReason = $desktopResult.Reason
    } catch {
        $shutdownFailed = $true
        $desktopStatus = 'Shutdown not confirmed'
        $desktopReason = $_.Exception.Message
        Write-Warning "Docker Desktop: $desktopReason No Docker process was forcibly terminated."
    }
}

Write-Host "Guacamole project containers inactive: $containersInactive"
Write-Host "UltraVNC service inactive: $serviceInactive"
Write-Host "TCP 5900 inactive: $portInactive"
Write-Host "Docker Desktop: $desktopStatus"
Write-Host "Docker Desktop detail: $desktopReason"
Write-Host 'PostgreSQL volume preserved. Unrelated workloads were not stopped by this script.'
if ($shutdownFailed -or $serviceInactive -ne 'Yes' -or $portInactive -ne 'Yes') { exit 1 }
Write-Host 'Remote desktop stopped.'
