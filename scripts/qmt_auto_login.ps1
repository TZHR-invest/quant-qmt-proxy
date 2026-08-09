<#
.SYNOPSIS
    自动点击 MiniQMT 登录按钮（账号/密码/验证码已自动填充，只需点登录）。
    以交互用户身份运行（SYSTEM 会话无法操作桌面窗口）。
    登录界面窗口标题为 "XtMiniQmt"；已登录主界面标题含券商名/账号，自动跳过。
.PARAMETER ExePath
    指定只处理该路径的 XtMiniQmt（如 G:\qmt\bin.x64\XtMiniQmt.exe）；
    留空则处理全部 XtMiniQmt 进程。
#>
param(
    [string]$ExePath = ""
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class QmtWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004

function Get-QmtProcess {
    param([string]$exePath)
    $procs = Get-Process -Name XtMiniQmt -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
    if ($exePath) { $procs = $procs | Where-Object { $_.Path -eq $exePath } }
    return $procs
}

# 判断是否为待登录界面窗口；返回 true 则调用方应点击登录
function Test-LoginWindow {
    param($proc)
    $title = $proc.MainWindowTitle
    # 登录界面标题固定为 "XtMiniQmt"；主界面标题含券商名/账号（如 "王白凡01 - 华泰证券QMT实盘 2.1.19.1"）
    if ($title -ne "XtMiniQmt") {
        return $false
    }
    $rect = New-Object QmtWin32+RECT
    [QmtWin32]::GetWindowRect($proc.MainWindowHandle, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    # 最小化窗口（坐标 -32000）或尺寸异常 → 非登录界面
    if ($rect.Left -le -30000 -or $w -lt 200 -or $h -lt 100) {
        return $false
    }
    return $true
}

function Invoke-LoginClick {
    param($proc)
    Write-Host "[$($proc.Path)] 检测到登录界面，点击登录按钮..."
    [QmtWin32]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 800
    $rect = New-Object QmtWin32+RECT
    [QmtWin32]::GetWindowRect($proc.MainWindowHandle, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    # 登录按钮中心：截图基准 624x415 中位于 (338,347) -> 相对 (0.542, 0.836)
    $bx = $rect.Left + [int]($w * 0.542)
    $by = $rect.Top + [int]($h * 0.836)
    Write-Host "[$($proc.Path)] 点击 @ ($bx, $by)"
    [QmtWin32]::SetCursorPos($bx, $by) | Out-Null
    Start-Sleep -Milliseconds 300
    [QmtWin32]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [QmtWin32]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [IntPtr]::Zero)
}

# 最多等 12 轮（每 5 秒，共 60 秒）让登录窗口出现
$clicked = $false
for ($round = 0; $round -lt 12; $round++) {
    $procs = Get-QmtProcess -exePath $ExePath
    foreach ($proc in $procs) {
        if (Test-LoginWindow -proc $proc) {
            Invoke-LoginClick -proc $proc
            $clicked = $true
        }
    }
    if ($clicked) { break }
    Start-Sleep -Seconds 5
}

if ($clicked) {
    Write-Host "=== 已点击登录，等待 15 秒 ==="
    Start-Sleep -Seconds 15
    Write-Host "=== 完成 ==="
} else {
    Write-Host "=== 未发现需要点击的登录界面（QMT 可能已登录或未启动）==="
}
