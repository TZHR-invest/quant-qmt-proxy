<#
  qmt-boot-both.ps1 -- logon entry point that brings up the FULL big-QMT client
  for ALL THREE installations, one after the other.

  WHY THIS EXISTS (2026-09-15, extended to three installs 2026-09-28)
  ------------------------------------------------------------------
  qmt-boot-chain.ps1 rewrites the QMT-AutoLogin task to run
  qmt-bigqmt-fullmode.ps1 with NO -QmtDir/-Service, i.e. the launcher defaults
  (G:\qmt1 / QMTProxy-666) -- 666 only.  That was fine while miniQMT auto-started
  itself from the HKCU Run keys (two entries named "...QMT..._mini" / "..._mini_666",
  both pointing at XtMiniQmt.exe, doc section 52).
  As soon as those keys are removed -- which IS the "give up miniQMT" step -- a
  reboot+logon would leave 020's bridge down, silently killing account 020's
  trading channel (devbox holds live connections to 8001).  So the logon chain
  has to cover every install BEFORE the mini keys go away.  The third account
  (2986, install G:\qmt2, service QMTProxy-2986) has no mini path at all and
  joined the same chain on 2026-09-28.

  Each leg is the SAME call that has already been verified:
    666  : exercised end-to-end on 2026-09-15 (EXIT=0, twice, doc section 42)
    020  : exercised end-to-end on 2026-09-15 11:51 (EXIT=0, doc section 53)
    2986 : third install, service registered 2026-09-28 (same call shape)
  This script adds nothing clever -- it just runs them in order and reports.

  BEHAVIOUR
    * -SkipServiceStop on every leg: the launcher only ever does `sc stop`, so
      without it a logon would leave every proxy STOPPED (doc section 44).
    * -SkipIfLoggedIn on every leg: a logon when the clients are already up is a
      no-op instead of a restart.
    * a failure on ANY leg does NOT stop the following legs (020 and 2986 must
      still come up).
    * every leg's exit code is echoed, and the launcher's own log has the detail.

  EXIT CODES
    0  = all three legs reported success
    20 = ONLY the 666 leg failed (020 and 2986 were still attempted)
    21 = ONLY the 020 leg failed (666 and 2986 were still attempted)
    22 = ONLY the 2986 leg failed (666 and 020 were still attempted)
    30 = TWO OR MORE legs failed
    2  = bad invocation (a launcher script is missing)

    ⚠️ 22 CHANGED MEANING on 2026-09-28.  It used to mean "BOTH legs failed"
    (0 = both OK / 20 = 666 / 21 = 020 / 22 = both).  A two-value encoding cannot
    express "2986 is down while the other two are fine", and reporting that as a
    total boot failure is exactly how a real single-account outage gets ignored.
    The mapping is now 20/21/22 = THAT ONE leg failed, 30 = two or more failed.
    Anyone still reading 22 as "everything failed" will UNDER-report one leg, so
    the per-leg exit codes are always printed -- read those, not just the code.
#>
param(
    [string]$ProxyDir = 'G:\qmt_projects\quant-qmt-proxy',
    [int]$WaitSec = 0,
    # 2026-09-15 17:11: was 0.  The launcher's final act is a strategy-liveness
    # check and the strategy only auto-starts a few seconds AFTER login is
    # confirmed (measured t+8s), so 0 makes every cold-boot leg exit 6 and the
    # whole boot look failed even when every client came up fine.  30s is the
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
    #     a manual experiment) -- without this the boot would leave EVERY proxy
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
    @{ Name = '666';  QmtDir = 'G:\qmt1'; Service = 'QMTProxy-666';  AccountId = '666810082889' },
    @{ Name = '020';  QmtDir = 'G:\qmt';  Service = 'QMTProxy-020';  AccountId = '020100053835' },
    @{ Name = '2986'; QmtDir = 'G:\qmt2'; Service = 'QMTProxy-2986'; AccountId = '666656292986' }
)

Say '=== boot all big-QMT installs ==='
# One accumulator per leg, keyed by leg name -- NOT $rc666/$rc020 style variables.
# The two-variable version could only encode two legs, so adding a third one
# silently dropped it from the verdict (a failed 2986 leg would have been reported
# as "BOOT OK").  A table keyed by the leg actually iterated cannot go stale.
$legRc = @{}
foreach ($leg in $legs) { $legRc[$leg.Name] = -1 }
foreach ($leg in $legs) {
    Say ("--- leg " + $leg.Name + " : " + $leg.QmtDir + " / " + $leg.Service + " / " + $leg.AccountId + " ---")
    if (-not (Test-Path -LiteralPath $leg.QmtDir)) {
        Say ("  SKIP: " + $leg.QmtDir + " does not exist")
        $legRc[$leg.Name] = 2
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
        $legRc[$leg.Name] = 0
        continue
    }
    & $psExe @a
    $rc = $LASTEXITCODE
    if ($null -eq $rc) { $rc = 0 }
    Say ("  leg " + $leg.Name + " exit=" + $rc)
    $legRc[$leg.Name] = $rc
}

if ($AllowServiceStop) {
    Say ''
    Say 'WARNING: -AllowServiceStop was given. The launcher stops the service and does NOT start it;'
    Say '         QMT-Proxy-AutoStart (logon only) is the only thing that would bring it back.'
}

Say ''
Say '--- service state after the boot (REPORT ONLY, we do not start them) ---'
foreach ($s in @('QMTProxy-666', 'QMTProxy-020', 'QMTProxy-2986')) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    Say ("  " + $s + " = " + $(if ($svc) { $svc.Status } else { 'MISSING' }))
}
# Deliberately NOT starting the services here.  The lifecycle has its own owner:
# QMT-Proxy-AutoStart (logon trigger, delay PT1M) runs restart-proxy.ps1
# -WaitMinutes 15, i.e. it comes up ~30s after this script starts and waits up to
# 15 minutes for the client to be ready.  Starting them here would only race it
# (and could bring the proxy up before the in-QMT strategy is registered).
Say '  (QMT-Proxy-AutoStart owns the service lifecycle: PT1M logon trigger + restart-proxy.ps1 -WaitMinutes 15)'

# Verdict: count the failed legs, then map to the documented exit codes.  The
# per-leg exit codes are always printed (the "leg X exit=N" lines above) so a
# single failed leg is diagnosable without decoding the aggregate code.
Say ''
$failed = @($legs | Where-Object { $legRc[$_.Name] -ne 0 })
$detail = (($legs | ForEach-Object { $_.Name + "=" + $legRc[$_.Name] }) -join '  ')
if ($failed.Count -eq 0) { Say '=== BOOT BOTH OK ==='; exit 0 }
if ($failed.Count -ge 2) {
    Say ("=== BOOT FAILED: " + $failed.Count + " legs failed (" + $detail + ") ===")
    exit 30
}
$only = $failed[0].Name
$code = switch ($only) { '666' { 20 } '020' { 21 } '2986' { 22 } default { 30 } }
Say ("=== " + $only + " LEG FAILED (exit " + $legRc[$only] + "); the other legs were still attempted: " + $detail + " ===")
exit $code
