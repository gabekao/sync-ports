[CmdletBinding()]
param([switch]$PauseOnExit)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\sync-common.ps1"

try {
    # Elevate before collecting credentials. Do not put credentials in command arguments.
    if (-not (Test-IsElevated)) {
        $originalUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        # A filtered administrator token still includes the Administrators group SID.
        $adminGroup = 'S-1-5-32-544'
        if ($adminGroup -notin @([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value)) {
            throw 'Run setup while signed in to the Windows administrator account that runs Proton VPN and qBittorrent. Do not elevate using a different user account.'
        }
        Write-Host "Requesting administrator access for $originalUser..."
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = Start-Process -FilePath $windowsPowerShell -Verb RunAs -Wait -PassThru `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -PauseOnExit"
        exit $child.ExitCode
    }

    Write-Host 'Sync Ports setup - automatic Proton VPN recovery is enabled by default.'
    Write-Host 'Keep this folder in place after setup; the scheduled task runs its scripts.'

    $envPath = Join-Path $PSScriptRoot '.env'
    if (-not (Test-Path -LiteralPath $envPath)) {
        $url = (Read-Host 'qBittorrent Web UI URL [http://localhost:8080]').Trim()
        if (-not $url) { $url = 'http://localhost:8080' }
        $uri = $null
        if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) {
            throw 'Enter an HTTP or HTTPS URL without embedded credentials.'
        }
        if ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback) {
            throw 'Use HTTPS for a remote qBittorrent Web UI, or use localhost for this PC.'
        }
        $username = (Read-Host 'qBittorrent Web UI username').Trim()
        $securePassword = Read-Host 'qBittorrent Web UI password' -AsSecureString
        $password = [System.Net.NetworkCredential]::new('', $securePassword).Password
        if (-not $username -or -not $password) { throw 'Username and password are required.' }
        # Quotes preserve leading/trailing password whitespace in the existing .env reader.
        foreach ($value in @($url, $username, $password)) {
            if ($value.Contains("`r") -or $value.Contains("`n")) { throw 'Configuration values must be a single line.' }
        }
        $client = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'ProtonVPN*' -and $_.Name -notlike '*Service*' -and $_.Name -notlike '*WireGuard*' -and $_.Path
        } | Select-Object -First 1
        $clientPath = if ($client) { $client.Path } else { '' }
        $lines = @(
            "QBT_URL=$url"
            "QBT_USER=`"$username`""
            "QBT_PASS=`"$password`""
            'PROTON_AUTO_RECONNECT=true'
            "PROTON_APP_PATH=$clientPath"
        )
        # Create an empty, restricted file before writing its credentials.
        New-Item -Path $envPath -ItemType File -ErrorAction Stop | Out-Null
        $acl = Get-Acl -LiteralPath $envPath
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')) {
            $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $envPath -AclObject $acl
        Set-Content -LiteralPath $envPath -Value $lines -Encoding UTF8
        $password = $null
        $lines = $null
        Write-Host 'Saved local configuration in .env (excluded from Git).'
    }
    else {
        Write-Host 'Using existing .env; edit that file to change credentials or settings.'
    }

    $config = Get-SyncConfig -ScriptRoot $PSScriptRoot
    if ($config.AutoReconnect) {
        foreach ($serviceName in $config.ProtonServiceNames) {
            if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                throw "Proton VPN service '$serviceName' was not found. Install Proton VPN or set PROTON_SERVICE_NAMES in .env."
            }
        }
    }
    if (-not (Test-Path -LiteralPath $config.ProtonVpnLogPath)) {
        Write-Warning 'Proton VPN log is not present yet. Open Proton VPN and connect with port forwarding enabled.'
    }
    Write-Host 'Checking qBittorrent Web UI login...'
    try {
        $null = Connect-Qbt -QbtUrl $config.QbtUrl -QbtUser $config.QbtUser -QbtPass $config.QbtPass
    }
    catch {
        throw 'Cannot log in to qBittorrent. Enable its Web UI and check QBT_URL, QBT_USER and QBT_PASS in .env, then rerun setup.'
    }

    $taskName = 'SyncPorts-ProtonVPN-qBittorrent'
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $taskName
        $stopDeadline = (Get-Date).AddSeconds(15)
        do {
            $task = Get-ScheduledTask -TaskName $taskName
            if ([string]$task.State -ne 'Running') { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $stopDeadline)
        if ([string]$task.State -eq 'Running') { throw 'Existing watcher did not stop; task registration was left unchanged.' }
    }
    & "$PSScriptRoot\install-task.ps1" -TaskName $taskName
    $startedAt = [datetimeoffset]::Now
    Start-ScheduledTask -TaskName $taskName

    Write-Host 'Waiting for the watcher heartbeat...'
    $deadline = (Get-Date).AddSeconds(30)
    $healthy = $false
    do {
        Start-Sleep -Seconds 1
        try {
            $status = Get-Content -LiteralPath $config.StatusPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($status.state -ne 'terminated' -and [datetimeoffset]::Parse($status.watcherStartedAt) -ge $startedAt -and
                [datetimeoffset]::Parse($status.lastHeartbeatAt) -ge $startedAt) {
                $watcher = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$status.watcherPid)"
                $scriptPath = Join-Path $PSScriptRoot 'watch-port.ps1'
                if ($watcher -and $watcher.CommandLine -and $watcher.CommandLine.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    [string](Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
                    $healthy = $true
                    break
                }
            }
        }
        catch { # The watcher may still be starting or replacing its status file.
        }
    } while ((Get-Date) -lt $deadline)
    if (-not $healthy) { throw "Task installed, but a fresh watcher heartbeat was not confirmed. Check $($config.LogPath) and run status.ps1." }
    Write-Host "Setup complete. Watcher is running; state=$($status.state)."
    Write-Host 'Port synchronization begins when Proton VPN reports a forwarded port.'
    Write-Host "Automatic Proton VPN recovery: $($config.AutoReconnect)."
}
catch {
    Write-Host "Setup failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($PauseOnExit) { $null = Read-Host 'Press Enter to close setup' }
}
