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

function Remove-OrcaEnvironment {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$')][string]$Name
    )
    $null = Invoke-OrcaJson -Cli $Cli -Arguments @('environment', 'rm', '--environment', $Name)
}

function Protect-OrcaSecret {
    param([Parameter(Mandatory)][string]$PlainText)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($protected)
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-OrcaSecret {
    param([Parameter(Mandatory)][string]$ProtectedBase64)
    Add-Type -AssemblyName System.Security
    $protected = [Convert]::FromBase64String($ProtectedBase64)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Write-OrcaJsonFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $tmp = "$Path." + [guid]::NewGuid().ToString('N') + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($tmp, $json + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Invoke-OrcaGatewayRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        $Body = $null,
        [switch]$UseSystemProxy,
        [int]$TimeoutSec = 15
    )
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Method = $Method
        $request.Timeout = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $request.Headers.Add('Authorization', "Bearer $Token")
        $request.Accept = 'application/json'
        if (-not $UseSystemProxy) {
            # Bypass Windows/Clash system HTTP proxy by default so Tailscale 100.x gateway connects directly.
            $request.Proxy = $null
        }
        if ($null -ne $Body) {
            $payload = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
            $request.ContentType = 'application/json; charset=utf-8'
            $request.ContentLength = $payload.Length
            $stream = $request.GetRequestStream()
            try { $stream.Write($payload, 0, $payload.Length) }
            finally { $stream.Dispose() }
        }
        try {
            $response = $request.GetResponse()
            try {
                $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
                try { $text = $reader.ReadToEnd() }
                finally { $reader.Dispose() }
                return ($text | ConvertFrom-Json)
            }
            finally { $response.Dispose() }
        }
        catch [Net.WebException] {
            $statusCode = 0
            if ($null -ne $_.Exception.Response) {
                try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
                try { $_.Exception.Response.Dispose() } catch {}
            }
            if ($statusCode -eq 401) {
                throw 'Gateway sync unauthorized (HTTP 401). This Windows client token may be invalid or revoked.'
            }
            if ($statusCode -gt 0) {
                throw "Gateway sync request failed (HTTP $statusCode) for $Method $Uri."
            }
            throw "Could not reach gateway sync endpoint $Uri. Check Tailscale connectivity and gateway port."
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls
    }
}

function ConvertTo-OrcaManagedMap {
    param($RawState)
    $map = @{}
    if ($null -eq $RawState -or $null -eq $RawState.PSObject.Properties['managed'] -or $null -eq $RawState.managed) {
        return $map
    }
    foreach ($prop in $RawState.managed.PSObject.Properties) {
        $entry = $prop.Value
        $map[$prop.Name] = @{
            nodeId   = [string]$entry.nodeId
            endpoint = [string]$entry.endpoint
            syncedAt = [string]$entry.syncedAt
        }
    }
    return $map
}

function Sync-OrcaGatewayEnvironments {
    param(
        [Parameter(Mandatory)][string]$Cli,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$StateFile,
        [switch]$AdoptExisting,
        [switch]$UseSystemProxy
    )
    $baseUrl = $Gateway.TrimEnd('/')
    if ($baseUrl -notmatch '^https?://[^/\s]+$') {
        throw 'Gateway URL must be http(s)://host:port without a path.'
    }
    $managed = @{}
    if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
        try {
            $rawState = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $managed = ConvertTo-OrcaManagedMap -RawState $rawState
        }
        catch { $managed = @{} }
    }

    $remote = Invoke-OrcaGatewayRequest -Method 'GET' -Uri "$baseUrl/sync/state" -Token $Token -UseSystemProxy:$UseSystemProxy
    if ($remote.ok -ne $true) {
        throw 'Gateway returned an unexpected sync state response.'
    }
    $remoteNodes = @($remote.nodes)
    $remoteByName = @{}
    foreach ($node in $remoteNodes) {
        if ($null -ne $node -and $node.name) {
            $remoteByName[[string]$node.name] = $node
        }
    }

    $listResult = Invoke-OrcaJson -Cli $Cli -Arguments @('environment', 'list')
    $localByLower = @{}
    foreach ($envItem in @($listResult.environments)) {
        if ($null -ne $envItem -and $envItem.name) {
            $localByLower[([string]$envItem.name).ToLowerInvariant()] = [string]$envItem.name
        }
    }

    $summary = [ordered]@{
        added         = @()
        replaced      = @()
        removed       = @()
        acked         = @()
        conflicts     = @()
        unprovisioned = @()
        failed        = @()
    }
    $dirty = $false

    $saveState = {
        Write-OrcaJsonFileAtomic -Path $StateFile -Value ([ordered]@{
            version = 1
            gateway = $baseUrl
            managed = $managed
        })
    }

    # 1. Clean up nodes that this sync tool previously added and the hub has since removed.
    foreach ($managedName in @($managed.Keys)) {
        if (-not $remoteByName.ContainsKey($managedName)) {
            $lower = $managedName.ToLowerInvariant()
            if ($localByLower.ContainsKey($lower)) {
                try {
                    Remove-OrcaEnvironment -Cli $Cli -Name $localByLower[$lower]
                    $localByLower.Remove($lower)
                    $summary.removed += $managedName
                    $managed.Remove($managedName)
                    $dirty = $true
                }
                catch {
                    $summary.failed += "remove:${managedName}"
                }
            }
            else {
                $managed.Remove($managedName)
                $dirty = $true
            }
        }
    }

    # 2. Sync active hub nodes into official Orca CLI without touching unmanaged user environments.
    foreach ($node in $remoteNodes) {
        $name = [string]$node.name
        $nodeId = [string]$node.nodeId
        $endpoint = [string]$node.endpoint
        $grantStatus = [string]$node.grantStatus
        $lower = $name.ToLowerInvariant()
        $hasLocal = $localByLower.ContainsKey($lower)
        $isManaged = $managed.ContainsKey($name)

        if ($isManaged -and $managed[$name].nodeId -ceq $nodeId -and $hasLocal) {
            if ($grantStatus -ceq 'pending') {
                # Previous run added the environment but failed before acking; verify then burn offer.
                try {
                    $null = Invoke-OrcaJson -Cli $Cli -Arguments @('status', '--environment', $localByLower[$lower])
                    $null = Invoke-OrcaGatewayRequest -Method 'POST' -Uri "$baseUrl/sync/ack" -Token $Token `
                        -Body @{ node = $name; nodeId = $nodeId } -UseSystemProxy:$UseSystemProxy
                    $summary.acked += $name
                }
                catch {
                    $summary.failed += "ack:${name}"
                }
            }
            continue
        }

        if ($hasLocal -and -not $isManaged) {
            if (-not $AdoptExisting) {
                $summary.conflicts += $name
                continue
            }
            if ($grantStatus -cne 'pending') {
                $summary.unprovisioned += $name
                continue
            }
        }

        if ($isManaged -and $hasLocal -and $managed[$name].nodeId -cne $nodeId) {
            if ($grantStatus -cne 'pending') {
                $summary.unprovisioned += $name
                continue
            }
        }

        if ($grantStatus -cne 'pending') {
            if ($isManaged -and -not $hasLocal) {
                $managed.Remove($name)
                $dirty = $true
            }
            $summary.unprovisioned += $name
            continue
        }

        $pairingUrl = $null
        try {
            $claimed = Invoke-OrcaGatewayRequest -Method 'POST' -Uri "$baseUrl/sync/claim" -Token $Token `
                -Body @{ node = $name } -UseSystemProxy:$UseSystemProxy
            if ($claimed.ok -ne $true -or $null -eq $claimed.offer) {
                throw 'Missing offer payload.'
            }
            $pairingUrl = [string]$claimed.offer.pairingUrl
            if ($pairingUrl -notmatch '^orca://pair\?code=[A-Za-z0-9_=%+&./-]+$') {
                throw 'Invalid pairing URL returned by gateway.'
            }
            $wasReplaced = $false
            if ($hasLocal) {
                Remove-OrcaEnvironment -Cli $Cli -Name $localByLower[$lower]
                $localByLower.Remove($lower)
                $wasReplaced = $true
            }
            $null = Invoke-OrcaJson -Cli $Cli -Arguments @(
                'environment', 'add', '--name', $name, '--pairing-code', $pairingUrl)
            $null = Invoke-OrcaJson -Cli $Cli -Arguments @('status', '--environment', $name)
            $managed[$name] = @{
                nodeId   = $nodeId
                endpoint = $endpoint
                syncedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            $localByLower[$lower] = $name
            $dirty = $true
            & $saveState
            $null = Invoke-OrcaGatewayRequest -Method 'POST' -Uri "$baseUrl/sync/ack" -Token $Token `
                -Body @{ node = $name; nodeId = $nodeId } -UseSystemProxy:$UseSystemProxy
            if ($wasReplaced) { $summary.replaced += $name } else { $summary.added += $name }
        }
        catch {
            $summary.failed += "sync:${name}"
        }
        finally { $pairingUrl = $null }
    }

    if ($dirty) { & $saveState }
    return [pscustomobject]$summary
}

Export-ModuleMember -Function Assert-OrcaWindowsUser, Get-OrcaVersionLock,
    Get-OrcaCliPath, Invoke-OrcaCli, Invoke-OrcaJson, Connect-OrcaEnvironment,
    Remove-OrcaEnvironment, Start-OrcaDesktop, Protect-OrcaSecret, Unprotect-OrcaSecret,
    Write-OrcaJsonFileAtomic, Invoke-OrcaGatewayRequest, Sync-OrcaGatewayEnvironments
