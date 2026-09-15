<#
  qmt-click.ps1 -- click one point inside a QMT client window, safely.

  Companion to qmt-focus.ps1.  Two clients share an identical title and rect on
  this machine, so a click must be aimed at a PID and the window must be raised
  (and confirmed) first -- otherwise the click lands in the other client.

  Coordinates are WINDOW-RELATIVE (the window sits at 0,0 on a 1920x1080 screen,
  so window coords == screen coords; the script adds the window origin anyway).

  Every click is followed by a screenshot, so "what did that do?" is always
  answerable after the fact.

  USAGE
    qmt-click.ps1 -X 1019 -Y 15                       # XtItClient, shot after
    qmt-click.ps1 -Image XtMiniQmt -X 100 -Y 200 -ShotBefore
#>
param(
    [int]$X,
    [int]$Y,
    [string]$Image = 'XtItClient',
    [int]$TargetPid = 0,
    [int]$SettleMs = 900,
    [string]$Tag = 'click',
    [switch]$ShotBefore,
    [switch]$NoFocus
)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class QC {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  public static List<string> All() {
    List<string> res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
      RECT r; GetWindowRect(h, out r);
      res.Add(h.ToInt64() + "|" + pid + "|" + c.ToString() + "|" + r.Left + "," + r.Top + "," + (r.Right-r.Left) + "," + (r.Bottom-r.Top));
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@
function Say($m) { Write-Output $m }
function Shot([string]$path, [int]$x, [int]$y, [int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

if ($TargetPid -eq 0) {
    $proc = Get-Process -Name $Image -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
    if (-not $proc) { Say "ERROR: no process named '$Image'"; exit 2 }
    $TargetPid = $proc.Id
}
$best = $null; $bestArea = 0
foreach ($w in [QC]::All()) {
    $p = $w.Split('|')
    if ([int]$p[1] -ne $TargetPid) { continue }
    $g = $p[3].Split(','); $area = [int]$g[2] * [int]$g[3]
    if ($area -gt $bestArea) { $bestArea = $area; $best = $p }
}
if (-not $best) { Say "ERROR: pid $TargetPid has no visible window"; exit 3 }
$hwnd = [IntPtr][int64]$best[0]
$g = $best[3].Split(',')
$ox = [int]$g[0]; $oy = [int]$g[1]; $ow = [int]$g[2]; $oh = [int]$g[3]
Say "target pid=$TargetPid hwnd=$($hwnd.ToInt64()) origin=($ox,$oy) size=${ow}x${oh}"

if (-not $NoFocus) {
    [void][QC]::SetWindowPos($hwnd, [IntPtr]::Zero, $ox, $oy, $ow, $oh, 0x0040)
    [void][QC]::BringWindowToTop($hwnd)
    [void][QC]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 500
    if ([QC]::GetForegroundWindow() -ne $hwnd) {
        Say 'ERROR: could not confirm this window is in front -- refusing to click (would hit the other client)'
        exit 4
    }
    Say 'focus confirmed'
}

if ($ShotBefore) { Shot "C:\temp\p0\${Tag}_before.png" $ox $oy $ow $oh; Say "shot before -> ${Tag}_before.png" }

$sx = $ox + $X; $sy = $oy + $Y
Say "clicking window($X,$Y) == screen($sx,$sy)"
[void][QC]::SetCursorPos($sx, $sy)
Start-Sleep -Milliseconds 120
[QC]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)   # left down
Start-Sleep -Milliseconds 60
[QC]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)   # left up
Start-Sleep -Milliseconds $SettleMs

Shot "C:\temp\p0\${Tag}_after.png" $ox $oy $ow $oh
Say "shot after  -> ${Tag}_after.png"
exit 0
