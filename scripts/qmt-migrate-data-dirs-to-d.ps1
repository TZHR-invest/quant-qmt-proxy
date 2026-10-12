<#
.SYNOPSIS
  Move a QMT install's *data* directories to D: via junctions (trade-pc, Windows).

.DESCRIPTION
  Moves, per install:
     <Install>\userdata  ->  D:\<Tag>_userdata   (full client data: logs, up_queue_*, users\<user>\accountInfo.ini)
     <Install>\datadir   ->  D:\<Tag>_datadir    (local tick library; 666 reached 23.6 GB)
  Deliberately does NOT move: bin.x64 / config / plugins / xtmodel / updater / ... (program+config; the
  client updater rewrites them, and 020/666 have always kept them on G), and userdata_mini itself
  (its bulk, datadir, is already a junction to D; wrapping it would nest junctions for ~1 GB of state).

  Steps (only steps 3-8 are downtime):
    0) preflight: src is a real dir, dst absent, backup name free, exactly one XtItClient for this install
    1) robocopy /MIR pass 1 with the client still running (no downtime; locked files come in pass 2)
    2) sc stop <Service> (+ taskkill the leftover python child still holding the port, if any)
    3) graceful close via CloseMainWindow(); after 60 s falls back to taskkill /F
       MEASURED 2026-09-28: these clients do NOT honour WM_CLOSE, so the fallback always triggers.
       It is survivable: the launcher re-runs the full login and the client re-creates
       users\<user>\accountInfo.ini at the new location (verified on all three accounts).
    4) robocopy /MIR pass 2 (delta, rc must be < 8) + file-count/byte equality check
    5) rename src -> <name>.orig-<stamp>, then mklink /J src dst
    6) write-through test: write a file through the G: path and require it to appear under D:
    7) relaunch the client via qmt-bigqmt-fullmode.ps1 -SkipServiceStop -ObserveSec 40 (full login)
    8) sc start <Service>, confirm the port is listening

  Fail-closed: any problem before step 5 aborts with client/service left DOWN and NOTHING renamed,
  so a rerun is safe.  Rollback: remove the junction, rename <name>.orig-<stamp> back, restart both.

  ASCII-ONLY ON PURPOSE: PS 5.1 decodes a .ps1 without a BOM as GBK, and Chinese text broke the parser
  three times on 2026-09-28 (script silently not executed at all).  Do not add non-ASCII here.

.EXAMPLE
  & .\qmt-migrate-data-dirs-to-d.ps1 -Install 'G:\qmt2' -Service 'QMTProxy-2986' `
        -AccountId '666656292986' -Port 8003 -Tag 'qmt2' -UserTag '2986'
#>
param(
  [Parameter(Mandatory=$true)][string]$Install,
  [Parameter(Mandatory=$true)][string]$Service,
  [Parameter(Mandatory=$true)][string]$AccountId,
  [Parameter(Mandatory=$true)][int]$Port,
  [Parameter(Mandatory=$true)][string]$Tag,
  [Parameter(Mandatory=$true)][string]$UserTag
)
$K = "$env:SystemRoot\System32"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$fail = @()
function Say($m) { Write-Output ("  " + $m) }
function ListenPid([int]$p) {
  $o = & "$K\netstat.exe" -ano 2>$null | Select-String (":" + $p + "\s") | Select-String 'LISTENING'
  if (-not $o) { return $null }
  return [int](($o | Select-Object -First 1) -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
}
function Stats([string]$p) {
  $m = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
  return @{ N = $m.Count; B = [double]$m.Sum }
}
$pairs = @(
  @{ Src = (Join-Path $Install 'userdata'); Dst = ("D:\" + $Tag + "_userdata"); Bak = ('userdata.orig-' + $stamp) },
  @{ Src = (Join-Path $Install 'datadir');  Dst = ("D:\" + $Tag + "_datadir");  Bak = ('datadir.orig-'  + $stamp) }
)
Write-Output ("=== migrate " + $UserTag + " (" + $Install + ") ===")
Write-Output "--- 0) preflight ---"
foreach ($p in $pairs) {
  if (-not (Test-Path -LiteralPath $p.Src)) { $fail += ("src missing: " + $p.Src); continue }
  $it = Get-Item -Force -LiteralPath $p.Src
  if ($it.LinkType) { $fail += ("src already a link: " + $p.Src + " (" + $it.LinkType + ")") }
  if (Test-Path -LiteralPath $p.Dst) { $fail += ("dst already exists: " + $p.Dst) }
  if (Test-Path -LiteralPath (Join-Path $Install $p.Bak)) { $fail += ("backup name exists: " + $p.Bak) }
  Say ($p.Src + "  ->  " + $p.Dst)
}
$clients = @(Get-CimInstance Win32_Process -Filter "Name = 'XtItClient.exe'" | Where-Object { $_.ExecutablePath -like ($Install + '\*') })
Say ("client count = " + $clients.Count)
if ($clients.Count -ne 1) { $fail += "expect exactly 1 client for this install" }
$aiPath = Join-Path $Install 'userdata\users'
$aiBefore = $null
$aiFile = Get-ChildItem -LiteralPath $aiPath -Recurse -File -Filter 'accountInfo.ini' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($aiFile) { $aiBefore = $aiFile.LastWriteTime; Say ("accountInfo.ini before = " + $aiBefore) }
if ($fail.Count -gt 0) { Write-Output "PREFLIGHT FAIL:"; $fail | ForEach-Object { Write-Output ("   ! " + $_) }; exit 21 }
$cpid = $clients[0].ProcessId
Write-Output "--- 1) pass1 robocopy (client still running, no downtime) ---"
foreach ($p in $pairs) {
  $rc = (Start-Process -FilePath "$K\robocopy.exe" -ArgumentList @($p.Src, $p.Dst, '/MIR', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NP') -Wait -PassThru -NoNewWindow).ExitCode
  Say ($p.Src + " pass1 rc=" + $rc)
}
Write-Output "--- 2) stop proxy service ---"
& "$K\sc.exe" stop $Service | Out-Null
Start-Sleep -Seconds 5
$pp = ListenPid $Port
if ($pp) { Say ("port " + $Port + " still held by pid " + $pp + " -> taskkill"); & "$K\taskkill.exe" /F /T /PID $pp | Out-Null; Start-Sleep -Seconds 3 }
Say ("port " + $Port + " listening = " + [bool](ListenPid $Port))
Write-Output "--- 3) graceful client stop (WM_CLOSE, NOT taskkill) ---"
$forced = $false
$proc = Get-Process -Id $cpid -ErrorAction SilentlyContinue
if ($proc) { $proc.CloseMainWindow() | Out-Null }
$gone = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 2
  if (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) { $gone = $true; break }
}
if (-not $gone) {
  Say "graceful close did NOT work within 60s -> force kill (login state may need re-login)"
  & "$K\taskkill.exe" /F /PID $cpid | Out-Null
  $forced = $true
  Start-Sleep -Seconds 3
}
Say ("client exited = " + (-not (Get-Process -Id $cpid -ErrorAction SilentlyContinue)) + " ; forced = " + $forced)
$aiAfter = $null
if ($aiFile -and (Test-Path -LiteralPath $aiFile.FullName)) { $aiAfter = (Get-Item -LiteralPath $aiFile.FullName).LastWriteTime }
Say ("accountInfo.ini after  = " + $aiAfter + "  (changed=" + ($aiAfter -ne $aiBefore) + ")")
Write-Output "--- 4) pass2 robocopy (delta) + verify ---"
foreach ($p in $pairs) {
  $rc = (Start-Process -FilePath "$K\robocopy.exe" -ArgumentList @($p.Src, $p.Dst, '/MIR', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:3', '/W:2', '/NFL', '/NDL', '/NP') -Wait -PassThru -NoNewWindow).ExitCode
  $s = Stats $p.Src; $d = Stats $p.Dst
  Say ($p.Src + " pass2 rc=" + $rc + "  src=" + $s.N + "/" + $s.B + "  dst=" + $d.N + "/" + $d.B)
  if ($rc -ge 8) { $fail += ("pass2 rc=" + $rc + " for " + $p.Src) }
  if ($s.N -ne $d.N -or $s.B -ne $d.B) { $fail += ("size mismatch for " + $p.Src) }
}
Write-Output "--- 5) swap: rename + junction ---"
if ($fail.Count -gt 0) {
  Write-Output "ABORT before swap (client/proxy are DOWN, nothing renamed):"
  $fail | ForEach-Object { Write-Output ("   ! " + $_) }
  exit 22
}
foreach ($p in $pairs) {
  Rename-Item -LiteralPath $p.Src -NewName $p.Bak -ErrorAction Stop
  & "$K\cmd.exe" /c mklink /J "$($p.Src)" "$($p.Dst)" | Out-Null
  $it = Get-Item -Force -LiteralPath $p.Src
  Say ($p.Src + "  LinkType=" + $it.LinkType + "  Target=" + ($it.Target -join ','))
  if ($it.LinkType -ne 'Junction') { $fail += ("junction not created: " + $p.Src) }
}
Write-Output "--- 6) write-through test (decisive) ---"
foreach ($p in $pairs) {
  $tf = Join-Path $p.Src '__linktest.txt'
  Set-Content -LiteralPath $tf -Value ("linktest-" + $stamp) -Encoding ascii
  Start-Sleep -Milliseconds 800
  $seen = Join-Path $p.Dst '__linktest.txt'
  if (Test-Path -LiteralPath $seen) { Say ($p.Src + " write-through OK (visible at " + $seen + ")") } else { $fail += ("write-through FAILED for " + $p.Src) }
  Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
}
Write-Output "--- 7) relaunch client (full login) ---"
$L = 'G:\qmt_projects\quant-qmt-proxy\scripts\qmt-bigqmt-fullmode.ps1'
& "$K\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $L -QmtDir $Install -Service $Service -AccountId $AccountId -SkipServiceStop -ObserveSec 40 2>&1 | Select-Object -Last 6 | ForEach-Object { Say $_ }
Say ("launcher exit = " + $LASTEXITCODE)
Write-Output "--- 8) start proxy service ---"
& "$K\sc.exe" start $Service | Out-Null
Start-Sleep -Seconds 18
& "$K\sc.exe" query $Service | Select-String 'STATE' | ForEach-Object { Say $_.ToString().Trim() }
Say ("port " + $Port + " listening = " + [bool](ListenPid $Port))
$np = @(Get-CimInstance Win32_Process -Filter "Name = 'XtItClient.exe'" | Where-Object { $_.ExecutablePath -like ($Install + '\*') })
Say ("client now: count=" + $np.Count + " pid=" + (($np | ForEach-Object { $_.ProcessId }) -join ','))
Write-Output ("=== RESULT " + $UserTag + ": forced_exit=" + $forced + " failures=" + $fail.Count + " ===")
$fail | ForEach-Object { Write-Output ("   ! " + $_) }
