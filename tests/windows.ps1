#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-True ($null -ne $failure) 'Expected a failure.'
    Assert-True ($failure.Exception.Message -match $Pattern) "Unexpected error: $failure"
}

foreach ($file in Get-ChildItem (Join-Path $root 'windows') -File) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parse errors in $file"
}
Write-Host 'PASS: all Windows scripts parse'

$module = Import-Module (Join-Path $root 'windows/OrcaDeploy.psm1') -Force -PassThru
$lock = Get-OrcaVersionLock
Assert-True ($lock.ORCA_VERSION -match '^\d+\.\d+\.\d+$') 'Version lock was not loaded.'
$originalProfile = $env:ORCA_USER_DATA_PATH
$originalPairing = $env:ORCA_REMOTE_PAIRING
try {
    $env:ORCA_USER_DATA_PATH = 'test-profile-override'
    $env:ORCA_REMOTE_PAIRING = 'test-routing-override'
    $clean = & $module {
        Invoke-OrcaDefaultProfile { -not $env:ORCA_USER_DATA_PATH -and -not $env:ORCA_REMOTE_PAIRING }
    }
    Assert-True $clean 'Inherited profile overrides reached the child operation.'
    Assert-True ($env:ORCA_USER_DATA_PATH -ceq 'test-profile-override') 'Profile override was not restored.'
    Expect-Failure { & $module { Invoke-OrcaDefaultProfile { throw 'fixture failure' } } } 'fixture failure'
    Assert-True ($env:ORCA_REMOTE_PAIRING -ceq 'test-routing-override') 'Routing override was not restored after failure.'
}
finally {
    $env:ORCA_USER_DATA_PATH = $originalProfile
    $env:ORCA_REMOTE_PAIRING = $originalPairing
}
Write-Host 'PASS: default-profile isolation and environment restoration'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('orca-deploy-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
try {
    $offerPath = Join-Path $temp 'server.pairing.json'
    $offer = @{ ok = $true; result = @{ available = $true; pairingUrl = 'orca://pair?code=TEST_PRIVATE_OFFER' } }
    $offer | ConvertTo-Json | Set-Content -LiteralPath $offerPath
    $url = & $module { param($Path) Read-OrcaPairingUrl -PairingFile $Path } $offerPath
    Assert-True ($url -ceq 'orca://pair?code=TEST_PRIVATE_OFFER') 'Valid offer was not accepted.'
    $offer.result.available = $false
    $offer | ConvertTo-Json | Set-Content -LiteralPath $offerPath
    Expect-Failure { & $module { param($Path) Read-OrcaPairingUrl -PairingFile $Path } $offerPath } 'successful output'
    $offer.result.available = $true
    $offer.result.pairingUrl = 'https://example.com'
    $offer | ConvertTo-Json | Set-Content -LiteralPath $offerPath
    Expect-Failure { & $module { param($Path) Read-OrcaPairingUrl -PairingFile $Path } $offerPath } 'Expected an orca'
    '{broken JSON' | Set-Content -LiteralPath $offerPath
    Expect-Failure { & $module { param($Path) Read-OrcaPairingUrl -PairingFile $Path } $offerPath } 'successful output'
    Write-Host 'PASS: pairing file parsing rejects failed, malformed and invalid offers'

    & $module {
        $script:environments = @()
        $script:added = 0
        $script:healthy = $true
        function script:Read-OrcaPairingUrl { param($PairingFile) return 'orca://pair?code=TEST_PRIVATE_OFFER' }
        function script:Invoke-OrcaJson {
            param($Cli, $Arguments)
            switch ($Arguments[0] + ' ' + $Arguments[1]) {
                'environment list' { return @{ environments = $script:environments } }
                'environment add' {
                    if ($Arguments[3] -cne 'dev-01' -or $Arguments[5] -cne 'orca://pair?code=TEST_PRIVATE_OFFER') {
                        throw 'Incorrect pairing arguments.'
                    }
                    $script:added++
                    $script:environments = @([pscustomobject]@{ name = 'dev-01' })
                    return @{}
                }
                'status --environment' {
                    if (-not $script:healthy) { throw 'Unavailable.' }
                    return @{ healthy = $true }
                }
                default { throw 'Unexpected CLI command.' }
            }
        }
    }
    Connect-OrcaEnvironment -Cli 'fixture' -Name 'dev-01' -PairingFile 'fixture'
    Assert-True ((& $module { $script:added }) -eq 1) 'New environment was not added.'
    Connect-OrcaEnvironment -Cli 'fixture' -Name 'dev-01'
    Assert-True ((& $module { $script:added }) -eq 1) 'An existing environment was paired again.'
    Expect-Failure { Connect-OrcaEnvironment -Cli 'fixture' -Name 'dev-01' -PairingFile 'fixture' } 'already exists'
    & $module { $script:healthy = $false }
    Expect-Failure { Connect-OrcaEnvironment -Cli 'fixture' -Name 'dev-01' } 'status check failed'
    Assert-True ((& $module { $script:environments.Count }) -eq 1) 'Failed health check removed a saved environment.'
    Write-Host 'PASS: pairing, repeat execution, duplicate protection and failed health checks'

    # Test Sync-OrcaGatewayEnvironments reconciliation, conflict protection, replacement, removal and ack safety.
    $syncStatePath = Join-Path $temp 'sync-state.json'
    & $module {
        $script:syncLocal = [ordered]@{ 'manual-node' = 'manual-node' }
        $script:syncRemote = @(
            [pscustomobject]@{ name = 'dev-01'; nodeId = 'id-1'; endpoint = 'ws://100.69.64.76:6769/node/dev-01'; grantStatus = 'pending' },
            [pscustomobject]@{ name = 'manual-node'; nodeId = 'id-m'; endpoint = 'ws://100.69.64.76:6769/node/manual-node'; grantStatus = 'pending' }
        )
        $script:syncAcked = @()
        $script:syncRemoved = @()
        $script:syncStatusFailFor = ''
        $script:syncUnauthorized = $false
        function script:Invoke-OrcaGatewayRequest {
            param($Method, $Uri, $Token, $Body, [switch]$UseSystemProxy, $TimeoutSec)
            if ($script:syncUnauthorized) { throw 'Gateway sync unauthorized (HTTP 401).' }
            if ($Method -ceq 'GET' -and $Uri -like '*/sync/state') {
                return [pscustomobject]@{ ok = $true; client = 'win-1'; nodes = $script:syncRemote }
            }
            if ($Method -ceq 'POST' -and $Uri -like '*/sync/claim') {
                return [pscustomobject]@{
                    ok    = $true
                    offer = [pscustomobject]@{ name = $Body.node; nodeId = 'id'; endpoint = 'ws://100.69.64.76:6769/node/' + $Body.node; pairingUrl = 'orca://pair?code=SYNC_OFFER_' + $Body.node }
                }
            }
            if ($Method -ceq 'POST' -and $Uri -like '*/sync/ack') {
                $script:syncAcked += "$($Body.node):$($Body.nodeId)"
                foreach ($n in $script:syncRemote) { if ($n.name -ceq $Body.node) { $n.grantStatus = 'claimed' } }
                return [pscustomobject]@{ ok = $true }
            }
            throw "Unexpected gateway call: $Method $Uri"
        }
        function script:Invoke-OrcaJson {
            param($Cli, $Arguments)
            switch ($Arguments[0] + ' ' + $Arguments[1]) {
                'environment list' {
                    return @{ environments = @($script:syncLocal.Values | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
                }
                'environment add' {
                    $n = $Arguments[3]
                    $script:syncLocal[$n] = $n
                    return @{}
                }
                'environment rm' {
                    $n = $Arguments[3]
                    $script:syncLocal.Remove($n)
                    $script:syncRemoved += $n
                    return @{}
                }
                'status --environment' {
                    $n = $Arguments[2]
                    if ($n -ceq $script:syncStatusFailFor) { throw 'status failed' }
                    return @{ graph = @{ state = 'ready' } }
                }
                default { throw "Unexpected CLI command: $($Arguments -join ' ')" }
            }
        }
    }

    # 1. Initial sync adds dev-01, skips unmanaged manual-node conflict, acks only dev-01.
    $r1 = Sync-OrcaGatewayEnvironments -Cli 'fixture' -Gateway 'http://100.69.64.76:6769' -Token 'tok' -StateFile $syncStatePath
    Assert-True ((@($r1.added) -join ',') -ceq 'dev-01') 'Expected dev-01 added.'
    Assert-True ((@($r1.conflicts) -join ',') -ceq 'manual-node') 'Expected manual-node conflict preserved.'
    Assert-True ((& $module { $script:syncAcked -join ',' }) -ceq 'dev-01:id-1') 'Expected only dev-01 acked.'

    # 2. Idempotent second run changes nothing.
    $r2 = Sync-OrcaGatewayEnvironments -Cli 'fixture' -Gateway 'http://100.69.64.76:6769' -Token 'tok' -StateFile $syncStatePath
    Assert-True (@($r2.added).Count -eq 0 -and @($r2.removed).Count -eq 0) 'Second sync was not idempotent.'

    # 3. Failed status check must NOT ack/burn the offer on the hub.
    & $module {
        $script:syncStatusFailFor = 'broken-node'
        $script:syncRemote += [pscustomobject]@{ name = 'broken-node'; nodeId = 'id-b'; endpoint = 'ws://100.69.64.76:6769/node/broken-node'; grantStatus = 'pending' }
    }
    $r3 = Sync-OrcaGatewayEnvironments -Cli 'fixture' -Gateway 'http://100.69.64.76:6769' -Token 'tok' -StateFile $syncStatePath
    Assert-True ((@($r3.failed) -join ',') -ceq 'sync:broken-node') 'Expected broken-node sync failure.'
    Assert-True ((& $module { $script:syncAcked -contains 'broken-node:id-b' }) -eq $false) 'Failed node must not be acked.'

    # 4. Removing dev-01 on hub removes managed env while preserving manual-node; -AdoptExisting adopts manual-node.
    & $module {
        $script:syncStatusFailFor = ''
        $script:syncRemote = @(
            [pscustomobject]@{ name = 'manual-node'; nodeId = 'id-m'; endpoint = 'ws://100.69.64.76:6769/node/manual-node'; grantStatus = 'pending' }
        )
    }
    $r4 = Sync-OrcaGatewayEnvironments -Cli 'fixture' -Gateway 'http://100.69.64.76:6769' -Token 'tok' -StateFile $syncStatePath
    Assert-True ((@($r4.removed) -join ',') -ceq 'dev-01') 'Removed hub node should be cleaned up locally.'
    Assert-True ((& $module { $script:syncLocal.Contains('manual-node') }) -eq $true) 'Unmanaged manual-node must stay intact.'
    $r5 = Sync-OrcaGatewayEnvironments -Cli 'fixture' -Gateway 'http://100.69.64.76:6769' -Token 'tok' -StateFile $syncStatePath -AdoptExisting
    Assert-True ((@($r5.replaced) -join ',') -ceq 'manual-node') 'Expected -AdoptExisting to replace manual-node.'

    # 5. Revoked token (HTTP 401) fails clearly without deleting local environments.
    & $module { $script:syncUnauthorized = $true }
    Expect-Failure { Sync-OrcaGatewayEnvironments -Cli 'fixture' -Gateway 'http://100.69.64.76:6769' -Token 'tok' -StateFile $syncStatePath } 'HTTP 401'
    Assert-True ((& $module { $script:syncLocal.Contains('manual-node') }) -eq $true) 'HTTP 401 must not delete local environments.'
    Write-Host 'PASS: Windows gateway sync handles additions, idempotency, ack safety, removals, unmanaged conflicts and HTTP 401'
}
finally {
    Remove-Module $module
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'Windows script tests passed. The Windows installer and desktop app were not executed.'
