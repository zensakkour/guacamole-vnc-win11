# Compatibility entry point; use scripts/Get-Remote-URL.ps1 for new instructions.
#Requires -Version 5.1
[CmdletBinding()]
param([string]$InterfaceAlias)

& (Join-Path $PSScriptRoot 'scripts\Get-Remote-URL.ps1') -InterfaceAlias $InterfaceAlias
