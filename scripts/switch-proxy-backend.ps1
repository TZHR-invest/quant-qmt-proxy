<#
.SYNOPSIS
    Switch ONE quant-qmt-proxy service between the miniQMT backend and the
    big-QMT bridge backend, in a single reversible step (2026-09-15).

.DESCRIPTION
    The backend is selected by exactly ONE thing: whether the service's NSSM
    AppEnvironmentExtra contains PYTHONPATH pointing at the bridge checkout.
      present -> the shim shadows the venv's real xtquant -> Redis -> strategy
      absent  -> the venv's own xtquant                    -> miniQMT
    So "rollback" is literally "remove that one line", which -Backend mini does.

    Every mutating step is verified.  If the service does not come back healthy,
    the previous environment is restored and the service restarted again, so a
    bad switch cannot leave it down.

.EXAMPLE
    .\switch-proxy-backend.ps1 -Service QMTProxy-666 -Backend bridge -DryRun
    .\switch-proxy-backend.ps1 -Service QMTProxy-666 -Backend bridge
    .\switch-proxy-backend.ps1 -Service QMTProxy-666 -Backend mini
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('QMTProxy-020','QMTProxy-666')][string]$Service,
    [Parameter(Mandatory=$true)][ValidateSet('bridge','mini')][string]$Backend,
    [string]$AccountId,
    [int]$Port,
    [string]$MiniUserData,
    [switch]$DryRun,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Continue'
$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$nssm     = "$proxyDir\nssm.exe"
$python   = "$proxyDir\.venv\Scripts\python.exe"
$K        = "$env:SystemRoot\System32"
$logDir   = "$proxyDir\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = "$logDir\switch-$Service-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Say([string]$m) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $m"
    Write-Host $line
    Add-Content -Path $log -Value $line
}

# Listener pids for a port, via netstat -- and this is now the JUDGE for
# "is it bound?".
#
# WHY (2026-09-15 13:30, hit for real while rehearsing step 5): Get-NetTCPConnection
# is a CIM cmdlet and was observed returning an EMPTY set for ports that WERE
# listening -- four consecutive calls returned correct answers for 8004/50054 and
# then empty for 8001/8002, whose pids had not changed since 12:11:14.  With
# -ErrorAction SilentlyContinue a provider error is indistinguishable from "no
# listener", i.e. "could not check" got printed as "not there".
#
# TWO places in this file would then do the wrong thing, so both now take the
# UNION of the two mechanisms (netstat first).  An OR/union can only remove false
# negatives; it adds no new failure mode:
#   * the leftover-listener kill after `sc stop` (a miss leaves the old python
#     child holding the port, so the following `sc start` cannot bind), and
#   * the final $ok verdict (a miss would report "SWITCH FAILED" on a switch that
#     actually worked).
function Get-NetstatListenerPid([int]$p) {
    $o = ''
    try { $o = (& "$K\netstat.exe" -ano 2>&1 | Out-String) } catch { return @() }
    $out = @()
    foreach ($ln in ($o -split "`r?`n")) {
        if (($ln -match 'LISTENING') -and ($ln -match (":" + $p + "\s"))) {
            $f = @($ln.Trim() -split '\s+')
            if ($f.Count -ge 1) {
                $last = $f[$f.Count - 1]
                if ($last -match '^\d+$') { $out += [int]$last }
            }
        }
    }
    return @($out | Select-Object -Unique)
}

# Defaults per service (020 and 666 are two independent QMT installations)
if (-not $AccountId)   { $AccountId   = if ($Service -eq 'QMTProxy-020') { '020100053835' } else { '666810082889' } }
if (-not $Port)        { $Port        = if ($Service -eq 'QMTProxy-020') { 8001 } else { 8002 } }
if (-not $MiniUserData){ $MiniUserData= if ($Service -eq 'QMTProxy-020') { 'G:\qmt\userdata_mini' } else { 'G:\qmt1\userdata_mini' } }
$bridgePath = 'C:\bridge-client\bridge\src;C:\bridge-client'

Say "=== switch $Service -> $Backend (account=$AccountId port=$Port dryRun=$DryRun) ==="

function Get-EnvLines {
    $raw = (& $nssm get $Service AppEnvironmentExtra 2>$null | Out-String)
    # nssm prints the block UTF-16-ish; keep ASCII key=value lines only.
    return @($raw -split "`r?`n" | ForEach-Object { ($_ -replace "`0", '').Trim() } |
             Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' })
}

$old = Get-EnvLines
Say ("current env: " + ($old -join ' | '))
# Both lines are managed together: PYTHONPATH picks the shim, BIGQMT_ACCOUNT_ID
# tells that shim WHICH account this service serves.  The client config module
# can only name one account, and without this a second proxy on the same machine
# would silently talk to the first account's bridge (2026-09-15, patch A6).
$base = @($old | Where-Object { $_ -notmatch '^PYTHONPATH=' -and $_ -notmatch '^BIGQMT_ACCOUNT_ID=' })
$new  = $base
if ($Backend -eq 'bridge') { $new = $base + @("BIGQMT_ACCOUNT_ID=$AccountId") + @("PYTHONPATH=$bridgePath") }
Say ("target  env: " + ($new -join ' | '))

if ($new.Count -eq 0) { Say 'ERROR: refusing to write an empty environment'; exit 2 }

if ($DryRun) { Say 'DRY RUN: nothing changed'; Say '=== end (dry run) ==='; exit 0 }

# Pre-flight: for the bridge the strategy must already answer, otherwise we
# would knowingly point a live service at a dead backend.
if ($Backend -eq 'bridge' -and -not $SkipVerify) {
    $probe = & $python "$proxyDir\scripts\bridge_rpc_probe.py" $AccountId 2>&1 | Out-String
    Say ("pre-flight bridge probe: " + $probe.Trim())
    if ($LASTEXITCODE -ne 0) { Say 'ERROR: bridge not ready; aborting BEFORE touching the service'; exit 3 }
}

$backupFile = "$logDir\env-$Service-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
$old | Set-Content -Path $backupFile -Encoding UTF8
Say "env backup -> $backupFile"

function Set-Env([string[]]$lines) {
    $a = @('set', $Service, 'AppEnvironmentExtra') + $lines
    $out = & $nssm @a 2>&1 | Out-String
    Say ("nssm set rc=$LASTEXITCODE " + $out.Trim())
}

function Restart-Svc {
    Say "stopping $Service"
    & "$K\sc.exe" stop $Service 2>&1 | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $s = Get-Service -Name $Service -ErrorAction SilentlyContinue
        if (-not $s -or $s.Status -eq 'Stopped') { break }
    }
    # sc stop leaves the python child holding the port (documented 2026-06-15).
    # Union of CIM and netstat -- see Get-NetstatListenerPid above: a CIM miss here
    # would leave the old child bound and make the following `sc start` fail.
    $killPids = @()
    foreach ($c in @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        if ($c.OwningProcess) { $killPids += [int]$c.OwningProcess }
    }
    $nsPids = @(Get-NetstatListenerPid $Port)
    if (($nsPids.Count -gt 0) -and ($killPids.Count -eq 0)) {
        Say "note: CIM saw NO listener on $Port but netstat saw pid $($nsPids -join ',') (known CIM flake)"
    }
    $killPids += $nsPids
    $killPids = @($killPids | Select-Object -Unique)
    if ($killPids.Count -gt 0) {
        foreach ($kp in $killPids) {
            Say "killing leftover listener pid=$kp on $Port"
            Stop-Process -Id $kp -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    }
    Say "starting $Service"
    & "$K\sc.exe" start $Service 2>&1 | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 1
        if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Test-Backend {
    if ($Backend -eq 'bridge') {
        $o = & $python "$proxyDir\scripts\bridge_rpc_probe.py" $AccountId 2>&1 | Out-String
        Say ("post-check bridge probe: " + $o.Trim())
        return ($LASTEXITCODE -eq 0)
    }
    $o = & $python "$proxyDir\scripts\qmt_ready_check.py" $MiniUserData $AccountId 2>&1 | Out-String
    Say ("post-check mini probe: " + $o.Trim())
    return ($LASTEXITCODE -eq 0)
}

Set-Env $new
if (-not (Restart-Svc)) { Say "ERROR: $Service did not bind port $Port" }
# Final verdict: union of CIM and netstat.  A CIM-only verdict was a single call,
# so one flake would have reported "SWITCH FAILED" on a switch that worked.
$cimOk = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) -ne $null
$nsOk = (@(Get-NetstatListenerPid $Port)).Count -gt 0
$ok = $cimOk -or $nsOk
if ($nsOk -and (-not $cimOk)) { Say "note: CIM saw NO listener on $Port but netstat did (known CIM flake; treating as bound)" }
if ($ok) {
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health/" -TimeoutSec 10
        Say ("health: " + $r.data.status + " (backend now " + (Get-EnvLines | Where-Object { $_ -match '^PYTHONPATH=' }) + ")")
    } catch { Say "health probe failed: $($_.Exception.Message)"; $ok = $false }
}
if ($ok) { $ok = Test-Backend }

if ($ok) {
    Say "=== SWITCH OK: $Service is on the $Backend backend ==="
    exit 0
}

Say '=== SWITCH FAILED -> rolling the environment back ==='
Set-Env $old
$null = Restart-Svc
Say 'rollback done; service is back on the previous environment'
exit 1
