[CmdletBinding()]
param(
    [string]$TaskName = "SyncPorts-ProtonVPN-qBittorrent",
    [string]$LegacyTaskName = "SyncPorts-PIA-qBittorrent"
)

$ErrorActionPreference = "Stop"

$watchScriptPath = Join-Path $PSScriptRoot "watch-port.ps1"
if (-not (Test-Path -LiteralPath $watchScriptPath)) {
    throw "watch-port.ps1 not found at '$watchScriptPath'."
}

$powerShellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
$powerShellExe = if ($powerShellCommand) { $powerShellCommand.Source } else { "powershell.exe" }

$userId = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction `
    -Execute $powerShellExe `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScriptPath`"" `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$trigger.Delay = "PT30S"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -StartWhenAvailable `
    -Hidden

$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Keeps qBittorrent listen port synced with Proton VPN forwarded port via Proton VPN app log parsing, restarts winnat when the port is reserved by WSL/Docker NAT, and restarts Proton VPN services to recover a dead forwarded port." `
    -Force | Out-Null

if ($TaskName -ne $LegacyTaskName) {
    $legacyTask = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
    if ($legacyTask) {
        Stop-ScheduledTask -TaskName $LegacyTaskName
        Unregister-ScheduledTask -TaskName $LegacyTaskName -Confirm:$false
        Write-Host "Removed legacy scheduled task '$LegacyTaskName'."
    }
}

Write-Host "Scheduled task '$TaskName' created or updated for user '$userId'."
Write-Host "Executable: $powerShellExe"
