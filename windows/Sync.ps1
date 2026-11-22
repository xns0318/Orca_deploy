#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Gateway,
    [string]$Token,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs/Orca'),
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'orca-deploy'),
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [ValidateRange(15, 3600)][int]$IntervalSeconds = 60,
    [switch]$AdoptExisting,
    [switch]$UseSystemProxy,
    [switch]$CleanManaged,
    [switch]$RemoveConfig,
    [switch]$Quiet
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrcaDeploy.psm1') -Force
Assert-OrcaWindowsUser

if ($InstallTask -and $UninstallTask) {
    throw 'Specify either -InstallTask or -UninstallTask, not both.'
}
if ($StateDirectory -notmatch '^[A-Za-z]:[\\/]' -or $StateDirectory -match '["\r\n]') {
    throw '-StateDirectory must be an absolute local Windows path without quotes or newlines.'
}
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory).TrimEnd('\', '/')
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\', '/')
$configFile = Join-Path $StateDirectory 'sync-config.json'
$stateFile = Join-Path $StateDirectory 'sync-state.json'
$logFile = Join-Path $StateDirectory 'sync.log'
$vbsLauncher = Join-Path $StateDirectory 'sync-hidden.vbs'
$taskName = 'OrcaDeployGatewaySync'

function Write-SyncLog {
    param([string]$Message)
    $line = "[$([DateTimeOffset]::Now.ToString('o'))] $Message"
    if (-not $Quiet) { Write-Host $Message }
    try {
        if (-not (Test-Path -LiteralPath $StateDirectory)) {
            $null = New-Item -ItemType Directory -Path $StateDirectory -Force
        }
        if ((Test-Path -LiteralPath $logFile -PathType Leaf) -and (Get-Item -LiteralPath $logFile).Length -gt 262144) {
            Move-Item -LiteralPath $logFile -Destination "$logFile.old" -Force
        }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    }
    catch {}
}

if ($UninstallTask) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-SyncLog "Removed scheduled task '$taskName'."
    }
    else {
        Write-SyncLog "Scheduled task '$taskName' is not installed."
    }
    Remove-Item -LiteralPath $vbsLauncher -Force -ErrorAction SilentlyContinue
    if ($CleanManaged -and (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        $cli = Get-OrcaCliPath -InstallDirectory $InstallDirectory
        $raw = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $raw -and $null -ne $raw.PSObject.Properties['managed'] -and $null -ne $raw.managed) {
            foreach ($prop in $raw.managed.PSObject.Properties) {
                try {
                    Remove-OrcaEnvironment -Cli $cli -Name $prop.Name
                    Write-SyncLog "Removed managed Orca environment '$($prop.Name)'."
                }
                catch {
                    Write-SyncLog "Warning: could not remove '$($prop.Name)'."
                }
            }
        }
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    }
    if ($RemoveConfig) {
        Remove-Item -LiteralPath $configFile -Force -ErrorAction SilentlyContinue
        Write-SyncLog 'Removed saved gateway sync configuration.'
    }
    exit 0
}

$savedConfig = $null
if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    $savedConfig = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
}

$effectiveGateway = if ($Gateway) {
    $Gateway.TrimEnd('/')
}
elseif ($null -ne $savedConfig -and $null -ne $savedConfig.PSObject.Properties['gateway']) {
    [string]$savedConfig.gateway
}
else { '' }
if (-not $effectiveGateway) {
    throw 'Specify -Gateway http://<gateway-tailscale-ip>:6769 on first run.'
}
if ($effectiveGateway -notmatch '^https?://[^/\s]+$') {
    throw 'Gateway URL must be http(s)://host:port without a path.'
}

$effectiveProxy = if ($PSBoundParameters.ContainsKey('UseSystemProxy')) {
    [bool]$UseSystemProxy
}
elseif ($null -ne $savedConfig -and $null -ne $savedConfig.PSObject.Properties['useSystemProxy'] -and $null -ne $savedConfig.useSystemProxy) {
    [bool]$savedConfig.useSystemProxy
}
else { $false }

$effectiveToken = $null
if ($Token) {
    $effectiveToken = $Token.Trim()
}
elseif ($null -ne $savedConfig -and $null -ne $savedConfig.PSObject.Properties['protectedToken'] -and $savedConfig.protectedToken) {
    $effectiveToken = Unprotect-OrcaSecret -ProtectedBase64 ([string]$savedConfig.protectedToken)
}
elseif (-not $Quiet) {
    $secret = Read-Host 'Paste the Windows gateway sync token' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    try { $effectiveToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim() }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $secret.Dispose()
    }
}
if (-not $effectiveToken) {
    throw 'Missing gateway sync token. Run interactively with -Gateway and -Token once.'
}

# Persist config encrypted with Windows CurrentUser DPAPI when initialized or updated.
if ($Gateway -or $Token -or $PSBoundParameters.ContainsKey('UseSystemProxy') -or -not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    Write-OrcaJsonFileAtomic -Path $configFile -Value ([ordered]@{
        version        = 1
        gateway        = $effectiveGateway
        protectedToken = Protect-OrcaSecret -PlainText $effectiveToken
        useSystemProxy = $effectiveProxy
        installDir     = $InstallDirectory
    })
}

$cli = Get-OrcaCliPath -InstallDirectory $InstallDirectory

$mutex = [Threading.Mutex]::new($false, 'Local\OrcaDeployGatewaySync')
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) {
        Write-SyncLog 'Another Orca gateway sync is already running; skipping.'
        exit 0
    }

    $result = Sync-OrcaGatewayEnvironments -Cli $cli -Gateway $effectiveGateway -Token $effectiveToken `
        -StateFile $stateFile -AdoptExisting:$AdoptExisting -UseSystemProxy:$effectiveProxy

    if ($result.added.Count -gt 0) { Write-SyncLog ("Added nodes: " + ($result.added -join ', ')) }
    if ($result.replaced.Count -gt 0) { Write-SyncLog ("Replaced nodes: " + ($result.replaced -join ', ')) }
    if ($result.removed.Count -gt 0) { Write-SyncLog ("Removed nodes: " + ($result.removed -join ', ')) }
    if ($result.acked.Count -gt 0) { Write-SyncLog ("Confirmed pending offers: " + ($result.acked -join ', ')) }
    if ($result.conflicts.Count -gt 0) {
        Write-SyncLog ("WARNING: skipped non-managed conflicting local environment(s): " + ($result.conflicts -join ', ') + ' (pass -AdoptExisting to replace).')
    }
    if ($result.unprovisioned.Count -gt 0) {
        Write-SyncLog ("Pending host provisioning (run hub/sync-windows.sh on Docker host): " + ($result.unprovisioned -join ', '))
    }
    if ($result.failed.Count -gt 0) {
        Write-SyncLog ("WARNING: sync errors: " + ($result.failed -join ', '))
    }
    if ($result.added.Count -eq 0 -and $result.replaced.Count -eq 0 -and $result.removed.Count -eq 0 -and
        $result.conflicts.Count -eq 0 -and $result.failed.Count -eq 0 -and -not $Quiet) {
        Write-Host 'Orca gateway sync complete: all managed containers are up to date.'
    }
}
finally {
    $effectiveToken = $null
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

if ($InstallTask) {
    $scriptPath = [IO.Path]::GetFullPath($PSCommandPath)
    if ($scriptPath -match '["\r\n]' -or $InstallDirectory -match '["\r\n]' -or $StateDirectory -match '["\r\n]') {
        throw 'Paths contain unsupported characters for Scheduled Task registration.'
    }
    if (-not (Test-Path -LiteralPath $StateDirectory)) {
        $null = New-Item -ItemType Directory -Path $StateDirectory -Force
    }
    $taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -InstallDirectory `"$InstallDirectory`" -StateDirectory `"$StateDirectory`" -Quiet"
    $wscript = Get-Command 'wscript.exe' -ErrorAction SilentlyContinue
    if ($null -ne $wscript) {
        # Launch via GUI-subsystem wscript.exe (SW_HIDE=0) so Windows never flashes a console window.
        $escapedCmd = ('powershell.exe ' + $taskArgs).Replace('"', '""')
        $vbsBody = @(
            'Option Explicit'
            'Dim shell, cmd'
            'Set shell = CreateObject("WScript.Shell")'
            ('cmd = "' + $escapedCmd + '"')
            'WScript.Quit shell.Run(cmd, 0, True)'
        ) -join "`r`n"
        [IO.File]::WriteAllText($vbsLauncher, $vbsBody + "`r`n", [Text.Encoding]::Unicode)
        $action = New-ScheduledTaskAction -Execute $wscript.Source -Argument "//B //Nologo `"$vbsLauncher`""
    }
    else {
        $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe $taskArgs"
    }
    $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds($IntervalSeconds) `
        -RepetitionInterval (New-TimeSpan -Seconds $IntervalSeconds) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Limited
    $null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($repeatTrigger, $logonTrigger) `
        -Settings $settings -Principal $principal -Force
    Write-SyncLog "Installed silent background scheduled task '$taskName' (every ${IntervalSeconds}s)."
}
