<#
  qmt-load-clipboard.ps1 -- put the bridge strategy SOURCE on the clipboard, verified.

  WHY THIS EXISTS (2026-09-15)
  ---------------------------
  Registering BIGQMT_BRIDGE for the 020 install goes through the in-QMT strategy
  editor (migration doc section 56): open it, set the name, tick "encrypt", paste
  the source, close (= save).  The paste half is what this script prepares, and it
  is worth a script for two reasons:

    * the value that ends up on the clipboard IS the strategy code -- if it is
      truncated or mangled, the registered strategy is silently wrong;
    * so this script READS IT BACK and compares, instead of trusting Set-Clipboard.

  The source is `python\BIGQMT_REDIS_DRYRUN.py` (16479 B, 385 lines, pure ASCII --
  measured 2026-09-15: 0 non-ASCII lines, so no GBK/UTF-8 hazard on the paste path).
  It is the bridge ENTRY: it loads the bridge package from dirname(__file__), which
  is why it must live beside bigqmt_signal_trader* in the same python dir.

  USAGE
    qmt-load-clipboard.ps1 -Account 020                 # load + verify
    qmt-load-clipboard.ps1 -Account 020 -CheckOnly      # do not touch the clipboard
    qmt-load-clipboard.ps1 -Account 020 -SourceFile G:\qmt\python\other.py

  THEN (in the editor): click the code area, Ctrl+A, Ctrl+V.

  EXIT CODES
    0 ok (clipboard verified, or -CheckOnly passed)
    2 bad invocation
    3 source file not found
    4 the clipboard did not round-trip byte-for-byte -- do NOT paste, read the diff
    5 the source is not pure ASCII (the paste path is no longer guaranteed safe)
#>
param(
    [ValidateSet('666', '020')] [string]$Account = '020',
    [string]$SourceFile = '',
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'

$instMap = @{
    '666' = @{ Dir = 'G:\qmt1'; Acct = '666810082889' }
    '020' = @{ Dir = 'G:\qmt';  Acct = '020100053835' }
}
$root = $instMap[$Account].Dir
$acct = $instMap[$Account].Acct
$src = if ($SourceFile -ne '') { $SourceFile } else { Join-Path $root 'python\BIGQMT_REDIS_DRYRUN.py' }

function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
function Md5Bytes([byte[]]$b) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    return (($md5.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '')
}

Say ("account : $Account / $acct")
Say ("source  : $src")
if (-not (Test-Path -LiteralPath $src)) { Say "ERROR: source not found: $src"; exit 3 }

$bytes = [System.IO.File]::ReadAllBytes($src)
$text = [System.Text.Encoding]::ASCII.GetString($bytes)
$fileMd5 = Md5Bytes $bytes
Say ("file    : " + $bytes.Length + " bytes, " + (($text -split "`n").Count) + " lines, md5=" + $fileMd5)

# ASCII-only check: the whole point is that the clipboard path cannot corrupt it.
$nonAscii = 0
foreach ($b in $bytes) { if ($b -gt 126 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) { $nonAscii++ } }
Say ("ascii   : " + $nonAscii + " non-ASCII/control byte(s)")
if ($nonAscii -gt 0) {
    Say 'ERROR: the source is not pure ASCII -- the paste path is no longer guaranteed safe.'
    Say '       Inspect before pasting (a GBK/UTF-8 mismatch would corrupt the strategy).'
    exit 5
}

if ($CheckOnly) {
    Say 'CHECK ONLY -- the clipboard was not touched'
    Say 'RESULT: source looks paste-safe'
    exit 0
}

Set-Clipboard -Value $text
Start-Sleep -Milliseconds 300
$back = Get-Clipboard -Raw
$backBytes = [System.Text.Encoding]::ASCII.GetBytes($back)
$backMd5 = Md5Bytes $backBytes
Say ("clipboard: " + $backBytes.Length + " bytes, md5=" + $backMd5)

if ($backMd5 -ne $fileMd5) {
    Say 'ERROR: the clipboard did NOT round-trip byte-for-byte.'
    Say ("       file=" + $fileMd5 + "  clipboard=" + $backMd5 + "  (len " + $bytes.Length + " vs " + $backBytes.Length + ")")
    Say '       Do NOT paste.  Likely a line-ending normalisation on the clipboard path.'
    exit 4
}

Say 'RESULT: clipboard holds the source, verified byte-for-byte'
Say ''
Say 'NEXT (in the QMT strategy editor): click the code area -> Ctrl+A -> Ctrl+V -> close to save'
exit 0
