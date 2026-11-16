Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-OrcaWindowsUser {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Run this script in Windows PowerShell 5.1 or PowerShell 7 on Windows.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'A 64-bit Windows installation is required.'
    }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'Run as the Windows user who will use the Orca desktop app, not SYSTEM.'
    }
}

function Get-OrcaVersionLock {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'versions.lock.env'
    $lock = ConvertFrom-StringData -StringData (Get-Content -LiteralPath $path -Raw)
    if ($lock.ORCA_VERSION -notmatch '^\d+\.\d+\.\d+$' -or
        $lock.WINDOWS_X64_SHA256 -notmatch '^[a-f0-9]{64}$' -or
        $lock.WINDOWS_X64_URL -notmatch '^https://github\.com/stablyai/orca/releases/download/') {
        throw 'Invalid Windows release in versions.lock.env.'
    }
    return $lock
}

function Get-OrcaCliPath {
    param([Parameter(Mandatory)][string]$InstallDirectory)
    $cli = Join-Path $InstallDirectory 'resources/bin/orca.exe'
    if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) {
        throw "Orca CLI was not found at $cli. Run Setup.ps1 or specify -InstallDirectory."
    }
    return $cli
}

function Invoke-OrcaDefaultProfile {
    param([Parameter(Mandatory)][scriptblock]$Action)
    # Both CLI and desktop must use the current user's default Orca profile.
    $keys = @('ORCA_USER_DATA_PATH', 'ORCA_ENVIRONMENT', 'ORCA_PAIRING_CODE',
        'ORCA_REMOTE_PAIRING', 'ORCA_APP_EXECUTABLE', 'ORCA_DEV_USER_DATA_PATH',
        'ORCA_SERVE_RUNTIME', 'ORCA_INSTANCE_ID', 'ORCA_RUNTIME_SOURCE_PROFILE_PATH',
        'ELECTRON_RUN_AS_NODE', 'ORCA_BACKGROUND_LAUNCH')
    $saved = @{}
    try {
        foreach ($key in $keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $null, 'Process')
        }
        & $Action
    }
    finally {
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
    }
}

function Start-OrcaDesktop {
    param([Parameter(Mandatory)][string]$Application)
    Invoke-OrcaDefaultProfile { $null = Start-Process -FilePath $Application }
}

function Invoke-OrcaCli {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Invoke-OrcaDefaultProfile {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $PSNativeCommandUseErrorActionPreference = $false
            $output = @(& $Cli @Arguments 2>$null)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
        if ($code -ne 0) {
            throw "Orca CLI failed (exit $code). Check the address, pairing offer and server status."
        }
        return ($output -join "`n")
    }
}

function Invoke-OrcaJson {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $text = Invoke-OrcaCli -Cli $Cli -Arguments ($Arguments + @('--json'))
    try { $response = ConvertFrom-Json -InputObject $text }
    catch { throw 'Orca returned invalid JSON. No response body was logged.' }
    if ($response.ok -ne $true -or $null -eq $response.result) {
        throw 'Orca RPC failed. No response body was logged.'
    }
    return $response.result
}

function Read-OrcaPairingUrl {
    param([string]$PairingFile)
    if ($PairingFile) {
        try {
            $offer = Get-Content -LiteralPath $PairingFile -Raw | ConvertFrom-Json
            $url = [string]$offer.result.pairingUrl
            if ($offer.ok -ne $true -or $offer.result.available -ne $true) { throw 'Invalid offer.' }
        }
        catch { throw 'The pairing file must contain successful output from orca-service pair.' }
    }
    else {
        $secret = Read-Host 'Paste the Orca pairing URL' -AsSecureString
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
        try { $url = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
            $secret.Dispose()
        }
    }
    if ($url -notmatch '^orca://pair\?code=[A-Za-z0-9_=%+&./-]+$') {
        throw 'Expected an orca://pair?code=... URL. Create a fresh offer on the container.'
    }
    return $url
}

function Connect-OrcaEnvironment {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$')][string]$Name,
        [string]$PairingFile
    )
    $result = Invoke-OrcaJson -Cli $Cli -Arguments @('environment', 'list')
    $existing = @($result.environments | Where-Object { $_.name -ieq $Name })
    if ($existing.Count -gt 0) {
        if ($PairingFile) {
            throw "Environment '$Name' already exists. Omit -PairingFile to verify it, or manage it in Orca Settings."
        }
        Write-Host "Using saved environment: $Name"
    }
    else {
        $pairingUrl = Read-OrcaPairingUrl -PairingFile $PairingFile
        try {
            $null = Invoke-OrcaJson -Cli $Cli -Arguments @(
                'environment', 'add', '--name', $Name, '--pairing-code', $pairingUrl)
        }
        finally { $pairingUrl = $null }
        Write-Host "Saved environment: $Name"
    }
    try { $null = Invoke-OrcaJson -Cli $Cli -Arguments @('status', '--environment', $Name) }
    catch { throw "Environment '$Name' is saved but its status check failed. Check its network/server, then rerun without -PairingFile." }
    Write-Host "Connected and verified: $Name"
}

Export-ModuleMember -Function Assert-OrcaWindowsUser, Get-OrcaVersionLock,
    Get-OrcaCliPath, Invoke-OrcaCli, Invoke-OrcaJson, Connect-OrcaEnvironment, Start-OrcaDesktop
