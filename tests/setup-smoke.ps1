# Offline installer smoke test. Uses a temporary copy and mocks every task,
# process, service and network boundary; does not touch the installed watcher.
param([switch]$FailLogin)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sync-ports-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' | Copy-Item -Destination $testRoot

$overrides = @'

function Test-IsElevated { return $true }
function Connect-Qbt {
    param($QbtUrl, $QbtUser, $QbtPass)
    if ($global:SyncPortsTestFailLogin) { throw 'Simulated authentication failure.' }
    if ($QbtUrl -ne 'http://localhost:8080' -or $QbtUser -ne 'test-user' -or $QbtPass -cne ' test"pass=''word ') {
        throw 'Synthetic credentials did not round-trip correctly.'
    }
    return 'fake-session'
}
'@
Add-Content -LiteralPath (Join-Path $testRoot 'sync-common.ps1') -Value $overrides

$global:SyncPortsTestregistered = $false
$global:SyncPortsTestFailLogin = [bool]$FailLogin
$global:SyncPortsTesttaskState = 'Ready'
$global:SyncPortsTeststopped = 0
$global:SyncPortsTestremoved = $false
$global:SyncPortsTestprompts = 0
function Read-Host {
    param($Prompt, [switch]$AsSecureString)
    $global:SyncPortsTestprompts++
    if ($AsSecureString) { return ConvertTo-SecureString ' test"pass=''word ' -AsPlainText -Force }
    if ($Prompt -like '*username*') { return 'test-user' }
    return ''
}
function Get-Process { return [pscustomobject]@{Name='ProtonVPN'; Path='C:\Test Apps\ProtonVPN.exe'} }
function Get-Service { param($Name) return [pscustomobject]@{Name=$Name} }
function Get-ScheduledTask {
    param($TaskName)
    if ($TaskName -eq 'SyncPorts-ProtonVPN-qBittorrent' -and $global:SyncPortsTestregistered) {
        return [pscustomobject]@{State=$global:SyncPortsTesttaskState}
    }
}
function Stop-ScheduledTask { param($TaskName) $global:SyncPortsTeststopped++; $global:SyncPortsTesttaskState='Ready' }
function New-ScheduledTaskAction {
    param($Execute, $Argument, $WorkingDirectory)
    return [pscustomobject]@{Execute=$Execute; Arguments=$Argument; WorkingDirectory=$WorkingDirectory}
}
function New-ScheduledTaskTrigger {
    param([switch]$AtLogOn, $User)
    return [pscustomobject]@{Delay=''; User=$User}
}
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$DontStopOnIdleEnd,
        $MultipleInstances, $RestartCount, $RestartInterval, [timespan]$ExecutionTimeLimit,
        [switch]$StartWhenAvailable, [switch]$Hidden)
    if ($ExecutionTimeLimit -ne [timespan]::Zero) { throw 'Unexpected execution limit.' }
    return [pscustomobject]@{ExecutionTimeLimit='PT0S'}
}
function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return [pscustomobject]@{UserId=$UserId} }
function Register-ScheduledTask {
    param($TaskName, $Action, $Trigger, $Settings, $Principal, $Description, [switch]$Force)
    if ($Settings.ExecutionTimeLimit -ne 'PT0S') { throw 'Watcher has an execution time limit.' }
    if ($Action.WorkingDirectory -ne $testRoot) { throw 'Wrong task directory.' }
    if ($Action.Arguments -notlike '*-WindowStyle Hidden*') { throw 'Task does not request a hidden window.' }
    $global:SyncPortsTestregistered = $true
}
function Start-ScheduledTask {
    param($TaskName)
    $global:SyncPortsTesttaskState = 'Running'
    @{
        state = 'waiting-for-proton-port'
        watcherStartedAt = [datetimeoffset]::Now.ToString('o')
        lastHeartbeatAt = [datetimeoffset]::Now.ToString('o')
        watcherPid = 12345
    } | ConvertTo-Json | Set-Content -LiteralPath $env:SYNC_STATUS_PATH
}
function Get-CimInstance {
    param($ClassName, $Filter)
    return [pscustomobject]@{CommandLine='powershell.exe -File "' + (Join-Path $testRoot 'watch-port.ps1') + '"'}
}
function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm) $global:SyncPortsTestremoved=$true }
function Start-Sleep { param($Seconds, $Milliseconds) }

$savedEnv = @{}
$names = @('QBT_URL','QBT_USER','QBT_PASS','PROTON_AUTO_RECONNECT','PROTON_SERVICE_NAMES','SYNC_STATUS_PATH','SYNC_LOG_PATH')
try {
    foreach ($name in $names) {
        $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $env:SYNC_STATUS_PATH = Join-Path $testRoot 'status.json'
    $env:SYNC_LOG_PATH = Join-Path $testRoot 'watch.log'
    & (Join-Path $testRoot 'setup.ps1')
    if ($FailLogin) {
        if ($LASTEXITCODE -ne 1 -or $global:SyncPortsTestregistered -or $global:SyncPortsTeststopped -ne 0) {
            throw 'Login failure did not stop setup before task changes.'
        }
        Write-Host 'PASS: failed login blocks task registration/start.'
        exit 0
    }
    if (-not $global:SyncPortsTestregistered -or $global:SyncPortsTestprompts -ne 3) { throw 'New installation failed.' }
    $configFile = Join-Path $testRoot '.env'
    $before = (Get-FileHash -LiteralPath $configFile).Hash
    $acl = Get-Acl -LiteralPath $configFile
    if (-not $acl.AreAccessRulesProtected -or @($acl.Access | Where-Object IsInherited).Count) {
        throw 'New credentials file has inherited permissions.'
    }
    & (Join-Path $testRoot 'setup.ps1')
    if ((Get-FileHash -LiteralPath $configFile).Hash -ne $before -or $global:SyncPortsTestprompts -ne 3 -or $global:SyncPortsTeststopped -ne 1) {
        throw 'Reinstall did not preserve configuration and restart the previous task.'
    }
    & (Join-Path $testRoot 'uninstall-task.ps1')
    if (-not $global:SyncPortsTestremoved -or $global:SyncPortsTeststopped -ne 2 -or -not (Test-Path -LiteralPath $configFile)) {
        throw 'Uninstall did not stop/remove the task and preserve configuration.'
    }
    Write-Host 'PASS: fresh setup, credential round-trip, restricted ACL, repeat setup, heartbeat and uninstall.'
}
finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
    # Delete only this test's verified, uniquely named temporary directory.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedRoot -Leaf) -match '^sync-ports-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
