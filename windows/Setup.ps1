#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$')][string]$Name,
    [string]$PairingFile,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/Orca'),
    [switch]$NoLaunch
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrcaDeploy.psm1') -Force
Assert-OrcaWindowsUser
if ($PairingFile -and -not $Name) { throw 'Specify -Name when using -PairingFile.' }
if ($InstallDirectory -notmatch '^[A-Za-z]:[\\/]' -or $InstallDirectory -match '["\r\n]') {
    throw '-InstallDirectory must be an absolute local Windows path without quotes or newlines.'
}
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\', '/')
$lock = Get-OrcaVersionLock
$app = Join-Path $InstallDirectory 'Orca.exe'
if (Test-Path -LiteralPath $app -PathType Leaf) {
    $cli = Get-OrcaCliPath -InstallDirectory $InstallDirectory
    $installed = (Invoke-OrcaCli -Cli $cli -Arguments @('--version')).Trim()
    if ($installed -ne $lock.ORCA_VERSION) {
        throw "Installed Orca is $installed; this repo pins $($lock.ORCA_VERSION). Existing app and sessions were kept. Use Connect.ps1 for pairing only."
    }
    Write-Host "Orca $installed is already installed."
}
else {
    if ((Test-Path -LiteralPath $InstallDirectory) -and
        @(Get-ChildItem -LiteralPath $InstallDirectory -Force).Count -gt 0) {
        throw 'The install directory is nonempty and contains no Orca.exe. Inspect it before installing.'
    }
    # Checksum verification is independent of certificate-chain validation.
    $cache = Join-Path (Split-Path $PSScriptRoot -Parent) '.cache'
    $null = New-Item -ItemType Directory -Path $cache -Force
    $installer = Join-Path $cache ("orca-" + [guid]::NewGuid().ToString('N') + '.exe')
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        Write-Host "Downloading Orca $($lock.ORCA_VERSION)..."
        Invoke-WebRequest -UseBasicParsing -Uri $lock.WINDOWS_X64_URL -OutFile $installer
        if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ine $lock.WINDOWS_X64_SHA256) {
            throw 'Installer SHA256 mismatch. Nothing was executed.'
        }
        if ((Get-AuthenticodeSignature -LiteralPath $installer).Status -ne 'Valid') {
            throw 'Installer signature is invalid or untrusted. Nothing was executed.'
        }
        # NSIS requires /D= last, with no surrounding quotes even when the path has spaces.
        $process = Start-Process -FilePath $installer -ArgumentList "/S /currentuser /D=$InstallDirectory" -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "Orca installer failed (exit $($process.ExitCode))." }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
    }
    $cli = Get-OrcaCliPath -InstallDirectory $InstallDirectory
    $installed = (Invoke-OrcaCli -Cli $cli -Arguments @('--version')).Trim()
    if ($installed -ne $lock.ORCA_VERSION -or -not (Test-Path -LiteralPath $app -PathType Leaf)) {
        throw 'Installed Orca did not pass version/layout verification.'
    }
    Write-Host "Installed Orca $installed."
}
if ($Name) { Connect-OrcaEnvironment -Cli $cli -Name $Name -PairingFile $PairingFile }
if (-not $NoLaunch) { Start-OrcaDesktop -Application $app }
