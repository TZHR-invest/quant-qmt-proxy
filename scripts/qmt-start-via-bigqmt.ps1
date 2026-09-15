<#
.SYNOPSIS
    Start a QMT instance by using the big-QMT client (XtItClient.exe) as a launcher.

.DESCRIPTION
    Why this exists (verified on trade-pc 2026-09-14):
      * XtItClient.exe is a 219 KB stub. On this HuaTai build it ALWAYS behaves as a
        "lite-mode launcher": it logs in, writes <bin.x64>\linkMini, kills any existing
        XtMiniQmt.exe that is "alive but not child process", spawns its own XtMiniQmt.exe
        and then exits normally (setNormalQuit, ExitCode=0).
      * The mini it spawns comes up ALREADY LOGGED IN (window title becomes
        "<user> - <broker>QMT... 2.1.19.1" instead of the login-window title "XtMiniQmt").
        That makes this path MORE reliable than launching XtMiniQmt.exe + clicking login
        via qmt_auto_login.ps1 (which uses absolute-coordinate mouse clicks).

    WARNING: launching XtItClient.exe KILLS any running mini of the same installation.
    Always stop the proxy service for that instance first (see -StopService), otherwise
    the proxy will start returning 503 xttrader.connect() -1 / XTTRADER_UNAVAILABLE.

.PARAMETER QmtDir
    QMT installation root, e.g. "G:\qmt" (020) or "G:\qmt1" (666).

.PARAMETER Account
    Fund account id, used only for the readiness probe.

.PARAMETER StopService
    Name of the NSSM proxy service to stop before touching the client and start after
    the mini is ready, e.g. "QMTProxy-666".

.PARAMETER TimeoutSec
    How long to wait for the mini to become ready (default 180).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File qmt-start-via-bigqmt.ps1 `
        -QmtDir "G:\qmt1" -Account "666810082889" -StopService "QMTProxy-666"

.OUTPUTS
    exit 0 = mini ready (and service restarted if requested); 1 = failed/timeout.
#>
param(
    [Parameter(Mandatory = $true)][string]$QmtDir,
    [Parameter(Mandatory = $true)][string]$Account,
    [string]$StopService = "",
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = "Continue"
$bigQmt = Join-Path $QmtDir "bin.x64\XtItClient.exe"
$miniExe = Join-Path $QmtDir "bin.x64\XtMiniQmt.exe"

function Log([string]$m) {
    Write-Output ("[" + (Get-Date -Format "HH:mm:ss") + "] " + $m)
}

if (-not (Test-Path $bigQmt)) { Log ("FATAL: not found " + $bigQmt); exit 1 }
if (-not (Test-Path $miniExe)) { Log ("FATAL: not found " + $miniExe); exit 1 }

# Normalised dir for process-path matching ("G:\qmt1" vs "G:\qmt")
$norm = $QmtDir.TrimEnd("\").ToLower()

# --- optional: stop the proxy service of this instance -----------------------
if ($StopService -ne "") {
    Log ("stopping service " + $StopService)
    & sc.exe stop $StopService | Out-Null
    Start-Sleep -Seconds 6
}

# --- kill zombie launchers FIRST -------------------------------------------
# The launcher is supposed to exit within seconds. If one is still around from an
# earlier attempt it will (a) be detected as "alive but not child process" by the
# next launcher and (b) itself try to kill/spawn minis -- the two wedge each other
# and this script then times out waiting for a new mini (observed 2026-09-14:
# four leftovers -> 180 s timeout, 666 stuck with no mini and a stopped service).
$zombies = @(Get-Process XtItClient -ErrorAction SilentlyContinue)
if ($zombies.Count -gt 0) {
    Log ("killing " + $zombies.Count + " leftover launcher process(es)")
    $zombies | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 900
}

# --- kill mini processes belonging to THIS installation ---------------------
foreach ($m in (Get-Process XtMiniQmt -ErrorAction SilentlyContinue)) {
    $p = $null
    try { $p = $m.Path } catch { }
    if ($p -and $p.ToLower().StartsWith($norm)) {
        Log ("killing existing mini pid=" + $m.Id)
        Stop-Process -Id $m.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Milliseconds 900

# --- launch big QMT (it will spawn + auto-login the mini, then exit) --------
Log ("launching launcher: " + $bigQmt)
$before = @(Get-Process XtMiniQmt -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
try {
    Start-Process -FilePath $bigQmt -WorkingDirectory (Join-Path $QmtDir "bin.x64") | Out-Null
} catch {
    Log ("FATAL: launch failed: " + $_.Exception.Message); exit 1
}

# --- wait for a NEW mini process -------------------------------------------
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$newMini = $null
while ((Get-Date) -lt $deadline) {
    foreach ($m in (Get-Process XtMiniQmt -ErrorAction SilentlyContinue)) {
        $p = $null
        try { $p = $m.Path } catch { }
        if (-not $p) { continue }
        if (-not $p.ToLower().StartsWith($norm)) { continue }
        if ($before -notcontains $m.Id) { $newMini = $m; break }
    }
    if ($newMini) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $newMini) {
    # Observed 2026-09-14: after several launch/kill cycles the launcher can stop
    # spawning a mini at all. Degrade to starting the mini directly; the caller can
    # then run qmt_auto_login.ps1 (coordinate click) to log it in.
    Log "WARN: launcher produced no mini; falling back to direct mini start"
    try {
        Start-Process -FilePath $miniExe -WorkingDirectory (Join-Path $QmtDir "bin.x64") | Out-Null
    } catch {
        Log ("FATAL: direct mini start failed: " + $_.Exception.Message); exit 1
    }
    $fbDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $fbDeadline) {
        foreach ($m in (Get-Process XtMiniQmt -ErrorAction SilentlyContinue)) {
            $p = $null
            try { $p = $m.Path } catch { }
            if ($p -and $p.ToLower().StartsWith($norm) -and ($before -notcontains $m.Id)) { $newMini = $m; break }
        }
        if ($newMini) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $newMini) { Log "FAIL: mini did not start either"; exit 1 }
    Log ("fallback mini pid=" + $newMini.Id + "  (if its title is 'XtMiniQmt' it needs the login script)")
}
Log ("new mini pid=" + $newMini.Id)

# --- wait for the LOGIN WINDOW title to become the main-window title -------
# login window title is exactly "XtMiniQmt"; after login it contains the broker name
$loginOk = $false
while ((Get-Date) -lt $deadline) {
    $m = Get-Process -Id $newMini.Id -ErrorAction SilentlyContinue
    if (-not $m) { Log "FAIL: mini process exited"; break }
    $t = $m.MainWindowTitle
    if ($t -and $t -ne "XtMiniQmt") { $loginOk = $true; Log ("mini window title=[" + $t + "]"); break }
    Start-Sleep -Milliseconds 800
    $m.Refresh()
}
if (-not $loginOk) {
    Log "WARN: window title still looks like a login window; falling back to channel probe"
}

# --- channel probe: xtquant connect + subscribe -----------------------------
$ready = Join-Path $QmtDir "..\qmt_projects\quant-qmt-proxy\scripts\qmt_ready_check.py"
$py = Join-Path $QmtDir "..\qmt_projects\quant-qmt-proxy\.venv\Scripts\python.exe"
if ((Test-Path $ready) -and (Test-Path $py)) {
    $userdata = Join-Path $QmtDir "userdata_mini"
    Log ("probe: qmt_ready_check.py " + $userdata + " " + $Account)
    $out = & $py $ready $userdata $Account 30 2>&1 | Out-String
    Log ("probe output: " + $out.Trim())
    if ($LASTEXITCODE -ne 0) { Log "FAIL: trading channel not ready"; exit 1 }
    Log "trading channel READY"
} else {
    Log ("WARN: probe script or python not found, skipping (" + $ready + ")")
}

# --- restart the proxy service ---------------------------------------------
if ($StopService -ne "") {
    Log ("starting service " + $StopService)
    & sc.exe start $StopService | Out-Null
    Start-Sleep -Seconds 10
}

Log "DONE"
exit 0
