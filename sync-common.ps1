Set-StrictMode -Version Latest

function Get-SyncConfig {
    [CmdletBinding()]
    param(
        [string]$ScriptRoot = $PSScriptRoot
    )

    $envPath = Join-Path $ScriptRoot ".env"
    $envFromFile = @{}

    if (Test-Path -LiteralPath $envPath) {
        foreach ($rawLine in Get-Content -LiteralPath $envPath) {
            $line = "$rawLine".Trim()
            if (-not $line -or $line.StartsWith("#")) {
                continue
            }

            $idx = $line.IndexOf("=")
            if ($idx -lt 1) {
                continue
            }

            $key = $line.Substring(0, $idx).Trim()
            $value = $line.Substring($idx + 1).Trim()

            if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            $envFromFile[$key] = $value
        }
    }

    function Resolve-ConfigValue {
        param(
            [string]$Name,
            [string]$Default
        )

        $processValue = [Environment]::GetEnvironmentVariable($Name, "Process")
        if (-not [string]::IsNullOrWhiteSpace($processValue)) {
            return $processValue
        }

        if ($envFromFile.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace($envFromFile[$Name])) {
            return $envFromFile[$Name]
        }

        return $Default
    }

    function Resolve-IntValue {
        param(
            [string]$Name,
            [int]$Default,
            [int]$Minimum
        )

        $raw = Resolve-ConfigValue -Name $Name -Default "$Default"
        $parsed = 0
        if (-not [int]::TryParse($raw, [ref]$parsed) -or $parsed -lt $Minimum) {
            throw "$Name must be an integer greater than or equal to $Minimum."
        }
        return $parsed
    }

    $qbtUrl = Resolve-ConfigValue -Name "QBT_URL" -Default "http://localhost:8080"
    $qbtUser = Resolve-ConfigValue -Name "QBT_USER" -Default ""
    $qbtPass = Resolve-ConfigValue -Name "QBT_PASS" -Default ""
    $defaultProtonVpnLogPath = Join-Path $env:LocalAppData "Proton\Proton VPN\Logs\client-logs.txt"
    $protonVpnLogPath = Resolve-ConfigValue -Name "PROTONVPN_LOG_PATH" -Default $defaultProtonVpnLogPath
    $protonAppPath = Resolve-ConfigValue -Name "PROTON_APP_PATH" -Default ""
    $protonServiceNamesRaw = Resolve-ConfigValue -Name "PROTON_SERVICE_NAMES" -Default "ProtonVPN Service"
    $defaultLogPath = Join-Path $env:LocalAppData "sync-ports\watch.log"
    $logPath = Resolve-ConfigValue -Name "SYNC_LOG_PATH" -Default $defaultLogPath
    $defaultStatusPath = Join-Path $env:LocalAppData "sync-ports\watch-status.json"
    $statusPath = Resolve-ConfigValue -Name "SYNC_STATUS_PATH" -Default $defaultStatusPath

    $heartbeatIntervalSeconds = Resolve-IntValue -Name "SYNC_HEARTBEAT_SECONDS" -Default 300 -Minimum 5
    $pollIntervalSeconds = Resolve-IntValue -Name "SYNC_POLL_SECONDS" -Default 10 -Minimum 1
    $protonPortStaleSeconds = Resolve-IntValue -Name "PROTON_PORT_STALE_SECONDS" -Default 180 -Minimum 1
    $firewallGraceSeconds = Resolve-IntValue -Name "QBT_FIREWALL_GRACE_SECONDS" -Default 180 -Minimum 10
    $reconnectCooldownSeconds = Resolve-IntValue -Name "RECONNECT_COOLDOWN_SECONDS" -Default 300 -Minimum 30

    $qbtDisableUpnpRaw = Resolve-ConfigValue -Name "QBT_DISABLE_UPNP" -Default "true"
    $autoReconnectRaw = Resolve-ConfigValue -Name "PROTON_AUTO_RECONNECT" -Default "true"

    $qbtDisableUpnp = $true
    switch -Regex ($qbtDisableUpnpRaw.Trim()) {
        "^(1|true|yes|on)$" { $qbtDisableUpnp = $true; break }
        "^(0|false|no|off)$" { $qbtDisableUpnp = $false; break }
        default { throw "QBT_DISABLE_UPNP must be true or false." }
    }

    $autoReconnect = $true
    switch -Regex ($autoReconnectRaw.Trim()) {
        "^(1|true|yes|on)$" { $autoReconnect = $true; break }
        "^(0|false|no|off)$" { $autoReconnect = $false; break }
        default { throw "PROTON_AUTO_RECONNECT must be true or false." }
    }

    $protonServiceNames = @($protonServiceNamesRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($protonServiceNames.Count -eq 0) {
        throw "PROTON_SERVICE_NAMES must list at least one Windows service name (comma-separated)."
    }

    if ([string]::IsNullOrWhiteSpace($qbtUser) -or [string]::IsNullOrWhiteSpace($qbtPass)) {
        throw "Missing qBittorrent credentials. Set QBT_USER and QBT_PASS in process env or .env."
    }

    return [pscustomobject]@{
        QbtUrl = $qbtUrl.TrimEnd("/")
        QbtUser = $qbtUser
        QbtPass = $qbtPass
        ProtonVpnLogPath = $protonVpnLogPath
        ProtonAppPath = $protonAppPath
        ProtonServiceNames = $protonServiceNames
        LogPath = $logPath
        StatusPath = $statusPath
        HeartbeatIntervalSeconds = $heartbeatIntervalSeconds
        PollIntervalSeconds = $pollIntervalSeconds
        ProtonPortStaleSeconds = $protonPortStaleSeconds
        FirewallGraceSeconds = $firewallGraceSeconds
        ReconnectCooldownSeconds = $reconnectCooldownSeconds
        QbtDisableUpnp = $qbtDisableUpnp
        AutoReconnect = $autoReconnect
    }
}

function Ensure-DirectoryForFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $directory = Split-Path -Path $FilePath -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
}

function Write-SyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO",
        [string]$LogPath
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"

    Write-Host $line

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Ensure-DirectoryForFile -FilePath $LogPath
        Add-Content -LiteralPath $LogPath -Value $line
    }
}

function Write-SyncStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatusPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Status
    )

    Ensure-DirectoryForFile -FilePath $StatusPath
    $Status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatusPath
}

function Test-IsNumericPort {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return $Value.Trim() -match "^\d+$"
}

function Get-ProtonPortHint {
    return "Waiting for a Proton VPN forwarded port. Enable Proton VPN port forwarding on a paid plan, connect to a P2P server, and turn on port forwarding in the Proton VPN app."
}

function Get-ProtonForwardPortStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [int]$StaleSeconds = 180,
        [int]$TailLines = 500
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return [pscustomobject]@{
            Port = $null
            State = "missing-log"
            Message = "$(Get-ProtonPortHint) Proton VPN log was not found at '$LogPath'."
            LineTimestamp = $null
            AgeSeconds = $null
        }
    }

    $linePattern = "^(?<timestamp>\d{4}-\d{2}-\d{2}T[^\s|]+)\s+\|\s+.*?\bPort pair\s+(?<publicPort>\d+)->(?<localPort>\d+)\b"
    $now = [datetimeoffset]::UtcNow
    $latest = $null

    foreach ($line in Get-Content -LiteralPath $LogPath -Tail $TailLines -ErrorAction Stop) {
        $match = [regex]::Match("$line", $linePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            continue
        }

        $publicPort = $match.Groups["publicPort"].Value
        $localPort = $match.Groups["localPort"].Value
        if ($publicPort -ne $localPort) {
            continue
        }

        try {
            $lineTimestamp = [datetimeoffset]::Parse($match.Groups["timestamp"].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            continue
        }

        if (-not $latest -or $lineTimestamp -gt $latest.LineTimestamp) {
            $latest = [pscustomobject]@{
                Port = $publicPort
                LineTimestamp = $lineTimestamp
            }
        }
    }

    if (-not $latest) {
        return [pscustomobject]@{
            Port = $null
            State = "no-port"
            Message = "$(Get-ProtonPortHint) No Proton port-forward log entry was found in the last $TailLines lines."
            LineTimestamp = $null
            AgeSeconds = $null
        }
    }

    $ageSeconds = [math]::Round(($now - $latest.LineTimestamp.ToUniversalTime()).TotalSeconds, 1)
    if ($ageSeconds -gt $StaleSeconds) {
        return [pscustomobject]@{
            Port = $null
            State = "stale-port"
            Message = "$(Get-ProtonPortHint) Latest Proton forwarded port $($latest.Port) is stale ($ageSeconds seconds old)."
            LineTimestamp = $latest.LineTimestamp.ToString("o")
            AgeSeconds = $ageSeconds
        }
    }

    return [pscustomobject]@{
        Port = $latest.Port
        State = "active"
        Message = "Active Proton forwarded port $($latest.Port)."
        LineTimestamp = $latest.LineTimestamp.ToString("o")
        AgeSeconds = $ageSeconds
    }
}

function Get-ProtonForwardPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,
        [int]$StaleSeconds = 180,
        [int]$RetryCount = 1,
        [int]$RetryDelaySeconds = 3
    )

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        $status = Get-ProtonForwardPortStatus -LogPath $LogPath -StaleSeconds $StaleSeconds

        if (Test-IsNumericPort -Value $status.Port) {
            return $status.Port
        }

        if ($attempt -lt $RetryCount) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    return $null
}

function Test-IsElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ProtonClientRunning {
    # The Proton VPN UI client (front-end), as opposed to the tunnel/connection services.
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like "ProtonVPN*" -and $_.Name -notlike "*Service*" -and $_.Name -notlike "*WireGuard*"
    })
    return ($procs.Count -gt 0)
}

function Restart-ProtonConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ServiceNames,
        [string]$ProtonAppPath,
        [string]$LogPath
    )

    if (-not (Test-IsElevated)) {
        Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "Cannot restart Proton services without elevation; skipping reconnect. Re-run install-task.ps1 so the scheduled task runs with highest privileges."
        return $false
    }

    $restarted = 0
    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "Proton service '$name' not found; skipping. Check PROTON_SERVICE_NAMES against 'Get-Service *Proton*'."
            continue
        }

        try {
            Restart-Service -Name $name -Force -ErrorAction Stop
            $restarted++
            Write-SyncLog -LogPath $LogPath -Message "Restarted Proton service '$name' to force a reconnect and fresh forwarded port."
        }
        catch {
            Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "Failed to restart Proton service '$name': $($_.Exception.Message)"
        }
    }

    # The client's auto-connect is what re-establishes the tunnel after the service restarts, so make
    # sure it's running (we never kill it; this only relaunches it if it had already exited).
    if (-not (Test-ProtonClientRunning)) {
        if (-not [string]::IsNullOrWhiteSpace($ProtonAppPath) -and (Test-Path -LiteralPath $ProtonAppPath)) {
            Start-Process -FilePath $ProtonAppPath
            Write-SyncLog -LogPath $LogPath -Message "Proton client was not running; relaunched '$ProtonAppPath'."
        }
        else {
            Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "Proton client is not running and PROTON_APP_PATH is unset/invalid, so auto-connect may not re-establish the tunnel. Set PROTON_APP_PATH to the Proton VPN client .exe."
        }
    }

    return ($restarted -gt 0)
}

function Get-QbtWebRequestParams {
    $webRequestParams = @{}
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
        $webRequestParams.UseBasicParsing = $true
    }
    return $webRequestParams
}

function Connect-Qbt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        [string]$QbtUser,
        [Parameter(Mandatory = $true)]
        [string]$QbtPass
    )

    $session = $null
    $webRequestParams = Get-QbtWebRequestParams

    $loginResponse = Invoke-WebRequest `
        -Uri "$QbtUrl/api/v2/auth/login" `
        -Method POST `
        -Headers @{ Referer = $QbtUrl } `
        -Body @{ username = $QbtUser; password = $QbtPass } `
        -SessionVariable session `
        -TimeoutSec 15 `
        @webRequestParams

    if ("$($loginResponse.Content)".Trim() -ne "Ok.") {
        $loginContent = "$($loginResponse.Content)".Trim()
        $sessionCookieCount = @($session.Cookies.GetCookies($QbtUrl)).Count
        $loginSucceeded = ([int]$loginResponse.StatusCode -eq 204 -and $sessionCookieCount -gt 0)

        if (-not $loginSucceeded) {
            throw "qBittorrent authentication failed. Login returned HTTP $([int]$loginResponse.StatusCode) with body '$loginContent'."
        }
    }

    return $session
}

function Set-QbtListenPort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [bool]$DisableUpnp = $true,
        [string]$QbtUser,
        [string]$QbtPass,
        $Session
    )

    if (-not $Session) {
        $Session = Connect-Qbt -QbtUrl $QbtUrl -QbtUser $QbtUser -QbtPass $QbtPass
    }

    $webRequestParams = Get-QbtWebRequestParams

    $prefs = @{ listen_port = $Port }
    if ($DisableUpnp) {
        $prefs.upnp = $false
    }

    $prefsJson = $prefs | ConvertTo-Json -Compress

    Invoke-WebRequest `
        -Uri "$QbtUrl/api/v2/app/setPreferences" `
        -Method POST `
        -Headers @{ Referer = $QbtUrl } `
        -WebSession $Session `
        -Body @{ json = $prefsJson } `
        @webRequestParams | Out-Null
}

function Get-QbtConnectionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        $Session
    )

    $webRequestParams = Get-QbtWebRequestParams

    $response = Invoke-WebRequest `
        -Uri "$QbtUrl/api/v2/transfer/info" `
        -Method GET `
        -Headers @{ Referer = $QbtUrl } `
        -WebSession $Session `
        @webRequestParams

    $info = "$($response.Content)" | ConvertFrom-Json
    return $info.connection_status
}

function Get-QbtActiveTorrentCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        $Session
    )

    $webRequestParams = Get-QbtWebRequestParams

    $response = Invoke-WebRequest `
        -Uri "$QbtUrl/api/v2/torrents/info?filter=active" `
        -Method GET `
        -Headers @{ Referer = $QbtUrl } `
        -WebSession $Session `
        @webRequestParams

    # Guard against Windows PowerShell 5.1 where an empty JSON array parses to $null and
    # @($null).Count would wrongly report 1; Where-Object drops the null.
    $torrents = @("$($response.Content)" | ConvertFrom-Json | Where-Object { $_ })
    return $torrents.Count
}
