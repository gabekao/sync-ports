[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\sync-common.ps1"
if (-not (Test-IsElevated)) {
    throw 'Run this script in PowerShell as administrator, using the account that installed Sync Ports.'
}

$taskName = 'SyncPorts-ProtonVPN-qBittorrent'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Stopped and removed '$taskName'."
}
else {
    Write-Host 'Sync Ports task is not installed.'
}
Write-Host 'Configuration, scripts and logs were kept. Proton VPN and qBittorrent were left running.'
