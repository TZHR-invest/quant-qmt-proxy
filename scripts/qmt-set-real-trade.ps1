<#
  qmt-set-real-trade.ps1 -- flip a model-trading strategy item to REAL trading
  (runMode="1") at the byte level, for any of the three QMT installs.

  WHY THIS EXISTS (2026-09-28)
  ---------------------------
  A strategy registered while the client was in SIMULATION gets
  `runMode="0"` in `<install>\config\indexUserConfig.xml`.  In real trading the
  bridge strategy MUST run in real mode: with simulation, `passorder()` is filled
  internally -- the order never reaches the broker and the order query never
  shows it (documented trap, AGENTS.md trade-pc section (2)).  Measured today:
  666 = runMode="1", 020 = runMode="1", the new 2986 install = runMode="0"
  (everything else in the item -- account, m_strAccountKey, startupAutorun,
  TradeTypeSet -- already matched).

  HOW IT STAYS SAFE
  -----------------
  * refuses while the client is running: QMT rewrites indexUserConfig.xml on
    exit, so an edit made underneath a live client is silently reverted;
  * requires the ASCII anchor `runMode="0"` to appear EXACTLY ONCE in the whole
    file (one item per install -- verified for all three today); zero or two
    matches => refuse, no write;
  * writes a timestamped backup first, then verifies the byte-level diff is
    exactly ONE byte (the "0" -> "1");
  * `-Mode status` only reads -- use it any time, including on a live client.

  USAGE (from ai-agent: bash scripts/qmt-psh.sh scripts/qmt-set-real-trade.ps1 -Account 2986 -Mode status)
    -Account  666 | 020 | 2986        (or any install dir via -InstallDir)
    -Mode     status | on | off       (default: status)
    -Value    override the target value (0/1) if the semantics ever differ

  EXIT CODES
    0 = done (status printed, or the edit verified)
    2 = bad invocation / unknown account / file missing
    3 = refused: client is running (for on/off)
    4 = refused: anchor not found exactly once
    5 = post-check failed (diff was not exactly one byte)
#>
param(
    [string]$Account = '2986',
    [ValidateSet('status', 'on', 'off')]
    [string]$Mode = 'status',
    [string]$InstallDir = '',
    [string]$Value = '',
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$K = "$env:SystemRoot\System32"
function Say($m) { Write-Output $m }

# install dir per account alias (the three production installs)
$dirs = @{
    '666'  = 'G:\qmt1'
    '020'  = 'G:\qmt'
    '2986' = 'G:\qmt2'
}
if ($InstallDir -ne '') { $dir = $InstallDir } else { $dir = $dirs[$Account] }
if (-not $dir) { Say "ERROR: unknown account '$Account' (use 666|020|2986 or -InstallDir)"; exit 2 }
$cfg = Join-Path $dir 'config\indexUserConfig.xml'
if (-not (Test-Path -LiteralPath $cfg)) { Say "ERROR: not found: $cfg"; exit 2 }

function Get-Anchor($text) {
    # count occurrences of both spellings; the file is ASCII for these tokens
    $zero = ([regex]::Matches($text, 'runMode="0"')).Count
    $one  = ([regex]::Matches($text, 'runMode="1"')).Count
    return @{ zero = $zero; one = $one }
}

$raw = [System.IO.File]::ReadAllText($cfg)
$a = Get-Anchor $raw
Say "install : $dir"
Say "file    : $cfg"
Say ('now     : runMode="0" x{0}   runMode="1" x{1}' -f $a.zero, $a.one)

if ($Mode -eq 'status') {
    if ($a.one -eq 1 -and $a.zero -eq 0)     { Say 'VERDICT REAL-TRADING (runMode=1)' }
    elseif ($a.zero -eq 1 -and $a.one -eq 0) { Say 'VERDICT SIMULATION (runMode=0) -- real orders would stay internal' }
    else                                     { Say 'VERDICT UNCLEAR (unexpected anchor counts)' }
    exit 0
}

$target = if ($Value -ne '') { $Value } elseif ($Mode -eq 'on') { '1' } else { '0' }
$from   = if ($target -eq '1') { '0' } else { '1' }
$anchor = 'runMode="' + $from + '"'
$repl   = 'runMode="' + $target + '"'

if ($target -eq $from) { Say 'ERROR: -Value equals -Mode target'; exit 2 }

# 1) refuse under a live client (it would rewrite the file on exit)
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'XtItClient.exe'" |
           Where-Object { $_.ExecutablePath -like "$dir\*" })
if ($procs.Count -gt 0) {
    Say ("REFUSING: this install's client is running (pid " + (($procs | ForEach-Object { $_.ProcessId }) -join ',') + ")")
    Say '           stop it first -- QMT rewrites indexUserConfig.xml on exit.'
    exit 3
}

# 2) require the anchor exactly once
$n = ([regex]::Matches($raw, [regex]::Escape($anchor))).Count
if ($n -ne 1) { Say "REFUSING: anchor $anchor occurs $n times (need exactly 1)"; exit 4 }

$new = $raw.Replace($anchor, $repl)
$diff = 0
for ($i = 0; $i -lt [Math]::Min($raw.Length, $new.Length); $i++) { if ($raw[$i] -ne $new[$i]) { $diff++ } }
if ($diff -ne 1) { Say "REFUSING: computed diff is $diff bytes (expected exactly 1)"; exit 5 }

Say ("change  : {0}  ->  {1}   (diff {2} byte)" -f $anchor, $repl, $diff)
if ($DryRun) { Say 'DRYRUN: no write'; exit 0 }

$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$bak = "$cfg.bak-runmode-$stamp"
Copy-Item -LiteralPath $cfg -Destination $bak
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cfg, $new, $enc)

# 3) read back and re-verify
$after = [System.IO.File]::ReadAllText($cfg)
$b = Get-Anchor $after
Say ('after   : runMode="0" x{0}   runMode="1" x{1}   (backup {2})' -f $b.zero, $b.one, (Split-Path $bak -Leaf))
if ($target -eq '1' -and -not ($b.one -eq 1 -and $b.zero -eq 0)) { Say 'ERROR: post-check failed'; exit 5 }
if ($target -eq '0' -and -not ($b.zero -eq 1 -and $b.one -eq 0)) { Say 'ERROR: post-check failed'; exit 5 }
Say 'OK: runMode set and verified'
exit 0
