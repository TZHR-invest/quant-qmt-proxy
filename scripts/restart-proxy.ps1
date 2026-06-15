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

# --- Step 1: Stop existing proxy processes ---
Write-Log "Stopping proxy processes..."
$procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
    Where-Object { $_.CommandLine -match 'run\.py' -or $_.CommandLine -match 'start\.py' }

if ($procs) {
    foreach ($p in $procs) {
        Write-Log "Killing PID $($p.ProcessId)..."
        & taskkill /f /pid $p.ProcessId 2>&1 | Out-Null
    }
    # Wait for processes to exit
    $waited = 0
    while ($waited -lt $timeoutSeconds) {
        $remaining = Get-Process -Name python -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -in $procs.ProcessId }
        if (-not $remaining) { break }
        Start-Sleep -Seconds 1
        $waited++
    }
    if ($waited -ge $timeoutSeconds) {
        Write-Log "WARNING: $($remaining.Count) process(es) did not exit gracefully."
    }
    Write-Log "All proxy processes stopped."
} else {
    Write-Log "No running proxy processes found."
}

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

# --- Step 2: Start 020 account ---
Write-Log "Starting account 020 (port 8001 / 50051)..."
$proc020 = Start-Process -FilePath "$proxyDir\start-prod-020.bat" -WindowStyle Hidden -PassThru
Write-Log "Started 020 (via start-prod-020.bat, PID: $($proc020.Id))"

# --- Step 3: Start 666 account ---
Write-Log "Starting account 666 (port 8002 / 50052)..."
$proc666 = Start-Process -FilePath "$proxyDir\start-prod-666.bat" -WindowStyle Hidden -PassThru
Write-Log "Started 666 (PID: $($proc666.Id))"

# --- Step 4: Wait and verify ---
Start-Sleep -Seconds 5

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
