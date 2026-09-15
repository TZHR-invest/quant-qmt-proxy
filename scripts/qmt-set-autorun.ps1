<#
  qmt-set-autorun.ps1 -- set one boolean attribute of the BIGQMT_BRIDGE strategy item.

  DEFAULT FIELD = `startupAutorun` (the "when the terminal starts, auto-run this
  strategy" flag).  With -Field <name> the very same verified write path sets any
  other 0|1 attribute of that same item, e.g.

      -Field runMode

  Measured 2026-09-15: 666's item carries runMode="1" while 020's carries
  runMode="0" -- the two items are otherwise identical in the 70 properties that
  matter, so runMode is the item's "is this strategy actually RUNNING" state (the
  UI's model-trading table has no start/stop control at all; see migration doc 57.23).
  The script NAME is historical -- this is a generic one-byte item-flag setter.

  WHY THIS EXISTS (2026-09-15)
  ---------------------------
  The strategy auto-start flag lives in the strategy ITEM inside

      G:\qmt1\config\indexUserConfig.xml     (666)
      G:\qmt\config\indexUserConfig.xml      (020)

  as the attribute `startupAutorun="0|1"`.  Two measured facts make a script worth
  having instead of hand-editing:

    * The "new strategy file / strategy editor" dialog (the item opened by
      +new-strategy -> Python strategy) has NO autorun control: both the "basic
      info" and the "parameter settings" property tabs were read on 2026-09-15 and
      neither carries it, and the flag DEFAULTS TO "0" when the item is created.
    * 666's "1" was obtained by editing this file: the leftover backup
      `indexUserConfig.xml.bak-autorun-20260915021917` differs from the live file
      in EXACTLY that one attribute (0 -> 1).  So "set autorun" is a file edit, and
      it must happen while the client is STOPPED -- QMT writes the whole file back
      when it exits, so an edit made while it runs is silently lost.

  SAFETY DESIGN
    * the edit is BYTE-LEVEL: `<field>="` is pure ASCII, so we never decode
      and re-encode the 75 KB XML (no encoding/BOM risk at all).
    * it REFUSES unless that ASCII pattern occurs EXACTLY ONCE in the whole file --
      that is what makes a whole-file replace unambiguous.  Measured 2026-09-15:
      exactly 1 occurrence of `startupAutorun="` in 666's file (only our strategy
      sets it) and exactly 1 of `runMode="` in 020's 75 KB file.
    * it REFUSES while this install's XtItClient.exe is running (unless -Force),
      because the edit would be overwritten on exit.
    * it always writes a timestamped backup FIRST (`<file>.bak-autorun-<stamp>`,
      same naming convention as the 666 precedent).
    * -ConfigPath lets the whole write path be REHEARSED on a throwaway copy --
      a rehearsal that flips the live file is not a rehearsal.

  USAGE
    qmt-set-autorun.ps1 -Account 020 -Mode status
    qmt-set-autorun.ps1 -Account 020 -Mode on
    qmt-set-autorun.ps1 -Account 020 -Field runMode -Mode status
    qmt-set-autorun.ps1 -Account 020 -Field runMode -Mode on
    qmt-set-autorun.ps1 -Account 666 -Mode on -ConfigPath C:/temp/copy.xml   # rehearsal

  EXIT CODES
    0 ok (including "already the wanted value" and status)
    2 bad invocation
    3 config file not found
    4 the `<field>="` pattern did not occur exactly once -- refusing to guess
    5 verification failed after the write
    6 this install's client is running -- stop it first (or pass -Force)
#>
param(
    [ValidateSet('666', '020')] [string]$Account = '666',
    [ValidateSet('status', 'on', 'off')] [string]$Mode = 'status',
    [string]$Field = 'startupAutorun',
    [string]$ConfigPath = '',
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if ($Field -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
    Write-Output "ERROR: -Field must be a plain XML attribute name (got '$Field')"
    exit 2
}
# keep the 666 precedent's backup suffix for the default field
$tag = if ($Field -eq 'startupAutorun') { 'autorun' } else { $Field }

$instMap = @{
    '666' = @{ Dir = 'G:\qmt1'; Acct = '666810082889' }
    '020' = @{ Dir = 'G:\qmt';  Acct = '020100053835' }
}
$root = $instMap[$Account].Dir
$acct = $instMap[$Account].Acct
$binDir = Join-Path $root 'bin.x64'
$cfg = if ($ConfigPath -ne '') { $ConfigPath } else { Join-Path $root 'config\indexUserConfig.xml' }
$isRehearsal = ($ConfigPath -ne '')

function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }

Say ("account : $Account / $acct")
Say ("xml     : $cfg" + $(if ($isRehearsal) { '   [REHEARSAL COPY]' } else { '' }))
if (-not (Test-Path -LiteralPath $cfg)) { Say "ERROR: config not found: $cfg"; exit 3 }

$bytes = [System.IO.File]::ReadAllBytes($cfg)
$pat = [System.Text.Encoding]::ASCII.GetBytes($Field + '="')
Say ("field   : " + $Field)
Say ("size    : " + $bytes.Length + " bytes")

# ---- locate the single occurrence (plain byte search, no regex, no decoding) ----
$hits = New-Object System.Collections.ArrayList
for ($i = 0; $i -le ($bytes.Length - $pat.Length); $i++) {
    if ($bytes[$i] -ne $pat[0]) { continue }
    $ok = $true
    for ($j = 1; $j -lt $pat.Length; $j++) {
        if ($bytes[$i + $j] -ne $pat[$j]) { $ok = $false; break }
    }
    if ($ok) { [void]$hits.Add($i) }
}
Say ("pattern : " + $Field + "=`" found " + $hits.Count + " time(s)")
if ($hits.Count -ne 1) {
    if ($hits.Count -eq 0) {
        Say ("ERROR: the " + $Field + " attribute does not exist in this file at all.")
        if ($Field -eq 'startupAutorun') {
            Say '       That means the BIGQMT_BRIDGE item has not been written yet -- and the item'
            Say '       is written when the strategy is STARTED (creating it in the editor only'
            Say '       writes python\<name>.py plus the strategy LIST; see migration doc 56.10).'
            Say '       Register AND start the strategy first, then re-run this script.'
        } else {
            Say ('       So this item does not carry ' + $Field + ' -- do NOT invent it.')
            Say '       Compare against the other install''s item (666 = G:\qmt1) to see which'
            Say '       attribute actually differs before writing anything.'
        }
    } else {
        Say ("ERROR: refusing to guess -- the pattern occurs " + $hits.Count + " times.")
        Say '       More than one means other strategies also carry the flag, so a whole-file'
        Say '       replace would be ambiguous.  Locate the BIGQMT_BRIDGE item and edit by hand.'
        Say '       (first 24 bytes before each hit, to see what actually matched:)'
        foreach ($h in $hits) {
            $s = [Math]::Max(0, $h - 24)
            Say ('         @' + $h + ': ' + [System.Text.Encoding]::ASCII.GetString($bytes, $s, $h - $s))
        }
    }
    exit 4
}

$valIdx = $hits[0] + $pat.Length
$cur = [char]$bytes[$valIdx]
Say ("current : " + $Field + "=`"$cur`"")
if ($cur -ne '0' -and $cur -ne '1') { Say ("ERROR: unexpected value byte at " + $valIdx + ": " + $cur); exit 4 }

if ($Mode -eq 'status') {
    if ($Field -eq 'startupAutorun') {
        Say ("status  : " + $(if ($cur -eq '1') { 'autorun ON  (the strategy starts with the terminal)' } else { 'autorun OFF (the strategy will NOT auto-start after a terminal restart)' }))
    } else {
        Say ("status  : " + $Field + " = " + $cur + "  (no meaning assumed for this field here -- compare with the other install)")
    }
    Say 'STATUS ONLY -- nothing was changed'
    exit 0
}

$want = if ($Mode -eq 'on') { '1' } else { '0' }
if ($cur -eq $want) { Say ("ALREADY `"$want`" -- nothing to do"); exit 0 }

# ---- the client must be stopped, else QMT rewrites the file on exit ----
if (-not $isRehearsal) {
    $running = @()
    foreach ($p in (Get-Process -Name 'XtItClient' -ErrorAction SilentlyContinue)) {
        $exePath = ''
        try { $exePath = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").ExecutablePath } catch { }
        if ($exePath -and $exePath.ToLower().StartsWith($binDir.ToLower())) { $running += $p }
    }
    if ($running.Count -gt 0 -and -not $Force) {
        $pids = ($running | ForEach-Object { $_.Id }) -join ','
        Say ("ERROR: this install's XtItClient.exe is RUNNING (pid=$pids).")
        Say '       QMT writes indexUserConfig.xml back when it exits, so an edit made now would be lost.'
        Say '       Stop that client first (by pid), then re-run.  -Force overrides this refusal.'
        exit 6
    }
    if ($running.Count -gt 0) { Say 'WARNING (-Force): the client is RUNNING; your edit may be overwritten when it exits' }
}

# ---- backup, then replace that single byte ----
$bak = "$cfg.bak-$tag-" + (Get-Date -Format 'yyyyMMddHHmmss')
Copy-Item -LiteralPath $cfg -Destination $bak -Force
Say ("backup  : " + $bak)

$bytes[$valIdx] = [byte][char]$want
[System.IO.File]::WriteAllBytes($cfg, $bytes)

# ---- verify ----
$after = [System.IO.File]::ReadAllBytes($cfg)
$afterVal = [char]$after[$valIdx]
$sameSize = ($after.Length -eq $bytes.Length)
Say ("wrote   : size=" + $after.Length + " (size unchanged=" + $sameSize + ")")
Say ("check   : " + $Field + "=`"$afterVal`"")
if ($afterVal -ne $want) { Say 'ERROR: verify failed after write!'; exit 5 }
if (-not $sameSize) { Say 'ERROR: the file size changed -- that should be impossible for a 1-byte edit'; exit 5 }

# ---- make sure nothing else moved (diff by byte, ignoring the one we meant to change) ----
$before = [System.IO.File]::ReadAllBytes($bak)
$diff = 0
for ($i = 0; $i -lt $before.Length; $i++) { if ($before[$i] -ne $after[$i]) { $diff++ } }
Say ("diff    : " + $diff + " byte(s) changed (expect exactly 1)")
if ($diff -ne 1) { Say 'ERROR: more than the intended byte changed!'; exit 5 }

Say ''
Say 'NEXT STEPS:'
Say ("  1) start that install's client: " + (Join-Path $binDir 'XtItClient.exe'))
Say ("     (a full client restart is what applies " + $Field + "=" + $want + ")")
Say '  2) after it is up, confirm with:'
Say ("     qmt-register-check.ps1 -Account " + $Account + "    -> expect exit 0")
if ($Field -eq 'startupAutorun') {
    if ($want -eq '1') { Say '  3) then verify the strategy really runs: the formula log must go fresh' }
} else {
    Say ("  3) then verify the strategy really runs: the " + $Field + " change alone is a")
    Say '     HYPOTHESIS until the formula log goes fresh AND the bridge probe answers'
    if ($want -eq '1') { Say '     READY.  If the log stays stale, revert this byte (backup above).' }
}
exit 0
