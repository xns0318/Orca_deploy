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
}
finally {
    Remove-Module $module
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'Windows script tests passed. The Windows installer and desktop app were not executed.'
