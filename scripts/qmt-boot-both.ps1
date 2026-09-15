<#
  qmt-boot-both.ps1 -- logon entry point that brings up the FULL big-QMT client
  for BOTH installations, one after the other.

  WHY THIS EXISTS (2026-09-15)
  ---------------------------
  qmt-boot-chain.ps1 rewrites the QMT-AutoLogin task to run
  qmt-bigqmt-fullmode.ps1 with NO -QmtDir/-Service, i.e. the launcher defaults
  (G:\qmt1 / QMTProxy-666) -- 666 only.  That was fine while miniQMT auto-started
  itself from the HKCU Run keys (two entries named "...QMT..._mini" / "..._mini_666",
  both pointing at XtMiniQmt.exe, doc section 52).
  As soon as those keys are removed -- which IS the "give up miniQMT" step -- a
  reboot+logon would leave 020's bridge down, silently killing account 020's
  trading channel (devbox holds live connections to 8001).  So the logon chain
  has to cover both installs BEFORE the mini keys go away.

  Each leg is the SAME call that has already been verified:
    666 : exercised end-to-end on 2026-09-15 (EXIT=0, twice, doc section 42)
    020 : exercised end-to-end on 2026-09-15 11:51 (EXIT=0, doc section 53)
  This script adds nothing clever -- it just runs them in order and reports.

  BEHAVIOUR
    * -SkipServiceStop on both legs: the launcher only ever does `sc stop`, so
      without it a logon would leave both proxies STOPPED (doc section 44).
    * -SkipIfLoggedIn on both legs: a logon when the clients are already up is a
      no-op instead of a restart.
    * a failure on the first leg does NOT stop the second (020 must still come up).
    * every leg's exit code is echoed, and the launcher's own log has the detail.

  EXIT CODES
    0  = both legs reported success
    20 = the 666 leg failed (020 was still attempted)
    21 = the 020 leg failed (666 was still attempted)
    22 = both legs failed
    2  = bad invocation (a launcher script is missing)
#>
param(
    [string]$ProxyDir = 'G:\qmt_projects\quant-qmt-proxy',
    [int]$WaitSec = 0,
    # 2026-09-15 17:11: was 0.  The launcher's final act is a strategy-liveness
    # check and the strategy only auto-starts a few seconds AFTER login is
    # confirmed (measured t+8s), so 0 makes every cold-boot leg exit 6 and the
    # whole boot look failed even when both clients came up fine.  30s is the
    # measured autorun delay plus margin.
    [int]$ObserveSec = 30,
    # Accepted for compatibility with the logon task's argument string
    # (`... qmt-boot-both.ps1 -SkipIfLoggedIn -SkipServiceStop -ObserveSec 0`).
    # BOTH ARE ALSO THE DEFAULT BEHAVIOUR below, so passing them changes nothing --
    # they are declared only so the intent is explicit and greppable rather than
    # being silently absorbed as stray arguments.
    [switch]$SkipIfLoggedIn,
    [switch]$SkipServiceStop,
    # Opt-outs.  Safe by default on purpose:
    #   * we pass -SkipServiceStop unless -AllowServiceStop is given, because the
    #     launcher only ever does `sc stop` and NEVER `sc start` (it was written as
    #     a manual experiment) -- without this the boot would leave BOTH proxies
    #     STOPPED and nothing would start them (migration doc section 44).
    #   * we pass -SkipIfLoggedIn unless -ForceRelaunch is given, so a boot when the
    #     clients are already healthy is a no-op instead of a restart.
    [switch]$AllowServiceStop,
    [switch]$ForceRelaunch,
    # Print what each leg WOULD run, touch nothing.  Lets the argument wiring be
    # verified without launching a trading client.
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'

$launcher = Join-Path $ProxyDir 'scripts\qmt-bigqmt-fullmode.ps1'
function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }

if (-not (Test-Path -LiteralPath $launcher)) { Say "ERROR: launcher not found: $launcher"; exit 2 }

$legs = @(
    @{ Name = '666'; QmtDir = 'G:\qmt1'; Service = 'QMTProxy-666'; AccountId = '666810082889' },
    @{ Name = '020'; QmtDir = 'G:\qmt';  Service = 'QMTProxy-020'; AccountId = '020100053835' }
)

Say '=== boot both big-QMT installs ==='
$rc666 = -1
$rc020 = -1
foreach ($leg in $legs) {
    Say ("--- leg " + $leg.Name + " : " + $leg.QmtDir + " / " + $leg.Service + " / " + $leg.AccountId + " ---")
    if (-not (Test-Path -LiteralPath $leg.QmtDir)) {
        Say ("  SKIP: " + $leg.QmtDir + " does not exist")
        if ($leg.Name -eq '666') { $rc666 = 2 } else { $rc020 = 2 }
        continue
    }
    # RUN THE LAUNCHER AS A CHILD powershell.exe, with an ARRAY of native args.
    #
    # 2026-09-15 16:51 -- this used to be `& $launcher @a` with $a an ARRAY.
    # PowerShell splats an array POSITIONALLY, which is a NATIVE-command idiom:
    # for a PowerShell command every element is bound to the next positional
    # parameter, so the literal string '-QmtDir' was fed to -WaitSec and both legs
    # died instantly with
    #     Cannot convert value "-QmtDir" to type "System.Int32"
    # Exit code 22, and the launcher never even created its output dir => the
    # logon path brought up NOTHING, for both installs.  The -DryRun branch below
    # never called the launcher, which is exactly why the dry run always "passed"
    # while the real path had never once executed.  (Removing the miniQMT Run keys
    # -- the "give up miniQMT" step -- would then have left a reboot with NO
    # trading channel at all.)
    #
    # A child powershell.exe with an argument ARRAY is both the shape that has
    # been verified by hand all day (`powershell -File <launcher> -QmtDir ...`)
    # and the only one where $LASTEXITCODE is guaranteed to carry the launcher's
    # own exit code: in-process, the launcher's SUCCESS path ends without an
    # explicit `exit`, so $LASTEXITCODE would keep a stale value and a successful
    # boot would be reported as a failure.
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
           '-QmtDir', $leg.QmtDir, '-Service', $leg.Service, '-AccountId', $leg.AccountId)
    if (-not $ForceRelaunch) { $a += '-SkipIfLoggedIn' }
    if (-not $AllowServiceStop) { $a += '-SkipServiceStop' }
    if ($WaitSec -gt 0) { $a += @('-WaitSec', "$WaitSec") }
    $a += @('-ObserveSec', "$ObserveSec")
    if ($DryRun) {
        Say ('  DRY RUN would run: ' + $psExe + ' ' + ($a -join ' '))
        if ($leg.Name -eq '666') { $rc666 = 0 } else { $rc020 = 0 }
        continue
    }
    & $psExe @a
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    Say ("  leg " + $leg.Name + " exit=" + $rc)
    if ($leg.Name -eq '666') { $rc666 = $rc } else { $rc020 = $rc }
}

if ($AllowServiceStop) {
    Say ''
    Say 'WARNING: -AllowServiceStop was given. The launcher stops the service and does NOT start it;'
    Say '         QMT-Proxy-AutoStart (logon only) is the only thing that would bring it back.'
}

Say ''
Say '--- service state after the boot (REPORT ONLY, we do not start them) ---'
foreach ($s in @('QMTProxy-666', 'QMTProxy-020')) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    Say ("  " + $s + " = " + $(if ($svc) { $svc.Status } else { 'MISSING' }))
}
# Deliberately NOT starting the services here.  The lifecycle has its own owner:
# QMT-Proxy-AutoStart (logon trigger, delay PT1M) runs restart-proxy.ps1
# -WaitMinutes 15, i.e. it comes up ~30s after this script starts and waits up to
# 15 minutes for the client to be ready.  Starting them here would only race it
# (and could bring the proxy up before the in-QMT strategy is registered).
Say '  (QMT-Proxy-AutoStart owns the service lifecycle: PT1M logon trigger + restart-proxy.ps1 -WaitMinutes 15)'

Say ''
if ($rc666 -eq 0 -and $rc020 -eq 0) { Say '=== BOOT BOTH OK ==='; exit 0 }
if ($rc666 -ne 0 -and $rc020 -ne 0) { Say ("=== BOOT BOTH FAILED (666=" + $rc666 + " 020=" + $rc020 + ") ==="); exit 22 }
if ($rc666 -ne 0) { Say ("=== 666 LEG FAILED (exit " + $rc666 + "); 020 leg rc=" + $rc020 + " ==="); exit 20 }
Say ("=== 020 LEG FAILED (exit " + $rc020 + "); 666 leg rc=" + $rc666 + " ===")
exit 21
