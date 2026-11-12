[CmdletBinding()]
param(
    [int]$RetryCount = 1,
    [int]$RetryDelaySeconds = 3
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\sync-common.ps1"

$config = $null
try {
    $config = Get-SyncConfig -ScriptRoot $PSScriptRoot
    Write-SyncLog -LogPath $config.LogPath -Message "Running one-shot sync."

    $port = Get-ProtonForwardPort `
        -LogPath $config.ProtonVpnLogPath `
        -StaleSeconds $config.ProtonPortStaleSeconds `
        -RetryCount $RetryCount `
        -RetryDelaySeconds $RetryDelaySeconds

    if (-not (Test-IsNumericPort -Value $port)) {
        $status = Get-ProtonForwardPortStatus -LogPath $config.ProtonVpnLogPath -StaleSeconds $config.ProtonPortStaleSeconds
        throw $status.Message
    }

    $session = Connect-Qbt -QbtUrl $config.QbtUrl -QbtUser $config.QbtUser -QbtPass $config.QbtPass
    $result = Invoke-QbtPortBind -Config $config -Session $session -Port ([int]$port) -Reason "one-shot sync" -SkipIfListening
    if (-not $result.Success) {
        throw "qBittorrent is '$($result.ConnectionStatus)' on listen_port=$port."
    }

    Write-SyncLog -LogPath $config.LogPath -Message "Applied listen_port=$port to qBittorrent (connection_status=$($result.ConnectionStatus))."
}
catch {
    # $config is null when loading configuration was what failed; still report the real error.
    $logPath = if ($config) { $config.LogPath } else { $null }
    Write-SyncLog -LogPath $logPath -Level "ERROR" -Message $_.Exception.Message
    exit 1
}
