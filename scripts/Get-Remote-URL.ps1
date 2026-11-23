#Requires -Version 5.1
[CmdletBinding()]
param([string]$InterfaceAlias)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Remote.Common.ps1')

try {
    Show-RemoteUrls -InterfaceAlias $InterfaceAlias
} catch { Write-Error "URL lookup failed: $($_.Exception.Message)" -ErrorAction Continue; exit 1 }
