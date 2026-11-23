#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Stop)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Remote.Common.ps1')

try {
    Assert-RemoteAdministrator
    [void](Get-UltraVncService)
    Set-Service -Name uvnc_service -StartupType Manual -ErrorAction Stop
    $serviceInfo = Get-CimInstance Win32_Service -Filter "Name='uvnc_service'" -ErrorAction Stop
    if ($serviceInfo.StartMode -ne 'Manual') { throw 'UltraVNC startup type was not changed to Manual.' }
    Write-Host 'UltraVNC startup type: Manual.'
    if ($Stop) { Stop-RemoteVnc; Write-Host 'UltraVNC service and TCP 5900 are inactive.' }
    Write-Host 'One-time setting: in Docker Desktop > Settings > General, turn off Start Docker Desktop when you sign in.'
    Write-Host 'Run Stop-Remote.ps1 once to remove any existing containers with the old restart policy. The next start uses restart: no.'
    Write-Host 'To reverse the service setting (administrator): Set-Service -Name uvnc_service -StartupType Automatic'
    Write-Host 'This does not change com.docker.service or start/stop Docker Desktop.'
} catch { Write-Error "Manual startup configuration failed: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
