[CmdletBinding()]
param(
    [int]$QbtRetryDelaySeconds = 10
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\sync-common.ps1"

$script:Config = $null
$script:LastAppliedPort = $null
$script:PendingPort = $null
$script:WatcherStartedAt = $null
$script:LastPortStatus = $null
$script:LastLoggedPortMessage = $null

$script:QbtSession = $null
$script:ConnectionStatus = $null
$script:ActiveTorrents = $null
$script:FirewalledSinceAt = $null
$script:StalePortSinceAt = $null
$script:LastReconnectAt = $null
$script:ReconnectCount = 0
$script:LastLoggedQbtError = $null
$script:LastLoggedLoopError = $null

function Update-WatcherStatus {
    param(
        [string]$State,
        [switch]$HeartbeatOnly
    )

    $status = @{
        state = $State
        watcherPid = $PID
        watcherStartedAt = $(if ($script:WatcherStartedAt) { $script:WatcherStartedAt.ToString("o") } else { $null })
        updatedAt = (Get-Date).ToString("o")
        lastHeartbeatAt = (Get-Date).ToString("o")
        lastAppliedPort = $script:LastAppliedPort
        pendingPort = $script:PendingPort
        protonPortState = $(if ($script:LastPortStatus) { $script:LastPortStatus.State } else { $null })
        protonPortAgeSeconds = $(if ($script:LastPortStatus) { $script:LastPortStatus.AgeSeconds } else { $null })
        protonPortTimestamp = $(if ($script:LastPortStatus) { $script:LastPortStatus.LineTimestamp } else { $null })
        connectionStatus = $script:ConnectionStatus
        activeTorrents = $script:ActiveTorrents
        reconnectCount = $script:ReconnectCount
        lastReconnectAt = $(if ($script:LastReconnectAt) { $script:LastReconnectAt.ToString("o") } else { $null })
        protonVpnLogPath = $script:Config.ProtonVpnLogPath
        logPath = $script:Config.LogPath
    }

    Write-SyncStatus -StatusPath $script:Config.StatusPath -Status $status

    if (-not $HeartbeatOnly) {
        $details = "state=$State watcherPid=$PID"
        if ($script:LastPortStatus -and $script:LastPortStatus.State) {
            $details += " protonPortState=$($script:LastPortStatus.State)"
        }
        if ($script:LastAppliedPort) {
            $details += " lastAppliedPort=$($script:LastAppliedPort)"
        }
        if ($script:ConnectionStatus) {
            $details += " connectionStatus=$($script:ConnectionStatus)"
        }
        Write-SyncLog -LogPath $script:Config.LogPath -Message "Watcher status updated: $details"
    }
}

function Get-QbtSession {
    if ($script:QbtSession) {
        return $script:QbtSession
    }

    try {
        $script:QbtSession = Connect-Qbt `
            -QbtUrl $script:Config.QbtUrl `
            -QbtUser $script:Config.QbtUser `
            -QbtPass $script:Config.QbtPass
        $script:LastLoggedQbtError = $null
        return $script:QbtSession
    }
    catch {
        if ($script:LastLoggedQbtError -ne $_.Exception.Message) {
            Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "qBittorrent connection failed: $($_.Exception.Message)"
            $script:LastLoggedQbtError = $_.Exception.Message
        }
        return $null
    }
}

function Invoke-ApplyPort {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Port
    )

    if ($script:LastAppliedPort -eq $Port) {
        $script:PendingPort = $null
        return
    }

    $session = Get-QbtSession
    if (-not $session) {
        $script:PendingPort = $Port
        Update-WatcherStatus -State "degraded" -HeartbeatOnly
        return
    }

    try {
        Set-QbtListenPort `
            -QbtUrl $script:Config.QbtUrl `
            -Port ([int]$Port) `
            -DisableUpnp $script:Config.QbtDisableUpnp `
            -Session $session

        $script:LastAppliedPort = $Port
        $script:PendingPort = $null
        Write-SyncLog -LogPath $script:Config.LogPath -Message "Applied listen_port=$Port to qBittorrent."
        Update-WatcherStatus -State "running" -HeartbeatOnly
    }
    catch {
        $script:PendingPort = $Port
        $script:QbtSession = $null
        Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "Failed to apply listen_port=${Port}: $($_.Exception.Message)"
        Update-WatcherStatus -State "degraded" -HeartbeatOnly
    }
}

function Update-QbtLiveness {
    # Track qBittorrent's own view of inbound reachability. Only meaningful once we've pushed a port.
    if (-not $script:LastAppliedPort) {
        $script:FirewalledSinceAt = $null
        return
    }

    $session = Get-QbtSession
    if (-not $session) {
        return
    }

    try {
        $script:ConnectionStatus = Get-QbtConnectionStatus -QbtUrl $script:Config.QbtUrl -Session $session
        $script:ActiveTorrents = Get-QbtActiveTorrentCount -QbtUrl $script:Config.QbtUrl -Session $session
        $script:LastLoggedQbtError = $null
    }
    catch {
        $script:QbtSession = $null
        if ($script:LastLoggedQbtError -ne $_.Exception.Message) {
            Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "qBittorrent liveness check failed: $($_.Exception.Message)"
            $script:LastLoggedQbtError = $_.Exception.Message
        }
        return
    }

    # Only count "firewalled" when qBittorrent is actually trying to use the port (active torrents
    # present); idle/pre-download firewalled readings are a known false positive.
    if ($script:ConnectionStatus -eq "firewalled" -and $script:ActiveTorrents -ge 1) {
        if (-not $script:FirewalledSinceAt) {
            $script:FirewalledSinceAt = Get-Date
        }
    }
    else {
        $script:FirewalledSinceAt = $null
    }
}

function Get-ReconnectReason {
    $grace = $script:Config.FirewallGraceSeconds

    if ($script:FirewalledSinceAt -and ((Get-Date) - $script:FirewalledSinceAt).TotalSeconds -ge $grace) {
        return "qBittorrent has been firewalled for $([math]::Round(((Get-Date) - $script:FirewalledSinceAt).TotalSeconds))s with $($script:ActiveTorrents) active torrent(s)"
    }

    if ($script:StalePortSinceAt -and ((Get-Date) - $script:StalePortSinceAt).TotalSeconds -ge $grace) {
        return "Proton forwarded port has been stale for $([math]::Round(((Get-Date) - $script:StalePortSinceAt).TotalSeconds))s"
    }

    return $null
}

function Invoke-Reconnect {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "Triggering Proton reconnect ($Reason)."
    Restart-ProtonConnection `
        -ServiceNames $script:Config.ProtonServiceNames `
        -ProtonAppPath $script:Config.ProtonAppPath `
        -LogPath $script:Config.LogPath | Out-Null

    $script:ReconnectCount++
    $script:LastReconnectAt = Get-Date
    # Reset the failure timers; give Proton time to reconnect and the log watcher time to pick up
    # the fresh port. If it's still dead after the cooldown, we'll trigger again.
    $script:FirewalledSinceAt = $null
    $script:StalePortSinceAt = $null
    Update-WatcherStatus -State "reconnecting" -HeartbeatOnly
}

try {
    $script:Config = Get-SyncConfig -ScriptRoot $PSScriptRoot
    $script:WatcherStartedAt = Get-Date

    Write-SyncLog -LogPath $script:Config.LogPath -Message "Watcher starting. AutoReconnect=$($script:Config.AutoReconnect)."
    if ($script:Config.AutoReconnect -and -not (Test-IsElevated)) {
        Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "AutoReconnect is on but this process is not elevated; Proton service restarts will be skipped. Re-run install-task.ps1 so the task runs with highest privileges."
    }
    Update-WatcherStatus -State "starting"

    $lastRetryAt = (Get-Date).AddSeconds(-$QbtRetryDelaySeconds)
    $lastHeartbeatAt = (Get-Date).AddSeconds(-$script:Config.HeartbeatIntervalSeconds)

    while ($true) {
        # A transient failure in one poll (Proton rotating its log mid-read, a locked status file,
        # etc.) must not end the watcher: Task Scheduler does not restart a task whose script exits
        # with an error, so it would stay down until the next logon. Log it and retry next poll.
        try {
            $script:LastPortStatus = Get-ProtonForwardPortStatus `
                -LogPath $script:Config.ProtonVpnLogPath `
                -StaleSeconds $script:Config.ProtonPortStaleSeconds

            if ($script:LastPortStatus.State -eq "active") {
                $script:StalePortSinceAt = $null
                $port = $script:LastPortStatus.Port
                if ($script:PendingPort -ne $port -and $script:LastAppliedPort -ne $port) {
                    Invoke-ApplyPort -Port $port
                    if ($script:PendingPort) {
                        $lastRetryAt = Get-Date
                    }
                }
            }
            else {
                # Only treat a stale port as a death signal once we've actually applied a port before;
                # missing-log / no-port at startup is the normal "waiting" state, not a failure.
                if ($script:LastPortStatus.State -eq "stale-port" -and $script:LastAppliedPort) {
                    if (-not $script:StalePortSinceAt) {
                        $script:StalePortSinceAt = Get-Date
                    }
                }
                else {
                    $script:StalePortSinceAt = $null
                }

                if ($script:LastLoggedPortMessage -ne $script:LastPortStatus.Message) {
                    Write-SyncLog -LogPath $script:Config.LogPath -Level "INFO" -Message $script:LastPortStatus.Message
                    $script:LastLoggedPortMessage = $script:LastPortStatus.Message
                }
            }

            if ($script:PendingPort -and ((Get-Date) - $lastRetryAt).TotalSeconds -ge $QbtRetryDelaySeconds) {
                Invoke-ApplyPort -Port $script:PendingPort
                $lastRetryAt = Get-Date
            }

            Update-QbtLiveness

            if ($script:Config.AutoReconnect) {
                $reason = Get-ReconnectReason
                if ($reason) {
                    $cooldownElapsed = (-not $script:LastReconnectAt) -or (((Get-Date) - $script:LastReconnectAt).TotalSeconds -ge $script:Config.ReconnectCooldownSeconds)
                    if ($cooldownElapsed) {
                        Invoke-Reconnect -Reason $reason
                    }
                }
            }

            if (((Get-Date) - $lastHeartbeatAt).TotalSeconds -ge $script:Config.HeartbeatIntervalSeconds) {
                $heartbeatState = if ($script:PendingPort) { "degraded" } elseif ($script:LastPortStatus.State -eq "active") { "running" } else { "waiting-for-proton-port" }
                Update-WatcherStatus -State $heartbeatState -HeartbeatOnly
                $lastHeartbeatAt = Get-Date
            }

            $script:LastLoggedLoopError = $null
        }
        catch {
            $loopError = $_.Exception.Message
            if ($script:LastLoggedLoopError -ne $loopError) {
                try {
                    Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "Poll failed; retrying next interval: $loopError"
                }
                catch {
                    # Logging itself failed (for example, the log file is locked); keep polling.
                }
                $script:LastLoggedLoopError = $loopError
            }
        }

        Start-Sleep -Seconds $script:Config.PollIntervalSeconds
    }
}
catch {
    $logPath = $null
    $statusPath = $null
    if ($script:Config -and $script:Config.PSObject.Properties.Name -contains "LogPath") {
        $logPath = $script:Config.LogPath
    }
    if ($script:Config -and $script:Config.PSObject.Properties.Name -contains "StatusPath") {
        $statusPath = $script:Config.StatusPath
    }

    Write-SyncLog -LogPath $logPath -Level "ERROR" -Message "Watcher terminated: $($_.Exception.Message)"
    if ($statusPath) {
        Write-SyncStatus -StatusPath $statusPath -Status @{
            state = "terminated"
            watcherPid = $PID
            watcherStartedAt = $(if ($script:WatcherStartedAt) { $script:WatcherStartedAt.ToString("o") } else { $null })
            updatedAt = (Get-Date).ToString("o")
            lastHeartbeatAt = (Get-Date).ToString("o")
            lastAppliedPort = $script:LastAppliedPort
            pendingPort = $script:PendingPort
            protonPortState = $(if ($script:LastPortStatus) { $script:LastPortStatus.State } else { $null })
            connectionStatus = $script:ConnectionStatus
            reconnectCount = $script:ReconnectCount
            protonVpnLogPath = $(if ($script:Config) { $script:Config.ProtonVpnLogPath } else { $null })
            logPath = $logPath
            error = $_.Exception.Message
        }
    }
    exit 1
}
