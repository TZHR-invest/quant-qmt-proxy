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
    # QMT 就绪等待时长（分钟）。计划任务以 -WaitMinutes 15 运行，
    # 等用户手动点击 MiniQMT 登录后自动接管启动代理。
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

# --- Step 0: Verify both MiniQMT are running AND trading channel is ready ---
# 必须在 QMT 已登录就绪后才重启代理，否则新代理进程会在 QMT 不可用时反复建会话，
# 导致 xtquant SDK writer 资源耗尽（"WaitingFreeWriter instances exceed maximum limit"），
# 之后即使 QMT 起来也无法恢复，只能再次重启。
# MiniQMT 无自动登录选项，需人工点击登录；本步骤以等待模式持续探活
# （最多 WaitMinutes 分钟），用户点完登录后自动继续。
$pythonExe = "$proxyDir\.venv\Scripts\python.exe"
$readyScript = "$proxyDir\scripts\qmt_ready_check.py"
$qmtChecks = @(
    @{ Label = "020 (G:\qmt)";  Path = "G:\qmt\userdata_mini";  Account = "020100053835"; Exe = "G:\qmt\bin.x64\XtMiniQmt.exe" },
    @{ Label = "666 (G:\qmt1)"; Path = "G:\qmt1\userdata_mini"; Account = "666810082889"; Exe = "G:\qmt1\bin.x64\XtMiniQmt.exe" }
)
$waitUntil = (Get-Date).AddMinutes($WaitMinutes)
$allReady = $false
while ((Get-Date) -lt $waitUntil) {
    $allReady = $true
    foreach ($q in $qmtChecks) {
        $proc = Get-CimInstance Win32_Process -Filter "Name='XtMiniQmt.exe'" |
            Where-Object { $_.ExecutablePath -eq $q.Exe }
        if (-not $proc) {
            Write-Log "等待中: $($q.Label) MiniQMT 进程未运行 ($($q.Exe))"
            $allReady = $false
            continue
        }
        $out = & $pythonExe $readyScript $q.Path $q.Account 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $out -match "READY") {
            Write-Log "交易通道 OK: $($q.Label) (PID $($proc.ProcessId))"
        } else {
            Write-Log "等待中: $($q.Label) 交易通道未就绪（MiniQMT 可能停在登录界面，请点击登录）: $($out.Trim())"
            $allReady = $false
        }
    }
    if ($allReady) { break }
    Start-Sleep -Seconds 30
}
if (-not $allReady) {
    Write-Log "=== ABORTED: $WaitMinutes 分钟内 QMT 未全部就绪，代理服务未重启 ==="
    Write-Log "请确认两个 MiniQMT 已登录后，重新运行本脚本"
    exit 1
}
Write-Log "两个 QMT 均已就绪，继续重启代理服务..."

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
