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

    function Resolve-BoolValue {
        param(
            [string]$Name,
            [bool]$Default
        )

        $raw = Resolve-ConfigValue -Name $Name -Default $(if ($Default) { "true" } else { "false" })
        switch -Regex ($raw.Trim()) {
            "^(1|true|yes|on)$" { return $true }
            "^(0|false|no|off)$" { return $false }
        }
        throw "$Name must be true or false."
    }

    $heartbeatIntervalSeconds = Resolve-IntValue -Name "SYNC_HEARTBEAT_SECONDS" -Default 300 -Minimum 5
    # Fallback re-read of the Proton log, which also re-evaluates port staleness. File-change events
    # trigger a read whenever Proton writes.
    $pollIntervalSeconds = Resolve-IntValue -Name "SYNC_POLL_SECONDS" -Default 30 -Minimum 1
    $qbtPollIntervalSeconds = Resolve-IntValue -Name "QBT_POLL_SECONDS" -Default 15 -Minimum 5
    $protonPortStaleSeconds = Resolve-IntValue -Name "PROTON_PORT_STALE_SECONDS" -Default 180 -Minimum 1
    $firewallGraceSeconds = Resolve-IntValue -Name "QBT_FIREWALL_GRACE_SECONDS" -Default 180 -Minimum 10
    $reconnectCooldownSeconds = Resolve-IntValue -Name "RECONNECT_COOLDOWN_SECONDS" -Default 300 -Minimum 30
    $bindRetryCooldownSeconds = Resolve-IntValue -Name "BIND_RETRY_COOLDOWN_SECONDS" -Default 600 -Minimum 60

    $qbtDisableUpnp = Resolve-BoolValue -Name "QBT_DISABLE_UPNP" -Default $true
    $autoReconnect = Resolve-BoolValue -Name "PROTON_AUTO_RECONNECT" -Default $true
    $winnatAutoRestart = Resolve-BoolValue -Name "WINNAT_AUTO_RESTART" -Default $true

    $qbtBindAddress = ([string](Resolve-ConfigValue -Name "QBT_BIND_ADDRESS" -Default "")).Trim()
    if ($qbtBindAddress) {
        $parsedAddress = $null
        if (-not [System.Net.IPAddress]::TryParse($qbtBindAddress, [ref]$parsedAddress) -or
            $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "QBT_BIND_ADDRESS must be an IPv4 address."
        }
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
        QbtPollIntervalSeconds = $qbtPollIntervalSeconds
        ProtonPortStaleSeconds = $protonPortStaleSeconds
        FirewallGraceSeconds = $firewallGraceSeconds
        ReconnectCooldownSeconds = $reconnectCooldownSeconds
        BindRetryCooldownSeconds = $bindRetryCooldownSeconds
        QbtDisableUpnp = $qbtDisableUpnp
        AutoReconnect = $autoReconnect
        WinnatAutoRestart = $winnatAutoRestart
        QbtBindAddress = $qbtBindAddress
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

function ConvertTo-SyncTimestamp {
    # PowerShell 7's ConvertFrom-Json turns ISO 8601 strings into [datetime]; passing that to
    # [datetimeoffset]::Parse() round-trips through a culture string and drops sub-second precision.
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [datetimeoffset]) {
        return $Value
    }
    if ($Value -is [datetime]) {
        return [datetimeoffset]$Value
    }
    return [datetimeoffset]::Parse("$Value", [System.Globalization.CultureInfo]::InvariantCulture)
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

function ConvertFrom-ExcludedPortRangeText {
    # Parses `netsh interface ipv4 show excludedportrange` output. Rows are "<start> <end>", with a
    # trailing "*" on administered (persistent) exclusions; headers are localized, so match rows only.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $ranges = @()
    foreach ($line in @($Lines)) {
        $match = [regex]::Match("$line", "^\s*(\d+)\s+(\d+)\s*(\*)?\s*$")
        if ($match.Success) {
            $ranges += [pscustomobject]@{
                Start = [int]$match.Groups[1].Value
                End = [int]$match.Groups[2].Value
                Administered = $match.Groups[3].Success
            }
        }
    }
    return $ranges
}

function Get-ExcludedPortRanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("udp", "tcp")]
        [string]$Protocol
    )

    # Keep native stderr from becoming a terminating error under Windows PowerShell 5.1.
    $ErrorActionPreference = "Continue"
    $output = @(& netsh.exe interface ipv4 show excludedportrange "protocol=$Protocol" 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "netsh could not list excluded $Protocol port ranges (exit $LASTEXITCODE): $($output -join ' ')"
    }
    return @(ConvertFrom-ExcludedPortRangeText -Lines $output)
}

function Test-PortBind {
    # Tries a throwaway bind. Returns "Ok", or the socket error name: AccessDenied (WSAEACCES, the port is
    # reserved), AddressAlreadyInUse (something holds it), AddressNotAvailable (the adapter has no such IP).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [ValidateSet("udp", "tcp")]
        [string]$Protocol
    )

    $socketType = if ($Protocol -eq "udp") { [System.Net.Sockets.SocketType]::Dgram } else { [System.Net.Sockets.SocketType]::Stream }
    $protocolType = if ($Protocol -eq "udp") { [System.Net.Sockets.ProtocolType]::Udp } else { [System.Net.Sockets.ProtocolType]::Tcp }
    $socket = New-Object System.Net.Sockets.Socket -ArgumentList ([System.Net.Sockets.AddressFamily]::InterNetwork), $socketType, $protocolType
    try {
        $socket.Bind((New-Object System.Net.IPEndPoint -ArgumentList ([System.Net.IPAddress]::Parse($Address)), $Port))
        return "Ok"
    }
    catch {
        $exception = $_.Exception
        while ($exception -and -not ($exception -is [System.Net.Sockets.SocketException])) {
            $exception = $exception.InnerException
        }
        if ($exception) {
            return [string]$exception.SocketErrorCode
        }
        return "Error: $($_.Exception.Message)"
    }
    finally {
        $socket.Dispose()
    }
}

function Get-PortCollision {
    # Checks whether Windows will refuse to bind the port, as happens when Hyper-V/WSL's NAT driver (winnat)
    # reserves a block of the dynamic range that contains it. qBittorrent then drops its whole listener.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,
        # Address qBittorrent binds to; when empty, the independent test bind is skipped.
        [string]$BindAddress
    )

    $reasons = @()
    $winnatRange = $false
    $administeredRange = $false

    foreach ($protocol in @("udp", "tcp")) {
        try {
            $ranges = @(Get-ExcludedPortRanges -Protocol $protocol)
        }
        catch {
            $reasons += "could not list excluded $protocol ranges: $($_.Exception.Message)"
            continue
        }
        foreach ($range in $ranges) {
            if ($Port -ge $range.Start -and $Port -le $range.End) {
                $label = "$($protocol.ToUpper()) $($range.Start)-$($range.End)"
                if ($range.Administered) {
                    $administeredRange = $true
                    $reasons += "$label (administered exclusion)"
                }
                else {
                    $winnatRange = $true
                    $reasons += "$label reserved"
                }
            }
        }
    }

    $bindResults = @{ udp = $null; tcp = $null }
    $bindRefused = $false
    if (-not [string]::IsNullOrWhiteSpace($BindAddress)) {
        foreach ($protocol in @("udp", "tcp")) {
            $bindResults[$protocol] = Test-PortBind -Address $BindAddress -Port $Port -Protocol $protocol
            if ($bindResults[$protocol] -eq "AccessDenied") {
                $bindRefused = $true
                $reasons += "test $($protocol.ToUpper()) bind on ${BindAddress}:$Port refused (WSAEACCES)"
            }
        }
    }

    $blocked = $winnatRange -or $administeredRange -or $bindRefused
    return [pscustomobject]@{
        Port = $Port
        Blocked = $blocked
        # Restarting winnat releases its own reservations, not administered exclusions.
        Fixable = $winnatRange -or ($bindRefused -and -not $administeredRange)
        Reasons = $reasons
        UdpBind = $bindResults.udp
        TcpBind = $bindResults.tcp
    }
}

function Get-WinnatState {
    $driver = Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='winnat'" -ErrorAction SilentlyContinue
    if (-not $driver) {
        return $null
    }
    return [string]$driver.State
}

function Invoke-NetServiceCommand {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("start", "stop")]
        [string]$Verb,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $ErrorActionPreference = "Continue"
    $output = @(& net.exe $Verb $Name 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join " ")
    }
}

function Restart-Winnat {
    # Stops and starts the Windows NAT driver, which releases the port blocks it reserved for Hyper-V/WSL/Docker.
    # Returns $true once the reservations were released. WSL/Docker NAT networking drops while it restarts.
    [CmdletBinding()]
    param(
        [string]$LogPath
    )

    if (-not (Test-IsElevated)) {
        Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "Cannot restart winnat without elevation, so the reserved port stays blocked. Re-run install-task.ps1 so the scheduled task runs with highest privileges."
        return $false
    }

    $state = Get-WinnatState
    if (-not $state) {
        Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "The winnat driver is not installed, so restarting it cannot release this reservation."
        return $false
    }
    if ($state -ne "Running") {
        Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "winnat is '$state', so the reservation is not from winnat; it was not restarted."
        return $false
    }

    Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "Restarting winnat to release its port reservations; WSL/Docker NAT networking drops briefly."
    $stop = Invoke-NetServiceCommand -Verb stop -Name "winnat"
    # Start it again even if stopping failed: leaving winnat stopped breaks WSL/Docker networking.
    $start = Invoke-NetServiceCommand -Verb start -Name "winnat"
    if ($start.ExitCode -ne 0 -and (Get-WinnatState) -ne "Running") {
        Start-Sleep -Seconds 1
        $start = Invoke-NetServiceCommand -Verb start -Name "winnat"
    }

    if ($start.ExitCode -ne 0 -and (Get-WinnatState) -ne "Running") {
        Write-SyncLog -LogPath $LogPath -Level "ERROR" -Message "winnat did not start again (net start exit $($start.ExitCode): $($start.Output)). WSL/Docker networking stays down until 'net start winnat' is run as administrator."
    }
    if ($stop.ExitCode -ne 0) {
        Write-SyncLog -LogPath $LogPath -Level "WARN" -Message "net stop winnat failed (exit $($stop.ExitCode): $($stop.Output))."
        return $false
    }
    return $true
}

function Start-FileChangeWatcher {
    # Raises PowerShell events "<SourceIdentifier>.<event>" when the file is written, created or renamed.
    # Returns $null when the folder does not exist yet. Windows sends these notifications once the write
    # cache reaches disk, which was measured at 5-8 s after each Proton log write.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$SourceIdentifier
    )

    $directory = Split-Path -Path $Path -Parent
    $fileName = Split-Path -Path $Path -Leaf
    if (-not $directory -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
        return $null
    }

    $watcher = New-Object System.IO.FileSystemWatcher -ArgumentList $directory, $fileName
    try {
        $watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size -bor [System.IO.NotifyFilters]::FileName
        foreach ($eventName in @("Changed", "Created", "Renamed", "Error")) {
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier "$SourceIdentifier.$eventName" | Out-Null
        }
        $watcher.EnableRaisingEvents = $true
        return $watcher
    }
    catch {
        Stop-FileChangeWatcher -Watcher $watcher -SourceIdentifier $SourceIdentifier
        throw
    }
}

function Stop-FileChangeWatcher {
    param(
        $Watcher,
        [Parameter(Mandatory = $true)]
        [string]$SourceIdentifier
    )

    Get-EventSubscriber -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -like "$SourceIdentifier.*" } |
        ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }
    Get-Event -ErrorAction SilentlyContinue |
        Where-Object { $_.SourceIdentifier -like "$SourceIdentifier.*" } |
        Remove-Event -ErrorAction SilentlyContinue
    if ($Watcher) {
        $Watcher.EnableRaisingEvents = $false
        $Watcher.Dispose()
    }
}

function Wait-FileChange {
    # Blocks until a Start-FileChangeWatcher event arrives or the timeout passes. Returns $true on a change.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceIdentifier,
        [double]$TimeoutSeconds = 0,
        # Pause after the first event so a burst of writes is handled by one read.
        [int]$SettleMilliseconds = 200
    )

    $pattern = "$SourceIdentifier.*"
    $deadline = (Get-Date).AddSeconds([math]::Max(0, $TimeoutSeconds))
    while (-not @(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like $pattern }).Count) {
        $remaining = ($deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) {
            return $false
        }
        $nextEvent = Wait-Event -Timeout ([int][math]::Ceiling($remaining))
        if (-not $nextEvent) {
            return $false
        }
        if ($nextEvent.SourceIdentifier -notlike $pattern) {
            # Not ours; drop it so it cannot wake this loop again.
            $nextEvent | Remove-Event -ErrorAction SilentlyContinue
        }
    }

    if ($SettleMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $SettleMilliseconds
    }
    Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like $pattern } | Remove-Event -ErrorAction SilentlyContinue
    return $true
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

function Get-QbtPreferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        $Session
    )

    $webRequestParams = Get-QbtWebRequestParams

    $response = Invoke-WebRequest `
        -Uri "$QbtUrl/api/v2/app/preferences" `
        -Method GET `
        -Headers @{ Referer = $QbtUrl } `
        -WebSession $Session `
        @webRequestParams

    return ("$($response.Content)" | ConvertFrom-Json)
}

function Send-QbtPreferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        $Session,
        [Parameter(Mandatory = $true)]
        [hashtable]$Preferences
    )

    $webRequestParams = Get-QbtWebRequestParams
    $prefsJson = $Preferences | ConvertTo-Json -Compress

    Invoke-WebRequest `
        -Uri "$QbtUrl/api/v2/app/setPreferences" `
        -Method POST `
        -Headers @{ Referer = $QbtUrl } `
        -WebSession $Session `
        -Body @{ json = $prefsJson } `
        @webRequestParams | Out-Null
}

function Get-TemporaryListenPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    if ($Port -lt 65535) {
        return $Port + 1
    }
    return $Port - 1
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
        $Session,
        # qBittorrent ignores a listen_port equal to its current one, so it never retries a listener that
        # failed to open. -ForceRebind switches to a neighbouring port first so the real port is a change.
        [switch]$ForceRebind,
        # qBittorrent's current listen_port, if already known; otherwise -ForceRebind reads it.
        [int]$CurrentPort = -1
    )

    if (-not $Session) {
        $Session = Connect-Qbt -QbtUrl $QbtUrl -QbtUser $QbtUser -QbtPass $QbtPass
    }

    if ($ForceRebind) {
        if ($CurrentPort -lt 0) {
            $CurrentPort = [int](Get-QbtPreferences -QbtUrl $QbtUrl -Session $Session).listen_port
        }
        if ($CurrentPort -eq $Port) {
            Send-QbtPreferences -QbtUrl $QbtUrl -Session $Session -Preferences @{ listen_port = (Get-TemporaryListenPort -Port $Port) }
            # Let qBittorrent apply the temporary port first, or it can merge both changes into no change.
            Start-Sleep -Milliseconds 500
        }
    }

    $prefs = @{ listen_port = $Port }
    if ($DisableUpnp) {
        $prefs.upnp = $false
    }

    Send-QbtPreferences -QbtUrl $QbtUrl -Session $Session -Preferences $prefs
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

function Wait-QbtListening {
    # Polls until qBittorrent reports a listener (connected or firewalled) or the timeout passes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QbtUrl,
        [Parameter(Mandatory = $true)]
        $Session,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    # Give qBittorrent a moment to drop the old listener so a stale "firewalled" isn't read as success.
    Start-Sleep -Milliseconds 1500
    while ($true) {
        $status = Get-QbtConnectionStatus -QbtUrl $QbtUrl -Session $Session
        if ($status -in @("connected", "firewalled") -or (Get-Date) -ge $deadline) {
            return $status
        }
        Start-Sleep -Seconds 1
    }
}

function Resolve-QbtBindAddress {
    # The IPv4 address qBittorrent listens on: QBT_BIND_ADDRESS, else qBittorrent's bound address, else the
    # address of its bound adapter (e.g. ProtonVPN), else 0.0.0.0 when it listens on every interface.
    # Returns $null when it is bound to an adapter without an IPv4 address (VPN down).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        $Preferences
    )

    if ($Config.QbtBindAddress) {
        return $Config.QbtBindAddress
    }
    if (-not $Preferences) {
        return $null
    }

    $names = @($Preferences.PSObject.Properties.Name)
    if ($names -contains "current_interface_address") {
        $address = "$($Preferences.current_interface_address)".Trim()
        $parsed = $null
        if ($address -and [System.Net.IPAddress]::TryParse($address, [ref]$parsed) -and
            $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $address
        }
    }

    if ($names -contains "current_interface_name") {
        $alias = "$($Preferences.current_interface_name)".Trim()
        if ($alias) {
            $ip = $null
            try {
                $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            }
            catch {
                $ip = $null
            }
            if ($ip) {
                return [string]$ip.IPAddress
            }
            return $null
        }
    }

    if (($names -contains "current_network_interface") -and "$($Preferences.current_network_interface)".Trim()) {
        return $null
    }
    return "0.0.0.0"
}

function Invoke-QbtPortBind {
    # Gives qBittorrent the port and makes sure it can actually listen on it:
    #   1. detect a Windows port reservation (netsh excluded ranges, plus a test bind),
    #   2. release it by restarting winnat (only on a real collision),
    #   3. push the port right away, forcing a rebind even if it is unchanged,
    #   4. verify qBittorrent is connected/firewalled; otherwise repeat once.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $Session,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [string]$Reason = "port update",
        # qBittorrent preferences, if already fetched.
        $Preferences,
        # Do nothing if qBittorrent already listens on this port.
        [switch]$SkipIfListening,
        [int]$MaxAttempts = 2,
        [int]$VerifyTimeoutSeconds = 15
    )

    $logPath = $Config.LogPath
    if (-not $Preferences) {
        $Preferences = Get-QbtPreferences -QbtUrl $Config.QbtUrl -Session $Session
    }
    $qbtPort = [int]$Preferences.listen_port

    $result = [pscustomobject]@{
        Port = $Port
        Success = $false
        ConnectionStatus = $null
        Attempts = 0
        WinnatRestarts = 0
        Collision = $null
        BindAddress = (Resolve-QbtBindAddress -Config $Config -Preferences $Preferences)
    }

    if ($SkipIfListening -and $qbtPort -eq $Port) {
        $status = Get-QbtConnectionStatus -QbtUrl $Config.QbtUrl -Session $Session
        if ($status -in @("connected", "firewalled")) {
            $result.Success = $true
            $result.ConnectionStatus = $status
            return $result
        }
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result.Attempts = $attempt

        # 1. Detect.
        $collision = Get-PortCollision -Port $Port -BindAddress $result.BindAddress
        $result.Collision = $collision

        # 2. Release. Restarting winnat briefly drops WSL/Docker NAT networking, so only on a real collision.
        if ($collision.Blocked) {
            Write-SyncLog -LogPath $logPath -Level "WARN" -Message "listen_port=$Port is reserved by Windows: $($collision.Reasons -join '; ')."
            if (-not $collision.Fixable) {
                Write-SyncLog -LogPath $logPath -Level "ERROR" -Message "Port $Port is in an administered port exclusion, which restarting winnat does not release. Remove it with 'netsh interface ipv4 delete excludedportrange' or reconnect Proton VPN for a new port."
            }
            elseif (-not $Config.WinnatAutoRestart) {
                Write-SyncLog -LogPath $logPath -Level "WARN" -Message "WINNAT_AUTO_RESTART is off, so winnat was not restarted to release port $Port."
            }
            else {
                if ($qbtPort -eq $Port) {
                    # Move off the port first, so the push right after winnat restarts is a change and takes one request.
                    $temporaryPort = Get-TemporaryListenPort -Port $Port
                    Set-QbtListenPort -QbtUrl $Config.QbtUrl -Port $temporaryPort -DisableUpnp $Config.QbtDisableUpnp -Session $Session
                    $qbtPort = $temporaryPort
                    Start-Sleep -Milliseconds 500
                }
                if (Restart-Winnat -LogPath $logPath) {
                    $result.WinnatRestarts++
                }
            }
        }

        # 3. Bind immediately. WSL/Docker re-reserve port blocks soon after winnat starts; an open socket survives that.
        Set-QbtListenPort -QbtUrl $Config.QbtUrl -Port $Port -DisableUpnp $Config.QbtDisableUpnp -Session $Session -ForceRebind -CurrentPort $qbtPort
        $qbtPort = $Port

        # 4. Verify.
        $result.ConnectionStatus = Wait-QbtListening -QbtUrl $Config.QbtUrl -Session $Session -TimeoutSeconds $VerifyTimeoutSeconds
        if ($result.ConnectionStatus -in @("connected", "firewalled")) {
            $result.Success = $true
            Write-SyncLog -LogPath $logPath -Message "qBittorrent is listening on port $Port (connection_status=$($result.ConnectionStatus))."
            return $result
        }
        Write-SyncLog -LogPath $logPath -Level "WARN" -Message "qBittorrent is still '$($result.ConnectionStatus)' on port $Port after attempt $attempt of $MaxAttempts."
    }

    Write-SyncLog -LogPath $logPath -Level "ERROR" -Message "qBittorrent could not listen on port $Port after $MaxAttempts attempts ($Reason). Look for 'Failed to listen' in qBittorrent's log."
    return $result
}
