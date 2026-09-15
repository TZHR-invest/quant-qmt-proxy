<#
  qmt-focus.ps1 -- raise ONE QMT client's own window and screenshot it.

  WHY THIS EXISTS
  ---------------
  On this machine the full client (XtItClient.exe) and the mini client
  (XtMiniQmt.exe) both own a visible 1920x1040 window at (0,0) with the SAME
  title ("<user> - <broker>QMT-live <ver>").  CopyFromScreen grabs whatever is
  visually on top, so:
      * you can NOT tell the clients apart by title, and
      * a screenshot taken without raising the right window may silently show
        the OTHER client.
  Everything here therefore targets a PID, raises that pid's largest visible
  window, verifies with GetForegroundWindow, and only then captures.

  It is READ-ONLY: no clicks, no keys, no state changes.  Z-order is the only
  thing it touches.

  NOTE: the parameter is -TargetPid and not -Pid on purpose -- $Pid is a
  READ-ONLY automatic variable in PowerShell and using it as a parameter name
  fails with "Cannot overwrite variable Pid because it is read-only".

  USAGE
    qmt-focus.ps1                                  # XtItClient, default shot path
    qmt-focus.ps1 -Image XtMiniQmt -Shot C:\temp\p0\mini.png
    qmt-focus.ps1 -TargetPid 30048 -NoRaise              # just report + capture as-is
#>
param(
    [string]$Image = 'XtItClient',
    [int]$TargetPid = 0,
    [string]$Shot = '',
    [switch]$NoRaise
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class QF {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  public static List<string> All() {
    List<string> res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
      StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512);
      RECT r; GetWindowRect(h, out r);
      res.Add(h.ToInt64() + "|" + pid + "|" + c.ToString() + "|" + t.ToString() + "|" + r.Left + "," + r.Top + "," + (r.Right-r.Left) + "," + (r.Bottom-r.Top));
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
function Say($m) { Write-Output $m }

if ($TargetPid -eq 0) {
    $proc = Get-Process -Name $Image -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
    if (-not $proc) { Say "ERROR: no process named '$Image'"; exit 2 }
    $TargetPid = $proc.Id
}
Say "target pid : $TargetPid"

# pick the largest visible window owned by this pid (the main frame, not a tooltip)
$best = $null; $bestArea = 0
foreach ($w in [QF]::All()) {
    $p = $w.Split('|')
    if ([int]$p[1] -ne $TargetPid) { continue }
    $g = $p[4].Split(',')
    $area = [int]$g[2] * [int]$g[3]
    if ($area -gt $bestArea) { $bestArea = $area; $best = $p }
}
if (-not $best) { Say "ERROR: pid $TargetPid has no visible top-level window"; exit 3 }
$hwnd = [IntPtr][int64]$best[0]
$g = $best[4].Split(',')
Say ("window     : class=" + $best[2] + " title=[" + $best[3] + "]")
Say ("geometry   : " + $best[4] + "  (area=" + $bestArea + ")")

$fgBefore = [QF]::GetForegroundWindow()
Say ("foreground before: " + $fgBefore.ToInt64())
$isFgBefore = ($fgBefore -eq $hwnd)

if (-not $NoRaise) {
    # 0x0040 = SWP_SHOWWINDOW ; keep the window exactly where it is otherwise
    [void][QF]::SetWindowPos($hwnd, [IntPtr]::Zero, [int]$g[0], [int]$g[1], [int]$g[2], [int]$g[3], 0x0040)
    [void][QF]::BringWindowToTop($hwnd)
    [void][QF]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 800
}
$fgAfter = [QF]::GetForegroundWindow()
Say ("foreground after : " + $fgAfter.ToInt64() + "  is-target=" + ($fgAfter -eq $hwnd))

if ($Shot -eq '') { $Shot = "C:\temp\p0\focus_$Image.png" }
$bmp = New-Object System.Drawing.Bitmap ([int]$g[2]), ([int]$g[3])
$gr = [System.Drawing.Graphics]::FromImage($bmp)
$gr.CopyFromScreen([int]$g[0], [int]$g[1], 0, 0, (New-Object System.Drawing.Size ([int]$g[2]), ([int]$g[3])))
$bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
$gr.Dispose(); $bmp.Dispose()
$md5 = (Get-FileHash -LiteralPath $Shot -Algorithm MD5).Hash
Say ("shot       : $Shot  (" + (Get-Item -LiteralPath $Shot).Length + " B, md5 " + $md5 + ")")
if (-not $isFgBefore -and -not $NoRaise -and ($fgAfter -ne $hwnd)) {
    Say "WARN: could not confirm this window became the foreground window -- the shot may show another client"
}
exit 0
