# window-entry.ps1 -- read-only inventory for the switch window (safe to run anytime).
$ErrorActionPreference = 'Continue'
$PS = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

Write-Output ("time=" + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss ddd'))

Write-Output "--- clients (pid / path / hwnd) ---"
Get-Process -Name XtItClient, XtMiniQmt -ErrorAction SilentlyContinue |
    Sort-Object ProcessName, Id |
    ForEach-Object {
        $p = ''
        try { $p = $_.Path } catch { $p = '(no path)' }
        Write-Output ("  " + $_.ProcessName + " pid=" + $_.Id + " hwnd=" + $_.MainWindowHandle + " start=" + $_.StartTime.ToString('HH:mm:ss') + " path=" + $p)
    }

Write-Output "--- services ---"
Get-Service QMTProxy-666, QMTProxy-020 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output ("  " + $_.Name + " = " + $_.Status) }

# Ports: judge = netstat, NOT Get-NetTCPConnection.  On 2026-09-15 13:30 the CIM
# cmdlet returned an EMPTY set for 8001/8002 while netstat showed them LISTENING
# on unchanged pids -- with -ErrorAction SilentlyContinue that printed "NO" for
# both production ports, i.e. a false "production is down".  Never let a silent
# failure become a verdict; disagreement is printed instead.
Write-Output "--- ports (judge = netstat; cim as cross-check) ---"
$nsOut = (& "$env:SystemRoot\System32\netstat.exe" -ano | Out-String)
# 端口角色（2026-09-28 第三个账户 2986 上线后重划）：8001=666 生产、8002=020 生产、
# 8003=**2986 生产**（G:\qmt2 / QMTProxy-2986）、8004=步骤5 彩排副本、8007=彩排副本新默认口。
# ⇒ 8003 以前是彩排副本口，现在必须留在清单里当**生产**看：看到 8003 在听别读成"副本起来了"。
# ⇒ 8007 是 8003/50053 让给 2986 生产之后，副本（bridge-test-666.bat 等）挪过去的口。
foreach ($p in 8001, 8002, 8003, 8004, 8007) {
    $hit = @(($nsOut -split "`r?`n") | Where-Object { $_ -match (":" + $p + "\s") -and $_ -match 'LISTENING' })
    $np = ''
    if ($hit.Count -gt 0) { $f = @($hit[0].Trim() -split '\s+'); $np = $f[$f.Count - 1] }
    $cim = @(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
    $cp = ''
    if ($cim.Count -gt 0) { $cp = [string]$cim[0].OwningProcess }
    $note = ''
    if ($np -ne '' -and $cp -eq '') { $note = '   <-- CIM MISSED IT (known flake)' }
    Write-Output ("  " + $p + " listen=" + $(if ($np -ne '') { 'yes pid=' + $np } else { 'no' }) + " cim=" + $(if ($cp -ne '') { $cp } else { '-' }) + $note)
}

Write-Output "--- strategy log freshness (the 57.7 self-check) ---"
$today = Get-Date -Format 'yyyyMMdd'
foreach ($d in 'G:\qmt1', 'G:\qmt') {
    $f = Join-Path $d ("userdata\log\XtClient_FormulaOutput_" + $today + ".log")
    if (Test-Path -LiteralPath $f) {
        $fi = Get-Item -LiteralPath $f
        $age = [int]((Get-Date) - $fi.LastWriteTime).TotalSeconds
        Write-Output ("  " + $d + " size=" + $fi.Length + " age=" + $age + "s fresh=" + ($age -lt 60))
    } else {
        Write-Output ("  " + $d + " MISSING")
    }
}

Write-Output "--- link* files (must be only explicit names) ---"
foreach ($d in 'G:\qmt1', 'G:\qmt') {
    $ls = @(Get-ChildItem -LiteralPath $d -Filter 'link*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    Write-Output ("  " + $d + " : " + $(if ($ls.Count -gt 0) { $ls -join ',' } else { '(none)' }))
}

Write-Output "--- register-check (read-only, exit code is the verdict) ---"
foreach ($acct in '666', '020') {
    $out = (& $PS -NoProfile -ExecutionPolicy Bypass -File 'G:\qmt_projects\quant-qmt-proxy\scripts\qmt-register-check.ps1' -Account $acct 2>&1 | Out-String)
    $rc = $LASTEXITCODE
    $lines = @($out.Trim() -split "`r?`n")
    $last = ''
    if ($lines.Count -gt 0) { $last = $lines[$lines.Count - 1] }
    # Print the FAIL COUNT, not just the last line.  With 2 failures the last line is
    # still a '!' line, so "the last line" alone is indistinguishable from "1 failure"
    # -- that ambiguity misled me on 2026-09-15 14:19 (see migration doc 57.19.3).
    $fails = @($lines | Where-Object { $_ -match '^\s*! ' })
    Write-Output ("  -Account " + $acct + " exit=" + $rc + " fails=" + $fails.Count + " | " + $last.Trim())
}

Write-Output "--- qmt-load-clipboard for 020 (only sets the clipboard) ---"
$cl = (& $PS -NoProfile -ExecutionPolicy Bypass -File 'G:\qmt_projects\quant-qmt-proxy\scripts\qmt-load-clipboard.ps1' -Account 020 2>&1 | Out-String)
Write-Output ("  exit=" + $LASTEXITCODE)
Write-Output ("  " + $cl.Trim())
exit 0
