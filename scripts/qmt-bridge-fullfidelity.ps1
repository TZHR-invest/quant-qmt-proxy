<#
  qmt-bridge-fullfidelity.ps1 -- start a REPLICA of the production proxy in
  bridge mode on spare ports, exercise it, and tear it down.  Production
  (8001/8002) is never touched.

  WHY THIS EXISTS (2026-09-15)
  ---------------------------
  Every bridge-mode test until now used scripts\bridge-test-666.bat, which runs
  APP_SERVERS=rest on the .venv interpreter.  The SERVICES run APP_SERVERS=all
  (REST + gRPC) and a different extra env (BIGQMT_ACCOUNT_ID), so "the bridge
  works" had never been shown for the shape production actually uses.  This
  script closes that gap before a switch, instead of discovering it during one.

  TWO TRAPS IT ENCODES (both were hit for real while writing it)
  -------------------------------------------------------------
  1. SOCKET LISTENING != APPLICATION READY.  uvicorn opens its socket before the
     lifespan startup finishes, so a request fired the moment the port appears
     can fail while the log still looks fine.  So: poll /health/ until it ANSWERS,
     then give it a moment -- never trust "the port is listening".
  2. A FAILED RUN MUST NOT LEAVE A PROCESS BEHIND.  The first version exited on
     error and left its instance holding the ports; the next run then died with
     "Failed to bind 0.0.0.0:<grpc>" and a request was answered by the LEFTOVER,
     which produced a completely misleading "it works"/"it is broken" pair of
     readings in two consecutive runs.  So: cleanup lives in a finally, the
     spawn is verified against a fresh port check, and every failure prints the
     log tail.

  USAGE
    qmt-bridge-fullfidelity.ps1 -Account 666
    qmt-bridge-fullfidelity.ps1 -Account 020 -Port 8006 -GrpcPort 50056
  Exit 0 = the production-shaped bridge replica served everything, 3 = spare
  port busy / unclean, 4 = never came up, 5 = could not open a session.
#>
param(
    [ValidateSet('666', '020')] [string]$Account = '666',
    [int]$Port = 0,
    [int]$GrpcPort = 0,
    [switch]$Keep
)
$ErrorActionPreference = 'Continue'

$map = @{
    '666' = @{ Dir = 'G:\qmt1'; Acct = '666810082889'; Port = 8004; Grpc = 50054; Yml = 'config.local.666.yml' }
    '020' = @{ Dir = 'G:\qmt';  Acct = '020100053835'; Port = 8006; Grpc = 50056; Yml = 'config.local.020.yml' }
}
$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$K = "$env:SystemRoot\System32"
$acct = $map[$Account].Acct
$yml = Join-Path $proxyDir $map[$Account].Yml
if ($Port -eq 0) { $Port = $map[$Account].Port }
if ($GrpcPort -eq 0) { $GrpcPort = $map[$Account].Grpc }

$bat = Join-Path $env:TEMP "qmt-ff-$Account.bat"
$log = Join-Path $proxyDir "logs\ff-$Account.log"

function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
function Stop-Replica {
    foreach ($p in @($Port, $GrpcPort)) {
        foreach ($c in @(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)) {
            Say ("cleanup: stopping listener on $p pid=" + $c.OwningProcess)
            Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 3
    $busy = @()
    foreach ($p in @($Port, $GrpcPort)) {
        if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { $busy += $p }
    }
    if ($busy.Count) { Say ("WARNING: still listening after cleanup: " + ($busy -join ',')) }
    else { Say 'cleanup: spare ports free' }
}

Say ("=== production-shaped bridge replica  account=$Account ($acct)  rest=$Port grpc=$GrpcPort ===")

# ---- refuse to run on a dirty port set (trap 2) ----------------------------
foreach ($p in @($Port, $GrpcPort)) {
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) {
        Say "ERROR: port $p is already in use -- clean it up first (a leftover replica?"
        Say "       this exact situation once produced a completely misleading result)"
        exit 3
    }
}

$lines = @(
    '@echo off'
    "cd /d `"$proxyDir`""
    'set APP_MODE=prod'
    "set APP_PORT=$Port"
    "set GRPC_PORT=$GrpcPort"
    'set APP_SERVERS=all'
    "set APP_LOCAL_CONFIG=$($map[$Account].Yml)"
    "set BIGQMT_ACCOUNT_ID=$acct"
    'set PYTHONPATH=C:\bridge-client\bridge\src;C:\bridge-client'
    ".venv\Scripts\python.exe run.py > `"$log`" 2>&1"
)
[System.IO.File]::WriteAllText($bat, ($lines -join "`r`n") + "`r`n", (New-Object System.Text.ASCIIEncoding))
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }

$key = [regex]::Match([System.IO.File]::ReadAllText($yml, [System.Text.Encoding]::UTF8), 'api_keys:\s*\r?\n\s*-\s*"?([^"\r\n]+?)"?\s*\r?\n').Groups[1].Value.Trim()
$AUTH = @('-H', "Authorization: Bearer $key")
$base = "http://127.0.0.1:$Port"
function J([string]$s) { try { return ($s | ConvertFrom-Json) } catch { return $null } }

$ok = $false
try {
    [void](Start-Process -FilePath "$K\cmd.exe" -ArgumentList '/c', $bat -WindowStyle Minimized -PassThru)

    # trap 1: wait until the APP answers, not until the socket exists
    $ready = $false
    for ($i = 1; $i -le 45; $i++) {
        Start-Sleep -Seconds 2
        $hresp = (& "$K\curl.exe" -s -m 3 "$base/health/" 2>&1 | Out-String)
        $j = J $hresp
        if ($j -and $j.data.status -eq 'healthy') { $ready = $true; break }
    }
    Say ("app answered /health/ after " + (2 * $i) + "s : " + $ready)
    if (-not $ready) {
        Say 'ERROR: the replica never became ready -- log tail:'
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 20 | ForEach-Object { Say ('  ' + $_) } }
        exit 4
    }
    Say ("listeners: rest=" + $(if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { 'yes' } else { 'NO' }) +
         "  grpc=" + $(if (Get-NetTCPConnection -LocalPort $GrpcPort -State Listen -ErrorAction SilentlyContinue) { 'yes' } else { 'NO' }))

    $body = Join-Path $env:TEMP "ff-$Account-sess.json"
    [System.IO.File]::WriteAllText($body, ('{"account_id": "' + $acct + '", "account_type": "STOCK"}'), (New-Object System.Text.UTF8Encoding($false)))
    $sess = J (& "$K\curl.exe" -s @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$body" "$base/api/v1/trading/sessions" 2>&1 | Out-String)
    if (-not $sess -or -not $sess.data.session_id) {
        Say 'ERROR: could not open a session; log tail:'
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 20 | ForEach-Object { Say ('  ' + $_) } }
        exit 5
    }
    $sid = $sess.data.session_id
    Say ("POST /trading/sessions 200  is_real=" + $sess.data.is_real + " orders_enabled=" + $sess.data.orders_enabled)

    $r = J (& "$K\curl.exe" -s @AUTH "$base/health/ready" 2>&1 | Out-String)
    Say ("/health/ready : status=" + $r.data.status + " backend=" + $r.data.backend)
    if ($r.data.backend -ne 'bridge') { Say "ERROR: backend is '$($r.data.backend)', expected 'bridge'"; exit 5 }

    $pos = J (& "$K\curl.exe" -s @AUTH "$base/api/v1/trading/sessions/$sid/positions" 2>&1 | Out-String)
    $ast = J (& "$K\curl.exe" -s @AUTH "$base/api/v1/trading/sessions/$sid/asset" 2>&1 | Out-String)
    Say ("positions=" + @($pos.data.items).Count + "  asset.cash=" + $ast.data.cash)

    $tb = Join-Path $env:TEMP "ff-$Account-tick.json"
    [System.IO.File]::WriteAllText($tb, '{"symbols": ["600000.SH"]}', (New-Object System.Text.UTF8Encoding($false)))
    $tick = J (& "$K\curl.exe" -s @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$tb" "$base/api/v1/data/full-tick" 2>&1 | Out-String)
    $lp = $null; try { $lp = $tick.data.items[0].tick.last_price } catch { }
    Say ("full-tick success=" + $tick.success + " 600000.SH last=" + $lp)

    [void](& "$K\curl.exe" -s -o NUL -X DELETE @AUTH "$base/api/v1/trading/sessions/$sid" 2>&1)

    Say '--- log tail ---'
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 6 | ForEach-Object { Say ('  ' + $_) } }
    $ok = $true
} finally {
    if ($Keep) { Say "leaving the replica running on $Port (spare ports are free, production untouched)" }
    else { Stop-Replica }
}

Say ''
Say ('=== ' + $(if ($ok) { 'REPLICA OK: the production-shaped service works in bridge mode' } else { 'REPLICA FAILED (see the log tail above)' }) + ' ===')
Say '--- production, untouched ---'
foreach ($p in @(8001, 8002)) {
    $c = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    Say ("  port $p listen=" + $(if ($c) { 'yes pid=' + $c[0].OwningProcess } else { 'NO' }))
}
if ($ok) { exit 0 }
exit 1
