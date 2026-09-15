<#
  qmt-switch-preflight.ps1 -- ONE read-only command that answers "are we good to
  start the miniQMT -> big-QMT switch right now?" and prints where we are.

  Run this FIRST in the switch window.  It changes nothing: no service is
  touched, no task is edited, no order is placed.

  It checks, in order:
    1. the clock (and REFUSES if we are inside A-share trading hours)
    2. both proxy services: state, listening port, current backend
    3. both accounts' /health/ready
    4. bridge RPC probes (666 should be READY; 020 is NOT until its strategy
       has been registered -- that is expected, not a failure)
    5. QMT process inventory: XtItClient **per install** (one each is normal --
       there are two installations now; only >1 from the SAME install is a zombie) /
       orphan miniquote / mini count
    6. link files by EXPLICIT name (never a link* glob -- it would list and could
       delete LinkageTrade.dll)
    7. scheduled tasks that drive the boot chain
    8. free space on the two drives that matter
    9. which baseline snapshots already exist

  Exit 0 = GO (no blocking problem), 1 = NO-GO (see the BLOCKERS list).
#>
param(
    [switch]$Force          # proceed even inside trading hours (loud warning)
)
$ErrorActionPreference = 'Continue'

$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$python = "$proxyDir\.venv\Scripts\python.exe"
$K = "$env:SystemRoot\System32"
$blockers = New-Object System.Collections.ArrayList
$warns = New-Object System.Collections.ArrayList

function Say($m) { Write-Output $m }
function Head($m) { Write-Output ''; Write-Output ("--- " + $m + " ---") }
function Block($m) { [void]$blockers.Add($m); Write-Output ("  BLOCKER: " + $m) }
function Warn($m) { [void]$warns.Add($m); Write-Output ("  warn   : " + $m) }

Say ("=== QMT switch preflight  " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===")

# ---- 1. clock / trading hours ---------------------------------------------
Head 'clock'
$now = Get-Date
$mins = $now.Hour * 60 + $now.Minute
$inAm = ($mins -ge (9 * 60 + 15)) -and ($mins -le (11 * 60 + 30))
$inPm = ($mins -ge (13 * 60)) -and ($mins -le (15 * 60))
# NOTE (fixed 2026-09-15 15:02, in the window): this used to be just
#   $inCall = $mins -ge (14 * 60 + 57)
# with NO upper bound.  Because $inPm already covers through 15:00 inclusive, the
# elseif that uses $inCall is only reachable when $mins > 900 -- and there
# `$mins -ge 897` is ALWAYS true.  So every run from 14:57 onward blocked with
# "inside the closing call auction ... wait for the close", i.e. the guard made
# THE SWITCH WINDOW ITSELF unreachable, contradicting its own message
# "(14:57-15:00)".  Bounded now; the auction itself is still blocked by the
# $inPm branch above (which covers 14:57-15:00 too).
$inCall = ($mins -ge (14 * 60 + 57)) -and ($mins -le (15 * 60))
$inSession = $inAm -or $inPm
Say ("  local time : " + $now.ToString('yyyy-MM-dd HH:mm:ss'))
Say ("  in A-share session (09:15-11:30 / 13:00-15:00): " + $inSession)
if ($inSession -and -not $Force) {
    Block 'inside trading hours: the switch must not run now (bridge is read-only, so orders would fail)'
} elseif ($inCall -and -not $Force) {
    Block 'inside the closing call auction (14:57-15:00): wait for the close'
} else {
    Say '  OK: outside trading hours'
}

# ---- 2. services and ports -------------------------------------------------
Head 'proxy services'
$svcMap = [ordered]@{ 'QMTProxy-666' = 8002; 'QMTProxy-020' = 8001 }
foreach ($svc in $svcMap.Keys) {
    $port = $svcMap[$svc]
    $state = (& "$K\sc.exe" query $svc 2>&1 | Select-String 'STATE' | ForEach-Object { $_.ToString().Trim() }) -join ' '
    # Ports: use netstat, NOT Get-NetTCPConnection.  Get-NetTCPConnection -State
    # Listen silently returns an EMPTY set when called repeatedly inside one
    # process (measured 2026-09-15), which reads a service that IS listening as
    # "NO" -- here that would raise a bogus blocker and make the switch window
    # unreachable.  netstat -ano is the authoritative source.
    $listenPid = ''
    foreach ($l in (netstat -ano)) {
        $s = [string]$l
        if (($s -like "*:$port *") -and ($s -like '*LISTENING*')) {
            $parts = $s.Trim() -split '\s+'
            $listenPid = $parts[$parts.Length - 1]
            break
        }
    }
    # Backend: `sc.exe qc` cannot show NSSM's AppEnvironmentExtra (that value
    # lives in the registry, not in the binary path), so it always reported
    # 'mini'; and nssm prints it as UTF-16, so even a raw read never matches.
    # Strip the NULs (same idiom as switch-proxy-backend.ps1::Get-EnvLines).
    $backend = 'mini'
    $envRaw = ""
    try { $envRaw = (& "$proxyDir\nssm.exe" get $svc AppEnvironmentExtra 2>$null | Out-String) } catch { }
    $flat = ($envRaw -replace "`0", '')
    if (($flat -match 'PYTHONPATH') -and ($flat -match 'bridge-client')) { $backend = 'bridge' }
    Say ("  {0,-14} port={1} listen={2} backend={3}" -f $svc, $port, $(if ($listenPid -ne '') { 'yes(pid ' + $listenPid + ')' } else { 'NO' }), $backend)
    Say ("                 {0}" -f $state)
    if ($listenPid -eq '') { Block "$svc is not listening on $port" }
    if ($state -notmatch 'RUNNING') { Block "$svc is not RUNNING" }
}

Say ''
Say ("  bridge path that will be injected: C:\bridge-client\bridge\src;C:\bridge-client")
if (-not (Test-Path -LiteralPath 'C:\bridge-client\bridge\src\bigqmt_signal_trader\xtquant_compat.py')) {
    Block 'the bridge client checkout is missing: C:\bridge-client\bridge\src\bigqmt_signal_trader\xtquant_compat.py'
}
foreach ($q in @('G:\qmt1\python\bigqmt_signal_trader_local_config.py', 'G:\qmt\python\bigqmt_signal_trader_local_config.py')) {
    if (Test-Path -LiteralPath $q) { Say ("  strategy local config present: " + $q) } else { Block ("missing strategy local config: " + $q) }
}

# ---- 2b. is the RUNNING service code the code on disk? ---------------------
# 2026-09-15: the production proxies were found running code from 00:19 while
# the D4/D5/D6 patch landed on disk at 08:59 -- "the source is patched" is NOT
# "the service is fixed".  These services only re-read code (and
# AppEnvironmentExtra) when they start, so this line tells the operator exactly
# what the next restart will change.
Head 'service code freshness (running pid vs source mtime)'
$srcFiles = @(
    'app\routers\health.py'
    'app\services\trading_session_manager.py'
    'app\services\xttrader_gateway.py'
    'app\utils\exceptions.py'
    'app\main.py'
) | ForEach-Object { Join-Path $proxyDir $_ }
$newest = $srcFiles | Where-Object { Test-Path -LiteralPath $_ } |
    ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
    Sort-Object -Descending | Select-Object -First 1
if (-not $newest) {
    Warn 'cannot read the proxy source mtimes'
} else {
    foreach ($svc in $svcMap.Keys) {
        $l = Get-NetTCPConnection -LocalPort $svcMap[$svc] -State Listen -ErrorAction SilentlyContinue
        if (-not $l) { continue }
        $procId = $l[0].OwningProcess
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $stale = $proc.StartTime -lt $newest
        Say ("  {0,-14} pid={1} started={2} newestSource={3} {4}" -f `
                $svc, $procId, $proc.StartTime.ToString('MM-dd HH:mm:ss'), $newest.ToString('MM-dd HH:mm:ss'), `
                $(if ($stale) { '<-- STALE CODE' } else { 'up to date' }))
        if ($stale) {
            Warn "$svc runs code older than $($newest.ToString('MM-dd HH:mm:ss')) -- restarting it (the switch does) will load the newer code"
        }
    }
}

# ---- 3/4. health + bridge probes ------------------------------------------
Head 'health and bridge probes'
$key666 = ''
$key020 = ''
foreach ($pair in @(@('666', "$proxyDir\config.local.666.yml"), @('020', "$proxyDir\config.local.020.yml"))) {
    $tag = $pair[0]; $yml = $pair[1]
    if (-not (Test-Path -LiteralPath $yml)) { Block "config yml missing: $yml"; continue }
    $m = [regex]::Match([System.IO.File]::ReadAllText($yml, [System.Text.Encoding]::UTF8), 'api_keys:\s*\r?\n\s*-\s*"?([^"\r\n]+?)"?\s*\r?\n')
    if (-not $m.Success) { Block "cannot read api_keys[0] from $yml"; continue }
    if ($tag -eq '666') { $key666 = $m.Groups[1].Value.Trim() } else { $key020 = $m.Groups[1].Value.Trim() }
}
foreach ($pair in @(@('666', 8002, '666810082889', $key666), @('020', 8001, '020100053835', $key020))) {
    $tag = $pair[0]; $port = $pair[1]; $acct = $pair[2]; $key = $pair[3]
    if ($key -ne '') {
        $h = & "$K\curl.exe" -s -H "Authorization: Bearer $key" "http://127.0.0.1:$port/health/ready" 2>&1 | Out-String
        Say ("  $tag /health/ready : " + $h.Trim())
        # Liveness only.  NOT the switch criterion: `backend` is derived from OPEN
        # SESSIONS, so with none it is "none"/"idle" while `success` stays true and
        # the HTTP status stays 200 (measured 2026-09-15, doc section 46.4).
        if ($h -notmatch '"success":true') { Block "$tag /health/ready did not answer 200" }
        $st = $null; $bk = $null
        try {
            $j = $h | ConvertFrom-Json
            $st = $j.data.status
            $bk = $j.data.backend
        } catch { }
        if ($null -ne $st) {
            Say ("                 status=$st backend=$(if ($null -eq $bk) { '(field absent = pre-D6 code)' } else { $bk })")
            if ($null -eq $bk) {
                Say '                 note: no backend field means this instance still runs pre-D6 code; the switch restarts it'
            } elseif ($st -eq 'idle') {
                Say '                 note: idle/none here is normal with no open session -- to test the backend, open a session first'
            }
        }
    }
    $probe = (& $python "$proxyDir\scripts\bridge_rpc_probe.py" $acct 8 2>&1 | Out-String).Trim()
    Say ("  $tag bridge probe   : " + $probe)
    if ($tag -eq '666' -and $probe -notmatch '^READY') {
        Warn 'the 666 bridge does not answer yet -- the strategy must be running before the switch'
    }
}

# ---- 5. process inventory --------------------------------------------------
Head 'QMT processes'
foreach ($name in @('XtItClient.exe', 'XtMiniQmt.exe', 'miniquote.exe', 'XtQuantServer.exe')) {
    $procs = @(Get-Process -Name ($name -replace '\.exe$', '') -ErrorAction SilentlyContinue)
    Say ("  {0,-18} count={1}" -f $name, $procs.Count)
    if ($procs.Count) {
        $detail = ($procs | ForEach-Object { "pid=$($_.Id)" }) -join ' '
        Say ("                     $detail")
    }
}
# Zombie test is PER INSTALL, not global (2026-09-15 fix).
#
# The old rule was `if ($it.Count -gt 1)`, correct when this machine had ONE QMT
# installation.  After the migration there are TWO (`G:\qmt1` = 666, `G:\qmt` =
# 020) and each one legitimately runs its own XtItClient.exe -- that is the
# architecture, not a leak.  Counting globally produced a **false NO-GO at 12:46**
# while both clients were logged in and both channels were healthy; the dangerous
# part is that it invites "clean up first", i.e. killing a live trading client.
# A real zombie is "more than one client FROM THE SAME INSTALL" (those are what
# make the launcher hang).
$it = @(Get-Process -Name 'XtItClient' -ErrorAction SilentlyContinue)
$instDirs = @('G:\qmt1\bin.x64', 'G:\qmt\bin.x64')
$perInst = @{}
foreach ($d in $instDirs) { $perInst[$d] = @() }
$strayClients = @()
foreach ($p in $it) {
    $exePath = ''
    try { $exePath = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").ExecutablePath } catch { }
    $hit = $false
    foreach ($d in $instDirs) {
        if ($exePath -and $exePath.ToLower().StartsWith($d.ToLower())) { $perInst[$d] += $p; $hit = $true }
    }
    if (-not $hit) { $strayClients += ("pid=" + $p.Id + " path=[" + $exePath + "]") }
}
Say '  --- XtItClient by install (one per install is NORMAL since the migration) ---'
foreach ($d in $instDirs) {
    $n = @($perInst[$d]).Count
    $pids = (@($perInst[$d]) | ForEach-Object { $_.Id }) -join ','
    Say ("  {0,-20} count={1} {2}" -f $d, $n, $(if ($n) { "pid=$pids" } else { '' }))
    if ($n -gt 1) { Block ("$n XtItClient.exe from $d -- those ARE zombies and make the launcher hang; clean up by pid first") }
    if ($n -eq 0) { Warn ("no XtItClient.exe from $d -- that install's big-QMT bridge would be down") }
}
foreach ($s in $strayClients) { Warn "XtItClient outside the two known installs: $s" }
$mini = @(Get-Process -Name 'XtMiniQmt' -ErrorAction SilentlyContinue)
if ($mini.Count -lt 1) { Warn 'no XtMiniQmt.exe running (the mini link is what we are moving away from, so this is informational)' }
$orphan = 0
foreach ($mq in @(Get-Process -Name 'miniquote' -ErrorAction SilentlyContinue)) {
    $parent = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $mq.Id) -ErrorAction SilentlyContinue).ParentProcessId
    if ($parent -and -not (Get-Process -Id $parent -ErrorAction SilentlyContinue)) { $orphan++ }
}
if ($orphan) { Warn "$orphan orphan miniquote.exe process(es) (parent gone)" }

# ---- 6. link files by explicit name ---------------------------------------
Head 'link files (explicit names only)'
$linkNames = @('linkQmt', 'linkMini', 'linkMiniQmt', 'link_reboot', 'linkResearchMini', 'linkResearchMini_reboot')
foreach ($dir in @('G:\qmt1\bin.x64', 'G:\qmt\bin.x64')) {
    $found = @()
    foreach ($n in $linkNames) { if (Test-Path -LiteralPath (Join-Path $dir $n)) { $found += $n } }
    $linkage = Test-Path -LiteralPath (Join-Path $dir 'LinkageTrade.dll')
    Say ("  {0,-14} link files: {1} | LinkageTrade.dll present: {2}" -f $dir, $(if ($found) { $found -join ',' } else { 'none' }), $linkage)
    if (-not $linkage) { Block "LinkageTrade.dll is MISSING from $dir (XtItClient.exe cannot start without it)" }
}

# ---- 7. scheduled tasks ----------------------------------------------------
Head 'scheduled tasks'
foreach ($t in @('QMT-AutoLogin', 'QMT-Proxy-AutoStart', 'QMT-Bridge-Sample')) {
    $ti = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    if (-not $ti) { Warn "scheduled task not found: $t"; continue }
    $act = ($ti.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
    Say ("  {0,-20} {1}" -f $t, $ti.State)
    Say ("    action: " + $act.Trim())
    $trig = ($ti.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ','
    Say ("    trigger: " + $trig)
}

# ---- 8. disk ---------------------------------------------------------------
Head 'disk'
foreach ($d in @('C:', 'G:')) {
    $v = Get-PSDrive -Name ($d.TrimEnd(':')) -ErrorAction SilentlyContinue
    if ($v) {
        $freeGb = [math]::Round($v.Free / 1GB, 1)
        $usedPct = [math]::Round(100 * ($v.Used / ($v.Used + $v.Free)), 1)
        Say ("  {0} free={1} GB used={2}%" -f $d, $freeGb, $usedPct)
        if ($freeGb -lt 5) { Block "$d has less than 5 GB free" }
    } else { Warn "cannot read drive $d" }
}

# ---- 9. baselines ----------------------------------------------------------
Head 'baseline snapshots already captured'
$cmpDir = "$proxyDir\logs\cmp"
if (Test-Path -LiteralPath $cmpDir) {
    Get-ChildItem -LiteralPath $cmpDir -Filter '*.json' | Sort-Object LastWriteTime |
        ForEach-Object { Say ("  {0,-28} {1}  {2} B" -f $_.Name, $_.LastWriteTime.ToString('HH:mm:ss'), $_.Length) }
} else { Say '  (none yet)' }

# ---- verdict ---------------------------------------------------------------
Say ''
Say '================ PREFLIGHT VERDICT ================'
if ($blockers.Count -eq 0) {
    Say "  GO  ($($warns.Count) warning(s))"
} else {
    Say "  NO-GO  -- $($blockers.Count) blocker(s):"
    foreach ($b in $blockers) { Say "    ! $b" }
}
foreach ($w in $warns) { Say "    ~ $w" }

Say ''
Say 'NEXT (see migration doc section 36):'
Say '  0. capture baselines FIRST (before any switch):'
Say '                         qmt-compare-backends.ps1 -Capture mini-666-before -Port 8002 -Account 666810082889 -ConfigYml config.local.666.yml'
Say '                         qmt-compare-backends.ps1 -Capture mini-020-before -Port 8001 -Account 020100053835 -ConfigYml config.local.020.yml'
Say '  1. P2 real-order test: ALREADY DONE on 2026-09-15 10:37 (passed, doc section 46) -- do NOT repeat'
Say '  2. switch:             switch-proxy-backend.ps1 -Service QMTProxy-666 -Backend bridge'
Say '                         switch-proxy-backend.ps1 -Service QMTProxy-020 -Backend bridge'
Say '  3. verify the backend: OPEN A SESSION FIRST, then read health/ready:'
Say '                         POST /api/v1/trading/sessions  ->  200'
Say '                         GET  /health/ready            ->  backend="bridge" AND status="ready"'
Say '                         (with no session it is backend="none"/status="idle" while success stays true)'
Say '  4. compare:            qmt-compare-backends.ps1 -Capture bridge-666-after -Port 8002 -Account 666810082889 -ConfigYml config.local.666.yml'
Say '                         qmt-compare-backends.ps1 -CompareA mini-666-before -CompareB bridge-666-after'
Say '  5. boot chain:         qmt-boot-chain.ps1 -Target bigqmt'

if ($blockers.Count -gt 0) { exit 1 }
exit 0
