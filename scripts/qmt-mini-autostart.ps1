<#
  qmt-mini-autostart.ps1 -- inspect / disable / restore the miniQMT autostart entries.

  WHY THIS EXISTS (2026-09-15)
  ---------------------------
  miniQMT is NOT started by a scheduled task and NOT by a service: it is started
  by the per-user "Run" registry key, one entry per installation (doc section 52):

      HKCU\Software\Microsoft\Windows\CurrentVersion\Run
        <broker>QMT<...>_mini      -> G:\qmt\bin.x64\XtMiniQmt.exe    (020)
        <broker>QMT<...>_mini_666  -> G:\qmt1\bin.x64\XtMiniQmt.exe   (666)
        <broker>QMT<...>           -> ...\XtItClient.exe (stale, empty dir -- harmless)
  (The real names are Chinese; they are read out of the registry, never hardcoded
  here, and this tool prints them verbatim.)

  The scheduled task QMT-AutoLogin only CLICKS LOGIN; it never starts a process.
  So "give up miniQMT" == stop the two XtMiniQmt processes AND remove these two
  values.  Removing a Run value is a real user-visible change, so this tool always
  writes a JSON backup before touching anything, and -Mode restore puts it back.

  MATCHING RULE: a value is a mini entry when its DATA contains 'XtMiniQmt.exe'
  (case-insensitive).  We deliberately do NOT match on the value NAME -- the names
  are Chinese and hardcoding them in a .ps1 invites the GBK mojibake already seen
  in this project.  The name is read back from the registry and passed through
  as a string, which is exact.

  MODES
    status   (default) list every Run value, flag the ones pointing at QMT binaries
    disable  back up, then remove the XtMiniQmt.exe values; verify none remain
    restore  recreate the values from the backup file; verify

  EXIT CODES
    0 = ok (status: nothing to do is still ok; disable: no mini values left)
    3 = a needed input is missing (backup file absent for restore)
    4 = verification failed after the change (state is NOT what we wanted)
    5 = backup could not be written (nothing was removed)
    6 = a value could not be removed
    7 = a value could not be recreated
#>
param(
    [ValidateSet('status', 'disable', 'restore')]
    [string]$Mode = 'status',
    [string]$BackupPath = 'G:\qmt_projects\quant-qmt-proxy\logs\run-keys-mini-backup.json',
    [int]$ShowAll = 1
)
$ErrorActionPreference = 'Stop'

$RUN = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$MARK = 'XtMiniQmt.exe'
$MARK2 = 'XtItClient.exe'
function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }

function Get-RunEntries {
    $item = Get-Item -LiteralPath $RUN
    $names = $item.GetValueNames()
    $out = @()
    foreach ($n in $names) {
        $v = $item.GetValue($n)
        # NOT `Kind = if (...) {...}`: an if-statement as a hashtable value is
        # fragile on Windows PowerShell 5.1.  Compute it first.
        $kind = 'String'
        if ($v -is [array]) { $kind = 'ExpandString' }
        $out += [pscustomobject]@{
            Name = $n
            Data = [string]$v
            Kind = $kind
        }
    }
    return $out
}

function Test-Mini($e) { return ($e.Data -like ('*' + $MARK + '*')) }

Write-Output ('=== qmt-mini-autostart mode=' + $Mode + ' host=' + $env:COMPUTERNAME + ' ===')
$all = @(Get-RunEntries)
Say ("HKCU Run entries total = " + $all.Count)

$mini = @($all | Where-Object { Test-Mini $_ })
$itc = @($all | Where-Object { $_.Data -like ('*' + $MARK2 + '*') })
$other = @($all | Where-Object { ($_.Data -like '*qmt*') -and (-not (Test-Mini $_)) -and ($_.Data -notlike ('*' + $MARK2 + '*')) })

Say ''
Say ('--- miniQMT autostart entries (' + $mini.Count + ') ---')
if ($mini.Count -eq 0) { Say '  (none)' }
foreach ($e in $mini) { Say ('  [MINI] ' + $e.Name + '  =  ' + $e.Data) }

Say ''
Say ('--- other QMT-ish entries (' + ($itc.Count + $other.Count) + ') ---')
foreach ($e in $itc) { Say ('  [ITCLIENT/stale] ' + $e.Name + '  =  ' + $e.Data) }
foreach ($e in $other) { Say ('  [other] ' + $e.Name + '  =  ' + $e.Data) }

if ($ShowAll -eq 1) {
    Say ''
    Say ('--- all ' + $all.Count + ' entries (context; do not touch the unrelated ones) ---')
    foreach ($e in $all) { Say ('  ' + $e.Name + '  =  ' + $e.Data) }
}

if ($Mode -eq 'status') {
    Say ''
    if ($mini.Count -gt 0) {
        Say ('STATUS: miniQMT WILL auto-start at logon (' + $mini.Count + ' entries)')
    } else {
        Say 'STATUS: miniQMT will NOT auto-start at logon (0 entries)'
    }
    Say ('backup file: ' + $BackupPath + '  exists=' + (Test-Path -LiteralPath $BackupPath))
    Say 'RESULT: status ok'
    exit 0
}

if ($Mode -eq 'disable') {
    if ($mini.Count -eq 0) {
        Say ''
        Say 'DISABLE: nothing to do -- no XtMiniQmt.exe entry in HKCU Run'
        Say 'RESULT: ok'
        exit 0
    }
    $dir = Split-Path -Parent $BackupPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        $payload = [pscustomobject]@{
            written_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            host        = $env:COMPUTERNAME
            user        = $env:USERNAME
            key         = $RUN
            entries     = @($mini | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Data = $_.Data; Kind = $_.Kind } })
        }
        $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $BackupPath -Encoding UTF8
    } catch {
        Say ('ERROR: could not write backup: ' + $_.Exception.Message)
        Say 'RESULT: aborting, nothing was removed'
        exit 5
    }
    Say ''
    Say ('backup written: ' + $BackupPath)
    $failed = 0
    foreach ($e in $mini) {
        try {
            Remove-ItemProperty -LiteralPath $RUN -Name $e.Name -ErrorAction Stop
            Say ('  removed: ' + $e.Name)
        } catch {
            Say ('  FAILED to remove: ' + $e.Name + ' -- ' + $_.Exception.Message)
            $failed++
        }
    }
    $after = @(Get-RunEntries)
    $left = @($after | Where-Object { Test-Mini $_ })
    Say ''
    Say ('verification: XtMiniQmt.exe entries remaining = ' + $left.Count)
    foreach ($e in $left) { Say ('  STILL PRESENT: ' + $e.Name + ' = ' + $e.Data) }
    if ($failed -gt 0) { Say ('RESULT: FAILED (' + $failed + ' removals errored)'); exit 6 }
    if ($left.Count -gt 0) { Say 'RESULT: FAILED (verification found survivors)'; exit 4 }
    Say 'RESULT: miniQMT autostart disabled; restore with -Mode restore'
    exit 0
}

# restore
if (-not (Test-Path -LiteralPath $BackupPath)) {
    Say ''
    Say ('ERROR: backup file not found: ' + $BackupPath)
    Say 'RESULT: cannot restore without a backup'
    exit 3
}
$b = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
Say ''
Say ('restoring from backup written ' + $b.written_utc + ' (host ' + $b.host + ')')
$failed = 0
foreach ($e in @($b.entries)) {
    try {
        New-ItemProperty -LiteralPath $RUN -Name $e.Name -Value $e.Data -PropertyType String -Force -ErrorAction Stop | Out-Null
        Say ('  restored: ' + $e.Name + ' = ' + $e.Data)
    } catch {
        Say ('  FAILED to restore: ' + $e.Name + ' -- ' + $_.Exception.Message)
        $failed++
    }
}
$after = @(Get-RunEntries)
$want = @($b.entries).Count
$have = @($after | Where-Object { Test-Mini $_ }).Count
Say ''
Say ('verification: wanted ' + $want + ' mini entries, found ' + $have)
if ($failed -gt 0) { Say ('RESULT: FAILED (' + $failed + ' restores errored)'); exit 7 }
if ($have -lt $want) { Say 'RESULT: FAILED (fewer entries than the backup had)'; exit 4 }
Say 'RESULT: miniQMT autostart restored'
exit 0
