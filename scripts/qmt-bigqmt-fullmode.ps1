# qmt-bigqmt-fullmode.ps1 (v4) -- start the FULL big-QMT client instead of miniQMT
#   v4 (2026-09-15): -QmtDir/-Service so one script drives BOTH installs, and all
#     process handling is scoped by ExecutablePath (a blanket taskkill /IM would
#     kill the other account's client, which after the migration is that account's
#     production channel).  Also refuses to launch when the scoped cleanup did not
#     finish.  See migration doc 38/38.5/42.
#
# Switch (user, 2026-09-15): the login dialog's "独立交易" checkbox.
#   [x] 独立交易 -> miniQMT      [ ] 独立交易 -> the full 大QMT client
#
# Findings from the two round-8 experiments that shaped this v2:
#   * un-ticking 独立交易 ALONE is ignored, because 自动登录 (remembered session)
#     fires the login and never consults the checkbox.
#   * un-ticking 自动登录 AFTER 独立交易 RE-TICKS 独立交易, so the order matters:
#     kill 自动登录 first, then 独立交易, then press the login button.
#   * GetWindowRect() returns the DWM-extended frame (624x443), while the real
#     client area is inset 12 px on every side (600x419).  All coordinates here
#     are therefore relative to the CLIENT area:
#         clientL = L + 12, clientT = T + 12, clientW = W - 24, clientH = H - 24
#     calibrated fractions inside that client area:
#         checkboxes y = 0.7220 * Hc
#         记住密码 x 0.3092 | 自动登录 x 0.4425 | 独立交易 x 0.5908
#         login button (0.3783, 0.7947)
#   * every checkbox toggle is pixel-verified (a ticked box is a solid blue
#     glyph) and retried, so we never press 登录 from the wrong state.
#
# ASCII only in all code and string literals: the file travels into a
# GBK-default Windows PowerShell session.  Chinese appears in comments only.

param(
    [int]$WaitSec      = 30,
    [int]$ObserveSec   = 150,
    [int]$Inset        = 12,
    [string]$AccountId = '666810082889',
    [int]$LoginWaitSec = 45,
    [int]$LoginRetries = 3,
    # Which QMT install to drive, and which proxy service serves it.  Two
    # installs live on this machine (G:\qmt1 = 666, G:\qmt = 020) and each has
    # its own XtItClient.exe.  Everything below derives from $QmtDir, and the
    # process handling is scoped to it: a blanket `taskkill /IM XtItClient.exe`
    # would kill the OTHER account's client, which after the migration is that
    # account's production trading channel.
    [string]$QmtDir     = 'G:\qmt1',
    [string]$Service    = 'QMTProxy-666',
    [switch]$AutoLogin,
    [switch]$SkipIfLoggedIn,
    [switch]$SkipServiceStop
)

$ErrorActionPreference = 'SilentlyContinue'
$BinDir  = Join-Path $QmtDir 'bin.x64'
$Exe     = Join-Path $BinDir 'XtItClient.exe'
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutDir  = "C:\temp\p0\fm2_$Stamp"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$TL = Join-Path $OutDir 'timeline.txt'
$K  = "$env:SystemRoot\System32"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class FM2 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    public static List<string> AllVisible() {
        List<string> res = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
            StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
            RECT r; GetWindowRect(h, out r);
            uint pid; GetWindowThreadProcessId(h, out pid);
            res.Add(h.ToInt64() + "|" + pid + "|" + c.ToString() + "|" + t.ToString() + "|" +
                    r.Left + "," + r.Top + "," + (r.Right - r.Left) + "," + (r.Bottom - r.Top));
            return true;
        }, IntPtr.Zero);
        return res;
    }
    public static List<string> WindowsOfPid(uint want) {
        List<string> res = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != want) return true;
            if (!IsWindowVisible(h)) return true;
            StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
            StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
            RECT r; GetWindowRect(h, out r);
            res.Add(h.ToInt64() + "|" + c.ToString() + "|" + t.ToString() + "|" +
                    r.Left + "," + r.Top + "," + (r.Right - r.Left) + "," + (r.Bottom - r.Top));
            return true;
        }, IntPtr.Zero);
        return res;
    }
    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(70);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);
        System.Threading.Thread.Sleep(50);
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);
    }
}
"@

function Log([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $m
    Write-Output $line
    Add-Content -Path $TL -Value $line -Encoding UTF8
}

function Snap([string]$path, [int]$x, [int]$y, [int]$w, [int]$h) {
    try {
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $true
    } catch { return $false }
}

# A ticked checkbox is a solid blue glyph on white.  Sample the glyph box and
# report the fraction of strongly-blue pixels; >35% means "ticked".
function Test-Checked([int]$cx, [int]$cy) {
    try {
        $w = 12; $h = 12
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen(($cx - 6), ($cy - 6), 0, 0, (New-Object System.Drawing.Size $w, $h))
        $blue = 0
        for ($yy = 0; $yy -lt $h; $yy++) {
            for ($xx = 0; $xx -lt $w; $xx++) {
                $c = $bmp.GetPixel($xx, $yy)
                if (($c.B -gt 140) -and (($c.B - $c.R) -gt 40) -and (($c.B - $c.G) -gt 20)) { $blue++ }
            }
        }
        $g.Dispose(); $bmp.Dispose()
        return ($blue / ($w * $h)) -gt 0.35
    } catch { return $false }
}

# ------------------------------------------------------------- login proof
# 2026-09-15: a click on the login button can silently do nothing.  XtItClient
# stays ALIVE either way and MainWindowTitle is IDENTICAL in both states, so
# "process alive" is NOT a success criterion.  The terminal's own message log
# is authoritative:
#   <qmt>\userdata\log\XtClient_Message_<yyyyMMdd>.log
#   "... [msg service] msg: <cjk> [<acct>] <cjk>!, account: 2____10007____8888____49____<acct>____"
# Only ASCII anchors are matched, so this is immune to the script's own
# encoding:  "!, account:"  followed by a token containing the account id.
function Get-MsgLogPath {
    $d = Join-Path (Split-Path $BinDir -Parent) 'userdata\log'
    return (Join-Path $d ('XtClient_Message_' + (Get-Date).ToString('yyyyMMdd') + '.log'))
}

function Get-MsgLogSize {
    $f = Get-MsgLogPath
    if (Test-Path $f) { return ([long](Get-Item $f).Length) }
    return [long]0
}

function Test-LoginSuccess([long]$fromOffset) {
    $f = Get-MsgLogPath
    if (-not (Test-Path $f)) { return $false }
    try {
        $fs = [System.IO.File]::Open($f, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read,
                                     [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -le $fromOffset) { $fs.Close(); return $false }
        $fs.Seek($fromOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buf = New-Object byte[] ($len - $fromOffset)
        [void]$fs.Read($buf, 0, $buf.Length)
        $fs.Close()
        $txt = [System.Text.Encoding]::GetEncoding(936).GetString($buf)
        return ($txt -match ('!, account:[^\r\n]*' + [regex]::Escape($AccountId)))
    } catch { return $false }
}

# Liveness of the in-QMT strategy: it prints a cadence line every 10 s, so a
# fresh FormulaOutput log means the bridge is actually running.
function Test-StrategyLive {
    $p = Join-Path (Split-Path $BinDir -Parent) 'userdata\log'
    $f = Join-Path $p ('XtClient_FormulaOutput_' + (Get-Date).ToString('yyyyMMdd') + '.log')
    if (-not (Test-Path $f)) { return $false }
    return (((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds -lt 60)
}

function Move-DialogsOffscreen([string]$why) {
    foreach ($w in [FM2]::AllVisible()) {
        $p = $w.Split('|')
        if ($p[2] -eq '#32770') {
            Log "  [$why] moving dialog off-screen handle=$($p[0])"
            [FM2]::SetWindowPos([IntPtr][int64]$p[0], [IntPtr]::Zero, -3000, -3000, 0, 0, 0x0005) | Out-Null
            Start-Sleep -Milliseconds 120
        }
    }
}

$script:EnumUnreliable = $false

function Get-QmtProcs([string]$name) {
    # ONLY processes started from this install's bin.x64 -- the guard that keeps
    # a 666 run and a 020 run from killing each other.
    #
    # 2026-09-15 16:52 (logon task, fixed here): this used to ask WMI once PER PID
    #     Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
    # In the scheduled-task context that call failed, the catch left $path empty,
    # and EVERY process was filtered out -- so the -SkipIfLoggedIn gate read "no
    # client running" while one WAS running (Dump-State, which enumerates by NAME,
    # saw it fine), the guard below also saw nothing, and the launcher started a
    # SECOND client on the same install; that duplicate could not show a login
    # window, so both legs failed (task result 22) and a stray client was left
    # behind.  ONE CIM query by name does the whole job, and it is the query
    # proven to work in that context.
    $want = $name
    if ($want -notlike '*.exe') { $want = $want + '.exe' }
    $cim = @(Get-CimInstance Win32_Process -Filter "Name='$want'" -ErrorAction SilentlyContinue)
    $out = @()
    foreach ($p in $cim) {
        $path = [string]$p.ExecutablePath
        if ($path -and $path.ToLower().StartsWith($BinDir.ToLower())) {
            $out += [pscustomobject]@{ Id = [int]$p.ProcessId; Name = $want; Path = $path }
        }
    }
    # Cross-check with a completely different mechanism.  "WMI listed nothing at
    # all while Get-Process sees processes" is NOT "nothing is running", it is
    # "I cannot tell" -- and guessing in that direction launches a duplicate
    # client, i.e. the documented zombie/hang failure.  So fail loudly instead.
    # (A genuine "only the other install is running" case has $cim.Count > 0.)
    $seen = @(Get-Process -Name $name -ErrorAction SilentlyContinue).Count
    if ($cim.Count -eq 0 -and $seen -gt 0) {
        Log ("  WARN: Get-Process sees {0} '{1}' process(es) but WMI listed none -- treating enumeration as UNRELIABLE" -f $seen, $name)
        $script:EnumUnreliable = $true
    }
    # 2026-09-15 17:0x (logon task, measured): a scheduled task running with a
    # LIMITED token gets Win32_Process ROWS with an EMPTY ExecutablePath for every
    # process that already existed (only its own children show a path) -- the same
    # for Process.Path.  The rows exist, so the check above does not fire, and
    # $out is empty => "no client of this install" while one IS running.  An
    # unattributable process must therefore also count as "I cannot tell", never
    # as "not mine".  Fixed by running the logon task with -RunLevel Highest
    # (migration doc 57); this keeps the non-elevated path (e.g. the watchdog's
    # deep recovery) FAIL-CLOSED instead of double-launching.
    $noPath = @($cim | Where-Object { -not ([string]$_.ExecutablePath) })
    if ($noPath.Count -gt 0) {
        Log ("  WARN: {0} '{1}' process(es) have NO readable image path (pid {2}) -- cannot tell whose they are" -f $noPath.Count, $name, (($noPath | ForEach-Object { $_.ProcessId }) -join ','))
        Log "        (typical cause: this launcher runs with a limited token, e.g. a logon task without RunLevel Highest)"
        $script:EnumUnreliable = $true
    }
    return $out
}

function Get-Procs {
    $names = @('XtItClient','XtMiniQmt','miniquote','minibroker','BrokerProxy','pythonw','CefViewWing','Crashui')
    $rows = @()
    foreach ($n in $names) {
        foreach ($p in (Get-Process -Name $n)) {
            $ppid = ''
            try { $ppid = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").ParentProcessId } catch {}
            $rows += ("{0} pid={1} ppid={2} ws={3}MB title=[{4}]" -f $p.ProcessName, $p.Id, $ppid, [math]::Round($p.WorkingSet64/1MB,0), $p.MainWindowTitle)
        }
    }
    return $rows
}

function Dump-State([string]$tag) {
    Log "---- STATE: $tag ----"
    foreach ($r in (Get-Procs)) { Log "  $r" }
    # explicit names only: a link* glob also matches LinkageTrade*.dll
    $linkNames = @('linkQmt','linkMini','linkMiniQmt','link_reboot','linkResearchMini','linkResearchMini_reboot')
    $links = @()
    foreach ($n in $linkNames) { $f = Join-Path $BinDir $n; if (Test-Path -LiteralPath $f) { $links += (Get-Item -LiteralPath $f) } }
    if ($links) { foreach ($l in $links) { Log ("  link: {0} size={1} mtime={2}" -f $l.Name, $l.Length, $l.LastWriteTime.ToString('HH:mm:ss')) } }
    else { Log "  link: (none)" }
    Log "  $Service`: $((& "$K\sc.exe" query $Service | Select-String 'STATE'))"
}

function Get-Target([int]$pid1) {
    foreach ($w in [FM2]::WindowsOfPid([uint32]$pid1)) {
        $parts = $w.Split('|'); $geo = $parts[3].Split(',')
        if ($parts[1] -eq 'Qt5QWindowIcon' -and [int]$geo[2] -gt 400 -and [int]$geo[2] -lt 1200 -and
            [int]$geo[3] -gt 300 -and [int]$geo[3] -lt 900) {
            return @{ hand = [int64]$parts[0]; title = $parts[2]
                      lft = [int]$geo[0]; tp = [int]$geo[1]; wid = [int]$geo[2]; hgt = [int]$geo[3] }
        }
    }
    return $null
}

# ---------------------------------------------------------------- main
Log "=== full-mode v4 start; QmtDir=$QmtDir Service=$Service account=$AccountId ==="
Log "OutDir=$OutDir"
Dump-State 'pre'
Move-DialogsOffscreen 'pre'

if ($SkipIfLoggedIn) {
    $p0 = @(Get-QmtProcs 'XtItClient') | Select-Object -First 1
    if ($p0 -and (Test-StrategyLive)) {
        Log "already up: XtItClient pid=$($p0.Id) and the bridge strategy is live -> nothing to do"
        Log "=== full-mode v4 end (no-op) ==="
        Write-Output "OUTDIR=$OutDir"
        exit 0
    }
}

if (-not $SkipServiceStop) {
    Log "stopping $Service"
    & "$K\sc.exe" stop $Service | Out-Null
    Start-Sleep -Seconds 6
}
Log "killing leftovers of THIS install only: $BinDir"
$killed = 0
foreach ($n in @('XtItClient', 'Crashui')) {
    foreach ($p in (Get-QmtProcs $n)) {
        Log ("  kill {0} pid={1}" -f $n, $p.Id)
        & "$K\taskkill.exe" /F /PID $p.Id 2>&1 | Out-Null
        $killed++
    }
}
if ($killed -eq 0) { Log "  (no leftovers of this install)" }
Start-Sleep -Milliseconds 900

# GUARD (2026-09-15): Get-QmtProcs filters on ExecutablePath, so if that read
# ever fails it silently returns NOTHING -- and we would launch a second client
# on the same install while the first is still up.  That is the documented
# "zombie XtItClient makes the launcher hang" failure (4 zombies -> 180s timeout
# -> 666 down for 5 minutes).  Refuse to launch until the install is clean.
$still = @(Get-QmtProcs 'XtItClient')
if ($script:EnumUnreliable) {
    Log "ERROR: cannot enumerate this install's XtItClient.exe reliably (WMI by name returned nothing while Get-Process saw processes)."
    Log "  Refusing to launch: a duplicate client on one install is the documented zombie/hang failure."
    Log "  Re-run from an interactive session, or check the WMI service (migration doc 44 / 57)."
    Dump-State 'enum-unreliable'
    exit 8
}
if ($still.Count -gt 0) {
    Log ("ERROR: {0} XtItClient.exe of THIS install still alive after kill: {1}" -f $still.Count, (($still | ForEach-Object { $_.Id }) -join ','))
    Log "  refusing to launch another one (two clients on one install = zombie/hang)"
    Dump-State 'kill-failed'
    exit 7
}
Log "  verified clean: no XtItClient.exe left for this install"
Move-DialogsOffscreen 'armed'

Log "launching $Exe"
$proc = Start-Process -FilePath $Exe -WorkingDirectory $BinDir -PassThru
Log "launched pid=$($proc.Id)"

$target = $null
$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline) {
    $proc.Refresh()
    if ($proc.HasExited) { Log "exited before window appeared"; break }
    $target = Get-Target $proc.Id
    if ($target) { break }
    Start-Sleep -Milliseconds 30
}
if (-not $target) {
    Log "ERROR: login window not found in ${WaitSec}s"
    foreach ($r in (Get-Procs)) { Log "  post: $r" }
    exit 2
}
Log ("FOUND handle={0} title=[{1}] rect=({2},{3}) {4}x{5}" -f $target.hand, $target.title, $target.lft, $target.tp, $target.wid, $target.hgt)

# client area (GetWindowRect gives the DWM-extended frame)
$cl = $target.lft + $Inset
$ct = $target.tp + $Inset
$cw = $target.wid - 2 * $Inset
$ch = $target.hgt - 2 * $Inset
Log "client area = ($cl,$ct) ${cw}x${ch}"

$chkY  = $ct + [int](0.7220 * $ch)
$xRm   = $cl + [int](0.3092 * $cw)   # remember-password
$xAuto = $cl + [int](0.4425 * $cw)   # auto-login
$xInd  = $cl + [int](0.5908 * $cw)   # standalone-trade
$xOk   = $cl + [int](0.3783 * $cw)   # login button
$yOk   = $ct + [int](0.7947 * $ch)
$rowX  = $cl + [int](0.22 * $cw)
$rowW  = [int](0.62 * $cw)

# The dialog exists (and IsWindowVisible is true) well before Qt paints it --
# an immediate capture sees whatever was behind it.  So poll until the checkbox
# row actually renders: re-raise the window, wait, and look for the solid blue
# glyph of the remember-password box.
$sRm = $false; $sAuto = $false; $sInd = $false
for ($i = 1; $i -le 40; $i++) {
    [FM2]::SetWindowPos([IntPtr]$target.hand, [FM2]::HWND_TOPMOST, $target.lft, $target.tp, $target.wid, $target.hgt, 0x0040) | Out-Null
    [FM2]::SetForegroundWindow([IntPtr]$target.hand) | Out-Null
    [FM2]::BringWindowToTop([IntPtr]$target.hand) | Out-Null
    Start-Sleep -Milliseconds 400
    $sRm   = Test-Checked $xRm   $chkY
    $sAuto = Test-Checked $xAuto $chkY
    $sInd  = Test-Checked $xInd  $chkY
    if ($sRm -or $sAuto -or $sInd) { Log "dialog rendered after $i probe(s)"; break }
}
Log "initial checkbox state: rememberPwd=$sRm autoLogin=$sAuto standaloneTrade=$sInd"
Snap (Join-Path $OutDir 'step0_row.png') $rowX ($chkY - 15) $rowW 32 | Out-Null
Snap (Join-Path $OutDir 'step0_win.png') $target.lft $target.tp $target.wid $target.hgt | Out-Null
if (-not ($sRm -or $sAuto -or $sInd)) {
    Log "WARN: dialog never rendered a checkbox glyph -- aborting"
    Snap (Join-Path $OutDir 'abort_win.png') $target.lft $target.tp $target.wid $target.hgt | Out-Null
    exit 3
}
if (-not $sRm) { Log "NOTE: remember-password reads unchecked; continuing anyway" }

# --- step 1: auto-login --------------------------------------------------
# Default: leave 自动登录 OFF (then the login button is the only path and the
# 独立交易 checkbox is honoured).  With -AutoLogin the terminal is told to
# auto-login on the NEXT boot -- but 独立交易 must still end up unticked, so it
# is always fixed up in step 2, which runs after this.
if ($AutoLogin) {
    for ($i = 1; $i -le 4; $i++) {
        if (Test-Checked $xAuto $chkY) { Log "auto-login is ON (kept, -AutoLogin)"; break }
        Log "click 1.$i tick auto-login at ($xAuto,$chkY)"
        [FM2]::Click($xAuto, $chkY); Start-Sleep -Milliseconds 450
    }
} else {
    for ($i = 1; $i -le 4; $i++) {
        if (-not (Test-Checked $xAuto $chkY)) { Log "auto-login is OFF"; break }
        Log "click 1.$i un-tick auto-login at ($xAuto,$chkY)"
        [FM2]::Click($xAuto, $chkY); Start-Sleep -Milliseconds 450
    }
}
$sAuto = Test-Checked $xAuto $chkY
Log "after step1: autoLogin=$sAuto standaloneTrade=$(Test-Checked $xInd $chkY)"
Snap (Join-Path $OutDir 'step1_row.png') $rowX ($chkY - 15) $rowW 32 | Out-Null

# --- step 2: un-tick 独立交易 (must be LAST, toggling auto-login re-ticks it)
for ($i = 1; $i -le 4; $i++) {
    if (-not (Test-Checked $xInd $chkY)) { Log "standalone-trade is OFF"; break }
    Log "click 2.$i un-tick standalone-trade at ($xInd,$chkY)"
    [FM2]::Click($xInd, $chkY); Start-Sleep -Milliseconds 450
}
$sInd = Test-Checked $xInd $chkY
$sAuto = Test-Checked $xAuto $chkY
Log "after step2: autoLogin=$sAuto standaloneTrade=$sInd"
Snap (Join-Path $OutDir 'step2_row.png') $rowX ($chkY - 15) $rowW 32 | Out-Null

if ($sInd) { Log "ERROR: could not un-tick standalone-trade; aborting before login"; exit 4 }

# --- step 3: press login, then PROVE it (v3) -----------------------------
# 2026-09-15 02:20: the single click did nothing and the terminal sat on the
# login window for 4 minutes -- the old script could not tell, because it only
# watched for HasExited.  Now every attempt is verified against the terminal's
# own message log and retried.
$loggedIn = $false
for ($attempt = 1; $attempt -le $LoginRetries; $attempt++) {
    $off = Get-MsgLogSize
    Log ("click 3.$attempt : login button at ($xOk,$yOk)  [msgLogOffset=$off]")
    Snap (Join-Path $OutDir ("step3_before_$attempt.png")) $target.lft $target.tp $target.wid $target.hgt | Out-Null
    [FM2]::SetForegroundWindow([IntPtr]$target.hand) | Out-Null
    [FM2]::Click($xOk, $yOk)
    $dl = (Get-Date).AddSeconds($LoginWaitSec)
    while ((Get-Date) -lt $dl) {
        Start-Sleep -Seconds 2
        if (Test-LoginSuccess $off) { $loggedIn = $true; break }
    }
    Snap (Join-Path $OutDir ("step3_after_$attempt.png")) $target.lft $target.tp $target.wid $target.hgt | Out-Null
    if ($loggedIn) { Log "LOGIN CONFIRMED on attempt $attempt (terminal message log)"; break }
    Log "attempt $attempt : no login evidence within ${LoginWaitSec}s"
    $proc.Refresh()
    if ($proc.HasExited) { Log "XtItClient exited while logging in"; break }
}
if (-not $loggedIn) {
    Log "ERROR: login NOT confirmed after $LoginRetries attempt(s)"
    Dump-State 'login-failed'
}

$stop = (Get-Date).AddSeconds($ObserveSec)
$tick = 0
while ((Get-Date) -lt $stop) {
    Start-Sleep -Seconds 2
    $tick += 2
    $proc.Refresh()
    if ($proc.HasExited) { Log ("t+{0,3}s  XtItClient EXITED exitcode={1}" -f $tick, $proc.ExitCode); break }
    Log ("t+{0,3}s  ALIVE ws={1}MB loginConfirmed={2} strategyLive={3} title=[{4}]" -f $tick, [math]::Round($proc.WorkingSet64/1MB,0), $loggedIn, (Test-StrategyLive), $proc.MainWindowTitle)
    if ($tick -eq 10)  { Snap (Join-Path $OutDir 't10.png')  0 0 1920 1080 | Out-Null }
    if ($tick -eq 40)  { Snap (Join-Path $OutDir 't40.png')  0 0 1920 1080 | Out-Null }
    if ($tick -eq 100) { Snap (Join-Path $OutDir 't100.png') 0 0 1920 1080 | Out-Null }
    if ($tick % 20 -eq 0) { foreach ($r in (Get-Procs)) { Log "        $r" } }
}

Log "=== final ==="
Dump-State 'final'
$proc.Refresh()
if ($proc.HasExited) { Log "RESULT: XtItClient EXITED exitcode=$($proc.ExitCode)" }
else { Log "RESULT: XtItClient ALIVE pid=$($proc.Id) title=[$($proc.MainWindowTitle)]" }
Log "=== full-mode v4 end ==="
Write-Output "OUTDIR=$OutDir"
if (-not $loggedIn) { exit 5 }
# Chinese only in comments: the file must survive being re-saved as ANSI.
if (-not (Test-StrategyLive)) { Log "WARN: strategy log is stale -- check the auto-run option in model trading"; exit 6 }
