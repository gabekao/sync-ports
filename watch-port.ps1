[CmdletBinding()]
param(
    [int]$QbtRetryDelaySeconds = 10
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\sync-common.ps1"

$script:LogEventSource = "SyncPorts.ProtonLog"

$script:Config = $null
$script:LastAppliedPort = $null
$script:PendingPort = $null
$script:LastRetryAt = $null
$script:WatcherStartedAt = $null
$script:LastPortStatus = $null
$script:LastLoggedPortMessage = $null
$script:ProtonLogWatcher = $null
$script:LastLogWatchMessage = $null

$script:QbtSession = $null
$script:NextLivenessAt = $null
$script:ConnectionStatus = $null
$script:ActiveTorrents = $null
$script:FirewalledSinceAt = $null
$script:DisconnectedSinceAt = $null
$script:StalePortSinceAt = $null
$script:LastReconnectAt = $null
$script:ReconnectCount = 0
$script:LastLoggedQbtError = $null
$script:LastLoggedLoopError = $null

$script:BindAddress = $null
$script:LastPortReservation = $null
$script:BindRepairCount = 0
$script:LastBindRepairAt = $null
$script:WinnatRestartCount = 0
$script:LastWinnatRestartAt = $null
$script:BindFailedPort = $null
$script:BindFailedAt = $null
$script:LastSkippedRepairMessage = $null

function Format-StatusTime {
    param($Time)
    if ($Time) {
        return $Time.ToString("o")
    }
    return $null
}

function Update-WatcherStatus {
    param(
        [string]$State,
        [switch]$HeartbeatOnly
    )

    $status = @{
        state = $State
        watcherPid = $PID
        watcherStartedAt = Format-StatusTime $script:WatcherStartedAt
        updatedAt = (Get-Date).ToString("o")
        lastHeartbeatAt = (Get-Date).ToString("o")
        lastAppliedPort = $script:LastAppliedPort
        pendingPort = $script:PendingPort
        protonPortState = $(if ($script:LastPortStatus) { $script:LastPortStatus.State } else { $null })
        protonPortAgeSeconds = $(if ($script:LastPortStatus) { $script:LastPortStatus.AgeSeconds } else { $null })
        protonPortTimestamp = $(if ($script:LastPortStatus) { $script:LastPortStatus.LineTimestamp } else { $null })
        logWatchMode = $(if ($script:ProtonLogWatcher) { "events" } else { "polling" })
        connectionStatus = $script:ConnectionStatus
        activeTorrents = $script:ActiveTorrents
        bindAddress = $script:BindAddress
        lastPortReservation = $script:LastPortReservation
        bindFailedPort = $script:BindFailedPort
        bindRepairCount = $script:BindRepairCount
        lastBindRepairAt = Format-StatusTime $script:LastBindRepairAt
        winnatRestartCount = $script:WinnatRestartCount
        lastWinnatRestartAt = Format-StatusTime $script:LastWinnatRestartAt
        reconnectCount = $script:ReconnectCount
        lastReconnectAt = Format-StatusTime $script:LastReconnectAt
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

function Write-SyncLogOnce {
    # Logs a message only when it differs from the last one stored in the named script variable.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO"
    )

    if ((Get-Variable -Name $Key -Scope Script -ValueOnly) -ne $Message) {
        Write-SyncLog -LogPath $script:Config.LogPath -Level $Level -Message $Message
        Set-Variable -Name $Key -Scope Script -Value $Message
    }
}

function Request-LivenessCheck {
    param(
        [int]$InSeconds = 0
    )

    $at = (Get-Date).AddSeconds($InSeconds)
    if (-not $script:NextLivenessAt -or $at -lt $script:NextLivenessAt) {
        $script:NextLivenessAt = $at
    }
}

function Start-ProtonLogWatcher {
    $logPath = $script:Config.ProtonVpnLogPath
    $pollSeconds = $script:Config.PollIntervalSeconds
    try {
        $script:ProtonLogWatcher = Start-FileChangeWatcher -Path $logPath -SourceIdentifier $script:LogEventSource
    }
    catch {
        $script:ProtonLogWatcher = $null
        Write-SyncLogOnce -Key "LastLogWatchMessage" -Level "WARN" -Message "Cannot watch the Proton VPN log for changes ($($_.Exception.Message)); re-reading it every ${pollSeconds}s instead."
        return
    }

    if ($script:ProtonLogWatcher) {
        Write-SyncLogOnce -Key "LastLogWatchMessage" -Message "Watching '$logPath' for changes; also re-reading it every ${pollSeconds}s."
    }
    else {
        Write-SyncLogOnce -Key "LastLogWatchMessage" -Message "Proton VPN log folder for '$logPath' does not exist yet; re-reading every ${pollSeconds}s until it appears."
    }
}

function Stop-ProtonLogWatcher {
    Stop-FileChangeWatcher -Watcher $script:ProtonLogWatcher -SourceIdentifier $script:LogEventSource
    $script:ProtonLogWatcher = $null
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
        # A new session usually means qBittorrent (re)started, and a restart can fail to bind a reserved
        # port again. Check its listener soon instead of waiting for the next poll.
        Request-LivenessCheck -InSeconds 3
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

function Invoke-BindPort {
    # Runs the detect/release/bind/verify cycle and records the outcome for status reporting.
    param(
        [Parameter(Mandatory = $true)]
        $Session,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        $Preferences
    )

    $result = Invoke-QbtPortBind -Config $script:Config -Session $Session -Port $Port -Reason $Reason -Preferences $Preferences

    $script:BindAddress = $result.BindAddress
    $script:ConnectionStatus = $result.ConnectionStatus
    if ($result.WinnatRestarts -gt 0) {
        $script:WinnatRestartCount += $result.WinnatRestarts
        $script:LastWinnatRestartAt = Get-Date
    }
    if ($result.Collision -and $result.Collision.Blocked) {
        $script:LastPortReservation = "port ${Port}: $($result.Collision.Reasons -join '; ')"
    }

    if ($result.Success) {
        $script:BindFailedPort = $null
        $script:BindFailedAt = $null
        $script:DisconnectedSinceAt = $null
    }
    else {
        $script:BindFailedPort = "$Port"
        $script:BindFailedAt = Get-Date
    }
    return $result
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
        $prefs = Get-QbtPreferences -QbtUrl $script:Config.QbtUrl -Session $session
        if ([int]$prefs.listen_port -eq [int]$Port) {
            # Already set, e.g. after a watcher restart. Leave the listener alone; the liveness check repairs
            # it if qBittorrent is not actually listening.
            if ($script:Config.QbtDisableUpnp -and ($prefs.PSObject.Properties.Name -contains "upnp") -and $prefs.upnp) {
                Send-QbtPreferences -QbtUrl $script:Config.QbtUrl -Session $session -Preferences @{ upnp = $false }
            }
            $script:LastAppliedPort = $Port
            $script:PendingPort = $null
            Write-SyncLog -LogPath $script:Config.LogPath -Message "qBittorrent already uses listen_port=$Port."
            Request-LivenessCheck
            Update-WatcherStatus -State "running" -HeartbeatOnly
            return
        }

        $result = Invoke-BindPort -Session $session -Port ([int]$Port) -Reason "Proton forwarded port changed" -Preferences $prefs
        $script:LastAppliedPort = $Port
        $script:PendingPort = $null
        Write-SyncLog -LogPath $script:Config.LogPath -Message "Applied listen_port=$Port to qBittorrent."
        Update-WatcherStatus -State $(if ($result.Success) { "running" } else { "port-blocked" }) -HeartbeatOnly
    }
    catch {
        $script:PendingPort = $Port
        $script:QbtSession = $null
        Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "Failed to apply listen_port=${Port}: $($_.Exception.Message)"
        Update-WatcherStatus -State "degraded" -HeartbeatOnly
    }
}

function Invoke-BindRepair {
    # qBittorrent has no listener on the port it was given. The usual cause is a Windows port reservation
    # that made its bind fail, at a port change or when qBittorrent restarted.
    $port = $script:LastAppliedPort
    $skip = $null
    if (-not $script:LastPortStatus -or $script:LastPortStatus.State -ne "active" -or $script:LastPortStatus.Port -ne $port) {
        $skip = "qBittorrent is disconnected, but Proton has no active forwarded port matching $port; waiting for Proton before rebinding."
    }
    elseif ($script:BindFailedPort -eq $port -and $script:BindFailedAt -and
        ((Get-Date) - $script:BindFailedAt).TotalSeconds -lt $script:Config.BindRetryCooldownSeconds) {
        $skip = "qBittorrent is still disconnected on port $port; retrying after the $($script:Config.BindRetryCooldownSeconds)s cooldown."
    }
    if ($skip) {
        Write-SyncLogOnce -Key "LastSkippedRepairMessage" -Message $skip
        return
    }
    $script:LastSkippedRepairMessage = $null

    $session = Get-QbtSession
    if (-not $session) {
        return
    }

    Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "qBittorrent is disconnected on listen_port=$port; checking for a Windows port reservation and rebinding."
    $script:BindRepairCount++
    $script:LastBindRepairAt = Get-Date
    try {
        $result = Invoke-BindPort -Session $session -Port ([int]$port) -Reason "qBittorrent disconnected"
        Update-WatcherStatus -State $(if ($result.Success) { "running" } else { "port-blocked" }) -HeartbeatOnly
    }
    catch {
        $script:QbtSession = $null
        $script:BindFailedPort = "$port"
        $script:BindFailedAt = Get-Date
        Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "Rebinding listen_port=$port failed: $($_.Exception.Message)"
    }
}

function Update-ProtonPortStatus {
    $script:LastPortStatus = Get-ProtonForwardPortStatus `
        -LogPath $script:Config.ProtonVpnLogPath `
        -StaleSeconds $script:Config.ProtonPortStaleSeconds

    if ($script:LastPortStatus.State -eq "active") {
        $script:StalePortSinceAt = $null
        $port = $script:LastPortStatus.Port
        if ($script:PendingPort -ne $port -and $script:LastAppliedPort -ne $port) {
            Invoke-ApplyPort -Port $port
            if ($script:PendingPort) {
                $script:LastRetryAt = Get-Date
            }
        }
        return
    }

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

    Write-SyncLogOnce -Key "LastLoggedPortMessage" -Message $script:LastPortStatus.Message
}

function Update-QbtLiveness {
    # Track qBittorrent's own view of inbound reachability. Only meaningful once we've pushed a port.
    if (-not $script:LastAppliedPort) {
        $script:FirewalledSinceAt = $null
        $script:DisconnectedSinceAt = $null
        return
    }

    $session = Get-QbtSession
    if (-not $session) {
        return
    }

    try {
        $script:ConnectionStatus = Get-QbtConnectionStatus -QbtUrl $script:Config.QbtUrl -Session $session
        # The torrent count only matters for the firewalled check, so skip that request otherwise.
        $script:ActiveTorrents = $null
        if ($script:ConnectionStatus -eq "firewalled") {
            $script:ActiveTorrents = Get-QbtActiveTorrentCount -QbtUrl $script:Config.QbtUrl -Session $session
        }
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

    # "disconnected" means qBittorrent has no listener at all, e.g. after its bind was refused.
    if ($script:ConnectionStatus -eq "disconnected") {
        # Confirm for a few seconds first: qBittorrent reports disconnected briefly while it starts or rebinds.
        $confirmSeconds = 5
        if (-not $script:DisconnectedSinceAt) {
            $script:DisconnectedSinceAt = Get-Date
        }
        $elapsed = ((Get-Date) - $script:DisconnectedSinceAt).TotalSeconds
        if ($elapsed -ge $confirmSeconds) {
            Invoke-BindRepair
        }
        else {
            Request-LivenessCheck -InSeconds ([int][math]::Ceiling($confirmSeconds - $elapsed))
        }
    }
    else {
        $script:DisconnectedSinceAt = $null
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

    Write-SyncLog -LogPath $script:Config.LogPath -Message "Watcher starting. AutoReconnect=$($script:Config.AutoReconnect) WinnatAutoRestart=$($script:Config.WinnatAutoRestart)."
    if (($script:Config.AutoReconnect -or $script:Config.WinnatAutoRestart) -and -not (Test-IsElevated)) {
        Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "This process is not elevated, so Proton service restarts and winnat restarts will be skipped. Re-run install-task.ps1 so the task runs with highest privileges."
    }
    Update-WatcherStatus -State "starting"

    $script:LastRetryAt = (Get-Date).AddSeconds(-$QbtRetryDelaySeconds)
    $script:NextLivenessAt = Get-Date
    $nextLogReadAt = Get-Date
    $nextHeartbeatAt = Get-Date

    while ($true) {
        # A transient failure in one pass (Proton rotating its log mid-read, a locked status file,
        # etc.) must not end the watcher: Task Scheduler does not restart a task whose script exits
        # with an error, so it would stay down until the next logon. Log it and retry shortly.
        try {
            if (-not $script:ProtonLogWatcher) {
                Start-ProtonLogWatcher
            }

            # Sleep until the next scheduled job, waking early when Windows reports a Proton log write.
            $dueTimes = @($nextLogReadAt, $script:NextLivenessAt, $nextHeartbeatAt)
            if ($script:PendingPort) {
                $dueTimes += $script:LastRetryAt.AddSeconds($QbtRetryDelaySeconds)
            }
            $nextDueAt = $dueTimes | Sort-Object | Select-Object -First 1
            $waitSeconds = ($nextDueAt - (Get-Date)).TotalSeconds

            $logChanged = $false
            if ($script:ProtonLogWatcher) {
                $logChanged = Wait-FileChange -SourceIdentifier $script:LogEventSource -TimeoutSeconds $waitSeconds
            }
            elseif ($waitSeconds -gt 0) {
                Start-Sleep -Milliseconds ([int][math]::Ceiling($waitSeconds * 1000))
            }

            if ($logChanged -or (Get-Date) -ge $nextLogReadAt) {
                Update-ProtonPortStatus
                $nextLogReadAt = (Get-Date).AddSeconds($script:Config.PollIntervalSeconds)
            }

            if ($script:PendingPort -and ((Get-Date) - $script:LastRetryAt).TotalSeconds -ge $QbtRetryDelaySeconds) {
                Invoke-ApplyPort -Port $script:PendingPort
                $script:LastRetryAt = Get-Date
            }

            if ((Get-Date) -ge $script:NextLivenessAt) {
                $script:NextLivenessAt = (Get-Date).AddSeconds($script:Config.QbtPollIntervalSeconds)
                Update-QbtLiveness
            }

            if ($script:Config.AutoReconnect) {
                $reason = Get-ReconnectReason
                if ($reason) {
                    $cooldownElapsed = (-not $script:LastReconnectAt) -or (((Get-Date) - $script:LastReconnectAt).TotalSeconds -ge $script:Config.ReconnectCooldownSeconds)
                    if ($cooldownElapsed) {
                        Invoke-Reconnect -Reason $reason
                    }
                }
            }

            if ((Get-Date) -ge $nextHeartbeatAt) {
                $heartbeatState = if ($script:PendingPort) { "degraded" } elseif ($script:BindFailedPort) { "port-blocked" } elseif ($script:LastPortStatus -and $script:LastPortStatus.State -eq "active") { "running" } else { "waiting-for-proton-port" }
                Update-WatcherStatus -State $heartbeatState -HeartbeatOnly
                $nextHeartbeatAt = (Get-Date).AddSeconds($script:Config.HeartbeatIntervalSeconds)
            }

            $script:LastLoggedLoopError = $null
        }
        catch {
            $loopError = $_.Exception.Message
            if ($script:LastLoggedLoopError -ne $loopError) {
                try {
                    Write-SyncLog -LogPath $script:Config.LogPath -Level "WARN" -Message "Watcher pass failed; retrying shortly: $loopError"
                }
                catch {
                    # Logging itself failed (for example, the log file is locked); keep going.
                }
                $script:LastLoggedLoopError = $loopError
            }
            # The failed pass may have skipped its sleep; back off so a persistent error cannot spin.
            Start-Sleep -Seconds 5
        }
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
            watcherStartedAt = Format-StatusTime $script:WatcherStartedAt
            updatedAt = (Get-Date).ToString("o")
            lastHeartbeatAt = (Get-Date).ToString("o")
            lastAppliedPort = $script:LastAppliedPort
            pendingPort = $script:PendingPort
            protonPortState = $(if ($script:LastPortStatus) { $script:LastPortStatus.State } else { $null })
            connectionStatus = $script:ConnectionStatus
            reconnectCount = $script:ReconnectCount
            winnatRestartCount = $script:WinnatRestartCount
            protonVpnLogPath = $(if ($script:Config) { $script:Config.ProtonVpnLogPath } else { $null })
            logPath = $logPath
            error = $_.Exception.Message
        }
    }
    exit 1
}
finally {
    Stop-ProtonLogWatcher
}
