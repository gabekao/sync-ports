[CmdletBinding()]
param(
    [string]$TaskName = "SyncPorts-ProtonVPN-qBittorrent"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\sync-common.ps1"

$config = Get-SyncConfig -ScriptRoot $PSScriptRoot
$status = $null

if (Test-Path -LiteralPath $config.StatusPath) {
    $status = Get-Content -LiteralPath $config.StatusPath -Raw | ConvertFrom-Json
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskState = if ($task) { [string]$task.State } else { "Missing" }

$processes = Get-CimInstance Win32_Process |
    Where-Object { $_.Name -in @("powershell.exe", "pwsh.exe") } |
    Where-Object { $_.CommandLine -match [regex]::Escape("watch-port.ps1") }

$watcherProcess = $null
if ($status -and $status.watcherPid) {
    $watcherProcess = $processes | Where-Object { $_.ProcessId -eq [int]$status.watcherPid } | Select-Object -First 1
}
if (-not $watcherProcess) {
    $watcherProcess = $processes | Select-Object -First 1
}

$heartbeatAgeSeconds = $null
$heartbeatFresh = $false
if ($status -and $status.lastHeartbeatAt) {
    $heartbeatAt = ConvertTo-SyncTimestamp $status.lastHeartbeatAt
    $heartbeatAgeSeconds = [math]::Round(([datetimeoffset]::Now - $heartbeatAt).TotalSeconds, 1)
    $heartbeatFresh = $heartbeatAgeSeconds -le ($config.HeartbeatIntervalSeconds + 30)
}

$effectiveState = "unknown"
if ($watcherProcess -and $heartbeatFresh) {
    $effectiveState = "running"
}
elseif ($watcherProcess) {
    $effectiveState = "stale-heartbeat"
}
elseif ($status -and $status.state -eq "terminated") {
    $effectiveState = "terminated"
}
elseif ($taskState -eq "Running") {
    $effectiveState = "starting"
}
elseif ($taskState -eq "Ready") {
    $effectiveState = "not-running"
}

function Get-StatusField {
    param([string]$Name)
    if ($status -and ($status.PSObject.Properties.Name -contains $Name)) {
        return $status.$Name
    }
    return $null
}

[pscustomobject]@{
    EffectiveState = $effectiveState
    TaskState = $taskState
    WatcherPid = if ($watcherProcess) { $watcherProcess.ProcessId } else { $null }
    ProtonPortState = Get-StatusField -Name "protonPortState"
    ProtonPortAgeSeconds = Get-StatusField -Name "protonPortAgeSeconds"
    ProtonPortTimestamp = Get-StatusField -Name "protonPortTimestamp"
    ConnectionStatus = Get-StatusField -Name "connectionStatus"
    ActiveTorrents = Get-StatusField -Name "activeTorrents"
    LastAppliedPort = Get-StatusField -Name "lastAppliedPort"
    PendingPort = Get-StatusField -Name "pendingPort"
    ReconnectCount = Get-StatusField -Name "reconnectCount"
    LastReconnectAt = Get-StatusField -Name "lastReconnectAt"
    ProtonVpnLogPath = $config.ProtonVpnLogPath
    LastHeartbeatAt = Get-StatusField -Name "lastHeartbeatAt"
    HeartbeatAgeSeconds = $heartbeatAgeSeconds
    StatusPath = $config.StatusPath
    LogPath = $config.LogPath
    LastError = Get-StatusField -Name "error"
} | Format-List
