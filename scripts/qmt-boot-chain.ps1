<#
.SYNOPSIS
    Point the logon task QMT-AutoLogin at the big-QMT launcher, or back at the
    mini auto-login (2026-09-15 big-QMT migration).

.DESCRIPTION
    QMT-AutoLogin fires at logon+30s as the INTERACTIVE user.  It must stay that
    way: the big-QMT UI automation needs a real desktop, so a SYSTEM task cannot
    click the login button.

    Before the migration it ran qmt_auto_login.ps1 (logs into miniQMT).
    After the proxy services are on the bridge, boot must instead bring up the
    FULL big-QMT client and let the strategy start itself (startupAutorun).

    *** The boot chain and the proxy backend must always agree. ***
    If QMT boots as big QMT while a proxy still expects miniQMT, restart-proxy.ps1
    waits for a XtMiniQmt.exe that will never appear, so the service is NEVER
    started.  This script therefore cross-checks both services' NSSM environment
    and refuses a mismatch unless -Force is given.

.EXAMPLE
    .\qmt-boot-chain.ps1 -Target bigqmt -DryRun
    .\qmt-boot-chain.ps1 -Target bigqmt
    .\qmt-boot-chain.ps1 -Target mini            # rollback
#>
param(
    [Parameter(Mandatory=$true)][ValidateSet('bigqmt','mini')][string]$Target,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$nssm     = "$proxyDir\nssm.exe"
$TaskName = 'QMT-AutoLogin'
$logDir   = "$proxyDir\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = "$logDir\bootchain-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Say([string]$m) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $m"
    Write-Host $line
    Add-Content -Path $log -Value $line
}

function Get-Backend([string]$svc) {
    # nssm prints AppEnvironmentExtra as UTF-16 (NUL between every ASCII char), so
    # matching the raw string always fails and the service reads as 'mini'.
    # Measured 2026-09-15 16:43: both proxies were on the bridge while this
    # function said mini/mini -- which made `-Target bigqmt` refuse (fail-safe)
    # and would have made `-Target mini` (rollback) ignore a real mismatch
    # (fail-UNSAFE).  Strip the NULs first.
    $raw = ""
    try { $raw = (& $nssm get $svc AppEnvironmentExtra 2>$null | Out-String) } catch { }
    $flat = ($raw -replace "`0", '')
    $hasPythonPath = [bool]($flat -match 'PYTHONPATH')
    $hasBridge = [bool]($flat -match 'bridge-client')
    if ($flat.Length -eq 0) {
        Say "  WARN: could not read AppEnvironmentExtra for $svc -- assuming mini"
    } elseif ($hasPythonPath -ne $hasBridge) {
        Say "  WARN: $svc env is inconsistent (PYTHONPATH=$hasPythonPath bridge-client=$hasBridge) -- assuming mini"
    }
    if ($hasPythonPath -and $hasBridge) { return 'bridge' }
    return 'mini'
}

$want = if ($Target -eq 'bigqmt') { 'bridge' } else { 'mini' }
$b020 = Get-Backend 'QMTProxy-020'
$b666 = Get-Backend 'QMTProxy-666'

Say "=== boot chain -> $Target (proxy side should be '$want') ==="
Say "  QMTProxy-020 backend = $b020"
Say "  QMTProxy-666 backend = $b666"

$mismatch = @()
if ($Target -eq 'bigqmt') { if ($b020 -ne 'bridge') { $mismatch += 'QMTProxy-020' }
                            if ($b666 -ne 'bridge') { $mismatch += 'QMTProxy-666' } }
else                      { if ($b020 -eq 'bridge') { $mismatch += 'QMTProxy-020' }
                            if ($b666 -eq 'bridge') { $mismatch += 'QMTProxy-666' } }

if ($mismatch.Count -gt 0) {
    $msg = "proxy backend does NOT match target '$Target' for: " + ($mismatch -join ', ')
    if (-not $Force) {
        Say "REFUSING: $msg"
        Say "  Boot chain and proxy backend must flip together (see migration doc 29.2)."
        Say "  Switch the proxy first, or pass -Force if you really mean it."
        exit 3
    }
    Say "WARNING (-Force): $msg"
}

$script = if ($Target -eq 'bigqmt') { "$proxyDir\scripts\qmt-boot-both.ps1" }
          else                      { "$proxyDir\scripts\qmt_auto_login.ps1" }
# -SkipServiceStop is REQUIRED, not cosmetic: the launcher only ever does `sc stop`
# and NEVER `sc start` (it was written as a manual experiment).  If this task is
# fired while the proxy services are RUNNING -- a manual drill, or a second logon
# without a reboot -- the launcher would stop both proxies and nothing would start
# them again, because QMT-Proxy-AutoStart only fires on a logon event.  After a
# real reboot the services are DEMAND_START and not running anyway, so skipping the
# stop changes nothing there; the service lifecycle belongs to QMT-Proxy-AutoStart.
#
# 2026-09-15: the bigqmt target used to be qmt-bigqmt-fullmode.ps1 with NO
# -QmtDir/-Service, i.e. the launcher defaults = G:\qmt1 / QMTProxy-666 -- 666 ONLY.
# That was survivable while miniQMT auto-started itself from the HKCU Run keys, but
# removing those keys IS the "give up miniQMT" step, so a logon would then leave 020
# with no client at all and its bridge permanently down.  qmt-boot-both.ps1 runs the
# 666 leg and then the 020 leg (both already verified end-to-end) and reports both
# exit codes; a failure of the first leg does not stop the second.
# 2026-09-15 17:11 (cold-boot drill): this used to be '-ObserveSec 0'.  The
# launcher's LAST act is a strategy-liveness check, and `startupAutorun` only
# starts the in-QMT strategy a few seconds AFTER the login is confirmed
# (measured t+8s).  With -ObserveSec 0 that check ran too early, every leg exited
# 6, and the task reported 22 -- i.e. a fully SUCCESSFUL cold boot (both clients,
# both strategies, both services verified up) was reported as a failure, which is
# exactly the kind of false alarm that trains people to ignore the task.  30s
# covers the measured autorun delay with margin.
$argLine = if ($Target -eq 'bigqmt') { '-SkipIfLoggedIn -SkipServiceStop -ObserveSec 30' } else { '' }

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Say "ERROR: scheduled task $TaskName not found"; exit 2 }
Say "  current action: $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
Say "  target  action: powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" $argLine"

if ($DryRun) { Say 'DRY RUN: task not changed'; Say '=== end (dry run) ==='; exit 0 }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $script, $argLine).Trim()

Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null
if ($LASTEXITCODE -ne 0 -and -not $?) { Say "ERROR: Set-ScheduledTask failed"; exit 1 }

$after = Get-ScheduledTask -TaskName $TaskName
Say "  new action: $($after.Actions[0].Execute) $($after.Actions[0].Arguments)"
Say "=== BOOT CHAIN OK: $TaskName now starts '$Target' ==="
Say "  reminder: the strategy starts itself (startupAutorun); reboot drill: see migration doc 29.5 step 6"
exit 0
