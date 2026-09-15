<#
.SYNOPSIS
    Restart quant-qmt-proxy services (both accounts).
    Designed to run daily before market open (e.g. 08:00 via Task Scheduler).
.DESCRIPTION
    1. Stop all proxy processes (run.py / start.py)
    2. Wait for clean shutdown
    3. Start both account proxies (020 and 666)
    4. Verify they're listening on expected ports
#>

param(
    # Readiness wait, in minutes: how long to wait for the trading channel to be
    # up before touching the services.  The logon task runs -WaitMinutes 15.
    #
    # 2026-09-15 17:31 -- CHINESE COMMENTS *INSIDE* param() BROKE THIS PARAMETER
    # LIST.  This file is UTF-8 WITHOUT BOM, and Windows PowerShell 5.1 decodes a
    # BOM-less .ps1 as ANSI/GBK, so a Chinese comment here decoded into stray
    # quote/paren characters and the parameter declaration was destroyed:
    # $WaitMinutes came out $null, `-WaitMinutes 15` was never bound, the wait
    # loop exited on its first test and the script aborted with
    #     === ABORTED: channels not ready within  min ...   <- empty value
    # even with both bridges READY (the logon task therefore never started the
    # proxies).  Reproduced identically from the task AND from an interactive
    # session, so it was the FILE, not the context.
    # RULE: keep param() PURE ASCII; Chinese belongs in the comment block above.
    [int]$WaitMinutes = 3
)

$ErrorActionPreference = "Stop"
$proxyDir = "G:\qmt_projects\quant-qmt-proxy"
$logDir = "$proxyDir\logs"
$restartLog = "$logDir\restart-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$timeoutSeconds = 30

# Ensure log directory exists
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Write-Host $line
    Add-Content -Path $restartLog -Value $line
}

Write-Log "=== Restarting quant-qmt-proxy ==="

# --- Step 0: wait until EVERY account's channel is really usable ----------
# Must happen BEFORE the proxies restart: a proxy that starts against a dead
# backend builds sessions in a loop and exhausts the xtquant SDK writers
# ("WaitingFreeWriter instances exceed maximum instances limit"), which then
# needs another full restart to clear.
#
# 2026-09-15 (big-QMT migration): the backend is derived from each service's own
# environment, so there is exactly ONE place to flip (the NSSM
# AppEnvironmentExtra PYTHONPATH) and this script follows automatically -- a
# second flag here could silently drift out of sync with reality.
#   mini   -> XtMiniQmt.exe alive AND qmt_ready_check.py says READY
#   bridge -> the strategy inside the big QMT client answers an RPC ping
$pythonExe = "$proxyDir\.venv\Scripts\python.exe"
$readyScript = "$proxyDir\scripts\qmt_ready_check.py"
$bridgeProbe = "$proxyDir\scripts\bridge_rpc_probe.py"
$nssmExe = "$proxyDir\nssm.exe"
# 2026-09-15 17:28: the scheduled task reported
#   "ABORTED: channels not ready within  min"      <- $WaitMinutes printed EMPTY
# i.e. the wait loop exited instantly even though the action string passes
# `-WaitMinutes 15` and the param defaults to 3.  Log the effective value (and
# where PowerShell came from) so the next occurrence is self-diagnosing instead
# of needing a bespoke probe task.
Write-Log ("effective WaitMinutes=$WaitMinutes bound=" + $PSBoundParameters.ContainsKey('WaitMinutes') + " ps=" + $PSVersionTable.PSVersion + " pshome=" + $PSHOME)

function Get-Backend([string]$service) {
    # nssm prints AppEnvironmentExtra as UTF-16 -- a NUL byte between every ASCII
    # character -- so matching the RAW string never works.  Measured 2026-09-15
    # 16:4x with BOTH proxies already on the bridge: raw length 418, NULs present,
    # `-match 'PYTHONPATH'` False, `-match 'bridge-client'` False, i.e. every
    # service read as 'mini'.  That is not cosmetic: the mini branch below waits
    # for XtMiniQmt.exe, so once miniQMT is retired a logon would find no MiniQMT,
    # time out, and leave BOTH proxy services stopped.  Strip the NULs first
    # (same idiom as switch-proxy-backend.ps1::Get-EnvLines).
    $raw = ""
    try { $raw = (& $nssmExe get $service AppEnvironmentExtra 2>$null | Out-String) } catch { }
    $flat = ($raw -replace "`0", '')
    $hasPythonPath = [bool]($flat -match 'PYTHONPATH')
    $hasBridge = [bool]($flat -match 'bridge-client')
    if ($flat.Length -eq 0) {
        Write-Log "WARN: could not read AppEnvironmentExtra for $service -- assuming mini"
    } elseif ($hasPythonPath -ne $hasBridge) {
        Write-Log "WARN: $service env is inconsistent (PYTHONPATH=$hasPythonPath bridge-client=$hasBridge) -- assuming mini"
    }
    if ($hasPythonPath -and $hasBridge) { return 'bridge' }
    return 'mini'
}

$qmtChecks = @(
    @{ Label = "020 (G:\qmt)";  Service = "QMTProxy-020"; Path = "G:\qmt\userdata_mini";  Account = "020100053835"; Exe = "G:\qmt\bin.x64\XtMiniQmt.exe" },
    @{ Label = "666 (G:\qmt1)"; Service = "QMTProxy-666"; Path = "G:\qmt1\userdata_mini"; Account = "666810082889"; Exe = "G:\qmt1\bin.x64\XtMiniQmt.exe" }
)
foreach ($q in $qmtChecks) { $q.Backend = Get-Backend $q.Service }
foreach ($q in $qmtChecks) { Write-Log "backend: $($q.Label) -> $($q.Backend)" }

$waitUntil = (Get-Date).AddMinutes($WaitMinutes)
$allReady = $false
while ((Get-Date) -lt $waitUntil) {
    $allReady = $true
    foreach ($q in $qmtChecks) {
        if ($q.Backend -eq 'bridge') {
            $out = & $pythonExe $bridgeProbe $q.Account 2>&1 | Out-String
            # READY must be its own token: a bare 'READY' substring also matches
        # 'NOT_READY' (the probe's failure line), so this would invert silently.
        if ($LASTEXITCODE -eq 0 -and $out -match '(^|\s)READY\b') {
                Write-Log "bridge channel OK: $($q.Label) $($out.Trim())"
            } else {
                Write-Log "waiting: $($q.Label) big-QMT bridge not ready (strategy running?): $($out.Trim())"
                $allReady = $false
            }
            continue
        }
        $proc = Get-CimInstance Win32_Process -Filter "Name='XtMiniQmt.exe'" |
            Where-Object { $_.ExecutablePath -eq $q.Exe }
        if (-not $proc) {
            Write-Log "waiting: $($q.Label) MiniQMT process not running ($($q.Exe))"
            $allReady = $false
            continue
        }
        $out = & $pythonExe $readyScript $q.Path $q.Account 2>&1 | Out-String
        # READY must be its own token: a bare 'READY' substring also matches
        # 'NOT_READY' (the probe's failure line), so this would invert silently.
        if ($LASTEXITCODE -eq 0 -and $out -match '(^|\s)READY\b') {
            Write-Log "trading channel OK: $($q.Label) (PID $($proc.ProcessId))"
        } else {
            Write-Log "waiting: $($q.Label) trading channel not ready (MiniQMT stuck on login?): $($out.Trim())"
            $allReady = $false
        }
    }
    if ($allReady) { break }
    Start-Sleep -Seconds 30
}
if (-not $allReady) {
    Write-Log "=== ABORTED: channels not ready within $WaitMinutes min; proxy services NOT restarted ==="
    Write-Log "bridge backend : check the big QMT is logged in and the strategy is running (startup autorun)"
    Write-Log "mini   backend : check both MiniQMT are logged in, then re-run this script"
    exit 1
}
Write-Log "all channels ready, restarting proxy services..."

# --- Step 1: Stop proxy services (NSSM managed) ---
# 代理由 NSSM 服务 QMTProxy-020 / QMTProxy-666 托管，必须通过服务控制停止，
# 否则 nssm 会立即拉起被杀掉的进程，与手动启动产生双实例/端口冲突。
Write-Log "Stopping proxy services..."
foreach ($svc in @("QMTProxy-020", "QMTProxy-666")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne "Stopped") {
        Write-Log "Stopping service $svc..."
        & sc.exe stop $svc 2>&1 | Out-Null
        $waited = 0
        while ($waited -lt $timeoutSeconds) {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s -or $s.Status -eq "Stopped") { break }
            Start-Sleep -Seconds 1
            $waited++
        }
        if ($waited -ge $timeoutSeconds) {
            Write-Log "WARNING: $svc did not stop within ${timeoutSeconds}s."
        }
    } else {
        Write-Log "$svc already stopped."
    }
}
Write-Log "All proxy services stopped."

# --- Step 1.5: Clean 666's tick cache (trading-only, no need to keep historical tick) ---
$cache666 = "D:\qmt1_data"
if (Test-Path $cache666) {
    $before = (Get-ChildItem -Path $cache666 -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($before -gt 0) {
        Get-ChildItem -Path "$cache666\*\*.dat" -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem -Path $cache666 -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $freed = [math]::Round(($before - $after)/1MB, 0)
        Write-Log "Cleaned 666 cache: freed ${freed}MB"
    } else {
        Write-Log "666 cache already empty."
    }
}

# Small delay to ensure ports are freed
Start-Sleep -Seconds 2

# --- Step 2: Start proxy services (NSSM managed) ---
Write-Log "Starting proxy services..."
foreach ($svc in @("QMTProxy-020", "QMTProxy-666")) {
    $out = & sc.exe start $svc 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Started $svc"
    } else {
        Write-Log "WARNING: sc start $svc failed: $($out.Trim())"
    }
}

# --- Step 3: Wait for services to bind ports ---
Start-Sleep -Seconds 8

$ports = @(8001, 8002, 50051, 50052)
$listening = netstat -ano | Select-String "LISTENING"
foreach ($port in $ports) {
    $found = $listening | Select-String ":$port "
    if ($found) {
        Write-Log "Port $port is LISTENING - OK"
    } else {
        Write-Log "WARNING: Port $port is NOT listening!"
    }
}

# Check memory usage
$os = Get-CimInstance Win32_OperatingSystem
$memPct = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize * 100, 1)
Write-Log "Memory usage: $memPct%"
Write-Log "=== Restart complete ==="
