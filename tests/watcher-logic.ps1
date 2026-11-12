# Offline tests for config parsing, port-reservation detection, the winnat bind/verify cycle and Proton
# log change events. Mocks netsh, sockets, winnat and the qBittorrent Web API; only writes to a temp folder.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'sync-common.ps1')

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sync-ports-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$global:SyncPortsTestFailures = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "PASS: $Name"
    }
    else {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        $global:SyncPortsTestFailures++
    }
}

function Assert-Calls {
    param([string[]]$Expected, [string]$Name)
    $actual = @($global:SyncPortsTestCalls)
    $match = ($actual -join ' | ') -eq ($Expected -join ' | ')
    if (-not $match) {
        Write-Host "  expected: $($Expected -join ' | ')"
        Write-Host "  actual:   $($actual -join ' | ')"
    }
    Assert-True $match $Name
}

$configNames = @('QBT_URL', 'QBT_USER', 'QBT_PASS', 'SYNC_POLL_SECONDS', 'QBT_POLL_SECONDS', 'WINNAT_AUTO_RESTART',
    'BIND_RETRY_COOLDOWN_SECONDS', 'QBT_BIND_ADDRESS', 'SYNC_LOG_PATH', 'SYNC_STATUS_PATH')
$savedEnv = @{}
try {
    # --- Config ---------------------------------------------------------------------------------------
    foreach ($name in $configNames) {
        $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    Set-Content -LiteralPath (Join-Path $testRoot '.env') -Value @('QBT_USER=u', 'QBT_PASS=p')
    $config = Get-SyncConfig -ScriptRoot $testRoot
    Assert-True ($config.PollIntervalSeconds -eq 30 -and $config.QbtPollIntervalSeconds -eq 15) 'default fallback log poll is 30s and qBittorrent poll is 15s'
    Assert-True ($config.WinnatAutoRestart -and $config.BindRetryCooldownSeconds -eq 600 -and $config.QbtBindAddress -eq '') 'winnat restart is on by default with a 600s retry cooldown'
    $env:WINNAT_AUTO_RESTART = 'off'
    $env:QBT_BIND_ADDRESS = '10.2.0.2'
    $config = Get-SyncConfig -ScriptRoot $testRoot
    Assert-True (-not $config.WinnatAutoRestart -and $config.QbtBindAddress -eq '10.2.0.2') 'WINNAT_AUTO_RESTART and QBT_BIND_ADDRESS overrides apply'
    $env:QBT_BIND_ADDRESS = 'not-an-ip'
    $threw = $false
    try { $null = Get-SyncConfig -ScriptRoot $testRoot } catch { $threw = $_.Exception.Message -like '*QBT_BIND_ADDRESS*' }
    Assert-True $threw 'rejects an invalid QBT_BIND_ADDRESS'
    $env:QBT_BIND_ADDRESS = $null
    $env:WINNAT_AUTO_RESTART = 'maybe'
    $threw = $false
    try { $null = Get-SyncConfig -ScriptRoot $testRoot } catch { $threw = $_.Exception.Message -like '*WINNAT_AUTO_RESTART*' }
    Assert-True $threw 'rejects a non-boolean WINNAT_AUTO_RESTART'
    $env:WINNAT_AUTO_RESTART = $null

    # --- netsh parsing --------------------------------------------------------------------------------
    $sample = @'
Protocol udp Port Exclusion Ranges

Start Port    End Port
----------    --------
     49665       49764
     50000       50059     *
     58982       59081
     64348       64447

* - Administered port exclusions.
'@ -split "`r?`n"
    $ranges = @(ConvertFrom-ExcludedPortRangeText -Lines $sample)
    Assert-True ($ranges.Count -eq 4) 'parses every excluded range row and ignores headers'
    Assert-True ($ranges[1].Start -eq 50000 -and $ranges[1].End -eq 50059 -and $ranges[1].Administered) 'flags administered exclusions'
    Assert-True ($ranges[2].Start -eq 58982 -and $ranges[2].End -eq 59081 -and -not $ranges[2].Administered) 'winnat ranges are not administered'
    Assert-True (@(ConvertFrom-ExcludedPortRangeText -Lines @('')).Count -eq 0) 'empty output has no ranges'

    # --- Collision detection --------------------------------------------------------------------------
    $global:SyncPortsTestRanges = @{ udp = $ranges; tcp = @() }
    $global:SyncPortsTestBind = @{}
    function Get-ExcludedPortRanges { param($Protocol) return $global:SyncPortsTestRanges[$Protocol] }
    function Test-PortBind {
        param($Address, $Port, $Protocol)
        $key = "$Protocol/$Port"
        if ($global:SyncPortsTestBind.ContainsKey($key)) { return $global:SyncPortsTestBind[$key] }
        return 'Ok'
    }

    $c = Get-PortCollision -Port 59076 -BindAddress '10.2.0.2'
    Assert-True ($c.Blocked -and $c.Fixable) 'a port in a winnat UDP block is blocked and fixable'
    $c = Get-PortCollision -Port 50010 -BindAddress '10.2.0.2'
    Assert-True ($c.Blocked -and -not $c.Fixable) 'an administered exclusion is blocked but not fixable'
    $c = Get-PortCollision -Port 42824 -BindAddress '10.2.0.2'
    Assert-True (-not $c.Blocked) 'a port outside every range is free'
    $global:SyncPortsTestBind['udp/42824'] = 'AccessDenied'
    $c = Get-PortCollision -Port 42824 -BindAddress '10.2.0.2'
    Assert-True ($c.Blocked -and $c.Fixable) 'a refused test bind alone counts as a collision'
    $global:SyncPortsTestBind['udp/42824'] = 'AddressAlreadyInUse'
    $c = Get-PortCollision -Port 42824 -BindAddress '10.2.0.2'
    Assert-True (-not $c.Blocked) 'a port in use is not a reservation'
    $global:SyncPortsTestBind.Clear()
    $c = Get-PortCollision -Port 59076 -BindAddress ''
    Assert-True ($c.Blocked -and $null -eq $c.UdpBind) 'skips the test bind when the address is unknown'

    # --- Restart-Winnat ordering ----------------------------------------------------------------------
    $global:SyncPortsTestCalls = New-Object System.Collections.Generic.List[string]
    $global:SyncPortsTestElevated = $true
    $global:SyncPortsTestWinnat = 'Running'
    $global:SyncPortsTestStopExit = 0
    function Test-IsElevated { return $global:SyncPortsTestElevated }
    function Get-WinnatState { return $global:SyncPortsTestWinnat }
    function Invoke-NetServiceCommand {
        param($Verb, $Name)
        $global:SyncPortsTestCalls.Add("net $Verb $Name")
        $code = if ($Verb -eq 'stop') { $global:SyncPortsTestStopExit } else { 0 }
        return [pscustomobject]@{ ExitCode = $code; Output = '' }
    }
    function Start-Sleep { param($Seconds, $Milliseconds) }
    $log = Join-Path $testRoot 'watch.log'

    $ok = Restart-Winnat -LogPath $log
    Assert-True $ok 'Restart-Winnat reports success'
    Assert-Calls @('net stop winnat', 'net start winnat') 'Restart-Winnat stops then starts winnat'
    $global:SyncPortsTestCalls.Clear()
    $global:SyncPortsTestStopExit = 2
    $ok = Restart-Winnat -LogPath $log
    Assert-True (-not $ok) 'a failed stop is reported'
    Assert-Calls @('net stop winnat', 'net start winnat') 'winnat is started again even when stopping failed'
    $global:SyncPortsTestCalls.Clear()
    $global:SyncPortsTestElevated = $false
    Assert-True (-not (Restart-Winnat -LogPath $log)) 'Restart-Winnat refuses without elevation'
    $global:SyncPortsTestElevated = $true
    $global:SyncPortsTestWinnat = $null
    Assert-True (-not (Restart-Winnat -LogPath $log)) 'Restart-Winnat skips a missing winnat driver'
    Assert-Calls @() 'no net commands run when winnat cannot be restarted'

    # --- Invoke-QbtPortBind ---------------------------------------------------------------------------
    $global:SyncPortsTestQbtPort = 0
    $global:SyncPortsTestStatus = New-Object System.Collections.Generic.Queue[string]
    function Get-QbtPreferences {
        param($QbtUrl, $Session)
        return [pscustomobject]@{ listen_port = $global:SyncPortsTestQbtPort; upnp = $false }
    }
    function Send-QbtPreferences {
        param($QbtUrl, $Session, $Preferences)
        $global:SyncPortsTestCalls.Add("set $($Preferences.listen_port)")
        $global:SyncPortsTestQbtPort = $Preferences.listen_port
    }
    function Get-QbtConnectionStatus {
        param($QbtUrl, $Session)
        $status = if ($global:SyncPortsTestStatus.Count) { $global:SyncPortsTestStatus.Dequeue() } else { 'disconnected' }
        $global:SyncPortsTestCalls.Add("status $status")
        return $status
    }
    function Restart-Winnat { param($LogPath) $global:SyncPortsTestCalls.Add('restart winnat'); return $true }

    $bindConfig = [pscustomobject]@{
        QbtUrl = 'http://localhost:8080'; LogPath = $log; QbtDisableUpnp = $true; WinnatAutoRestart = $true; QbtBindAddress = '10.2.0.2'
    }
    function Reset-QbtMock {
        param([int]$QbtPort, [string[]]$Statuses)
        $global:SyncPortsTestCalls.Clear()
        $global:SyncPortsTestStatus.Clear()
        foreach ($s in $Statuses) { $global:SyncPortsTestStatus.Enqueue($s) }
        $global:SyncPortsTestQbtPort = $QbtPort
    }

    Reset-QbtMock -QbtPort 59076 -Statuses @('firewalled')
    $r = Invoke-QbtPortBind -Config $bindConfig -Session 'S' -Port 59076 -VerifyTimeoutSeconds 0
    Assert-True ($r.Success -and $r.WinnatRestarts -eq 1 -and $r.Attempts -eq 1) 'blocked port already in qBittorrent: repaired in one attempt'
    Assert-Calls @('set 59077', 'restart winnat', 'set 59076', 'status firewalled') 'moves off the port, restarts winnat, then binds immediately'

    Reset-QbtMock -QbtPort 59076 -Statuses @('connected')
    $r = Invoke-QbtPortBind -Config $bindConfig -Session 'S' -Port 42824 -VerifyTimeoutSeconds 0
    Assert-True ($r.Success -and $r.WinnatRestarts -eq 0) 'a free new port is applied without restarting winnat'
    Assert-Calls @('set 42824', 'status connected') 'a free new port needs one request'

    Reset-QbtMock -QbtPort 1000 -Statuses @()
    $r = Invoke-QbtPortBind -Config $bindConfig -Session 'S' -Port 64400 -VerifyTimeoutSeconds 0
    Assert-True (-not $r.Success -and $r.Attempts -eq 2 -and $r.WinnatRestarts -eq 2) 'gives up after repeating the cycle once'
    Assert-Calls @('restart winnat', 'set 64400', 'status disconnected', 'set 64401', 'restart winnat', 'set 64400', 'status disconnected') 'the retry forces a rebind of the same port'

    $bindConfig.WinnatAutoRestart = $false
    Reset-QbtMock -QbtPort 59076 -Statuses @('disconnected', 'disconnected')
    $r = Invoke-QbtPortBind -Config $bindConfig -Session 'S' -Port 59076 -VerifyTimeoutSeconds 0 -MaxAttempts 1
    Assert-Calls @('set 59077', 'set 59076', 'status disconnected') 'WINNAT_AUTO_RESTART=false still rebinds but never restarts winnat'
    $bindConfig.WinnatAutoRestart = $true

    Reset-QbtMock -QbtPort 1000 -Statuses @('firewalled')
    $r = Invoke-QbtPortBind -Config $bindConfig -Session 'S' -Port 50010 -VerifyTimeoutSeconds 0
    Assert-Calls @('set 50010', 'status firewalled') 'an administered exclusion does not restart winnat'

    Reset-QbtMock -QbtPort 42824 -Statuses @('connected')
    $r = Invoke-QbtPortBind -Config $bindConfig -Session 'S' -Port 42824 -SkipIfListening -VerifyTimeoutSeconds 0
    Assert-True $r.Success '-SkipIfListening succeeds when qBittorrent already listens'
    Assert-Calls @('status connected') '-SkipIfListening leaves a working listener alone'

    # --- Set-QbtListenPort -ForceRebind ---------------------------------------------------------------
    Reset-QbtMock -QbtPort 65535 -Statuses @()
    Set-QbtListenPort -QbtUrl 'http://localhost:8080' -Port 65535 -Session 'S' -ForceRebind
    Assert-Calls @('set 65534', 'set 65535') 'ForceRebind reads the current port and bounces below 65535'
    Reset-QbtMock -QbtPort 0 -Statuses @()
    Set-QbtListenPort -QbtUrl 'http://localhost:8080' -Port 40000 -Session 'S' -ForceRebind -CurrentPort 39999
    Assert-Calls @('set 40000') 'ForceRebind sends one request when the port changes'

    # --- Proton log change events (real FileSystemWatcher) --------------------------------------------
    Remove-Item Function:\Start-Sleep
    $watchedLog = Join-Path $testRoot 'client-logs.txt'
    Set-Content -LiteralPath $watchedLog -Value 'start'
    $source = 'SyncPortsTest.Log'
    $watcher = Start-FileChangeWatcher -Path $watchedLog -SourceIdentifier $source
    try {
        Assert-True ($null -ne $watcher) 'starts a watcher on the log folder'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $changed = Wait-FileChange -SourceIdentifier $source -TimeoutSeconds 1
        Assert-True (-not $changed -and $sw.Elapsed.TotalSeconds -ge 0.9) 'returns false after the timeout when nothing is written'

        $job = Start-Job -ScriptBlock { param($Path) Start-Sleep -Seconds 2; Add-Content -LiteralPath $Path -Value 'Port pair 1->1' } -ArgumentList $watchedLog
        $sw.Restart()
        $changed = Wait-FileChange -SourceIdentifier $source -TimeoutSeconds 20
        $elapsed = $sw.Elapsed.TotalSeconds
        $job | Wait-Job | Remove-Job
        Assert-True ($changed -and $elapsed -lt 15) "wakes as soon as the log is written (after $([math]::Round($elapsed, 1))s, including job startup)"
        Assert-True (@(Get-Event | Where-Object { $_.SourceIdentifier -like "$source.*" }).Count -eq 0) 'drains the queued change events'
    }
    finally {
        Stop-FileChangeWatcher -Watcher $watcher -SourceIdentifier $source
    }
    Assert-True (@(Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "$source.*" }).Count -eq 0) 'stopping the watcher removes its event subscriptions'
    Assert-True ($null -eq (Start-FileChangeWatcher -Path (Join-Path $testRoot 'missing\client-logs.txt') -SourceIdentifier 'SyncPortsTest.Missing')) 'returns no watcher when the log folder is missing'
}
finally {
    foreach ($name in $configNames) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process') }
    # Delete only this test's verified, uniquely named temporary directory.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolvedRoot -Leaf) -match '^sync-ports-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

if ($global:SyncPortsTestFailures) {
    Write-Host "$($global:SyncPortsTestFailures) test(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All watcher logic tests passed.'
exit 0
