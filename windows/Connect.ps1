#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$')][string]$Name,
    [string]$PairingFile,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/Orca')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrcaDeploy.psm1') -Force
Assert-OrcaWindowsUser
$cli = Get-OrcaCliPath -InstallDirectory $InstallDirectory
Connect-OrcaEnvironment -Cli $cli -Name $Name -PairingFile $PairingFile
