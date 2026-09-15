<#
  qmt-order-methods.ps1 -- flip the big-QMT bridge order-method allow-list.

  WHY THIS IS A SCRIPT AND WHY THE RESTART IS NOT OPTIONAL
  --------------------------------------------------------
  bigqmt_signal_trader_redis_rpc_runtime.py reads rpc_allow_order_methods:
    * line 258 -- at MODULE IMPORT time
    * line 412 -- inside configure_runtime_redis()
  and configure_runtime_redis() has exactly ONE caller in the whole tree:
  the strategy script itself (BIGQMT_REDIS_DRYRUN.py:317), at startup.
  There is no RPC method that reaches it, so editing the config changes
  NOTHING until the strategy is stopped and started again.  The probe below
  shows that contrast for real: config=True while live=False means exactly
  "you still have to restart the strategy".

  It also flips a second, easy-to-miss thing: RPC_PROCESS_IN_LISTENER is
  computed as `... and not RPC_ALLOW_ORDER_METHODS` (line 262 / 415-416), so
  turning orders ON also turns process_in_listener OFF and that combination is
  what gets pushed to the strategy side by _apply_config().

  SAFETY
  ------
  The config is LF + no BOM.  We rewrite the single line in place after taking
  a timestamped backup, and refuse to write if the pattern does not match
  exactly once.  Nothing here touches QMT itself.

  USAGE
  -----
    qmt-order-methods.ps1 -Account 666 -Mode status   # default, read-only
    qmt-order-methods.ps1 -Account 666 -Mode on
    qmt-order-methods.ps1 -Account 666 -Mode off
#>
param(
    [ValidateSet('666', '020')] [string]$Account = '666',
    [ValidateSet('status', 'on', 'off')] [string]$Mode = 'status',
    [string]$ConfigPath = '',
    [switch]$SkipProbe
)
$ErrorActionPreference = 'Stop'

function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }

$cfgMap = @{
    '666' = 'G:\qmt1\python\bigqmt_signal_trader_local_config.py'
    '020' = 'G:\qmt\python\bigqmt_signal_trader_local_config.py'
}
$acctMap = @{
    '666' = '666810082889'
    '020' = '020100053835'
}
$cfg = $cfgMap[$Account]
# -ConfigPath exists so the write path can be rehearsed on a throwaway copy
# (with -SkipProbe) instead of the live config -- a rehearsal that flips the
# real file is not a rehearsal.
if ($ConfigPath -ne '') { $cfg = $ConfigPath }
$acct = $acctMap[$Account]
$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$python = "$proxyDir\.venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $cfg)) { Say "ERROR: config not found: $cfg"; exit 2 }

$md5 = [System.Security.Cryptography.MD5]::Create()
function Md5Bytes([byte[]]$b) { return (($md5.ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '') }
function Md5Text([string]$s) { return (Md5Bytes ([System.Text.Encoding]::UTF8.GetBytes($s))) }
function ReadValue([string]$t) {
    $m = [regex]::Match($t, '"rpc_allow_order_methods"\s*:\s*(\w+)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

$bytes = [System.IO.File]::ReadAllBytes($cfg)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
$cur = ReadValue $text

Say "account : $Account / $acct"
Say "config  : $cfg"
$hasCrlf = $text.Contains("`r`n")
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Say "shape   : CRLF=$hasCrlf BOM=$hasBom bytes=$($bytes.Length) md5=$(Md5Bytes $bytes)"
if ($null -eq $cur) { Say 'ERROR: rpc_allow_order_methods not found -- refusing to guess'; exit 3 }
Say "config  : rpc_allow_order_methods = $cur"

# ---- live state (what the running strategy actually answers) ----------------
if (-not $SkipProbe) {
    if (Test-Path -LiteralPath "$proxyDir\scripts\bridge_rpc_probe.py") {
        $probe = & $python "$proxyDir\scripts\bridge_rpc_probe.py" $acct 2>&1 | Out-String
        Say ("live    : " + $probe.Trim())
        if ($probe -match 'allow_order_methods=(\w+)') {
            $live = $Matches[1]
            if ($live -ne $cur) {
                Say "MISMATCH: config=$cur but running strategy=$live  --> restart the strategy for the change to apply"
            } else {
                Say "in sync : config and running strategy agree ($cur)"
            }
        }
    } else {
        Say "live    : (probe not found, skipped)"
    }
}

if ($Mode -eq 'status') { Say 'STATUS ONLY -- nothing was changed'; exit 0 }

$want = if ($Mode -eq 'on') { 'True' } else { 'False' }
if ($cur -eq $want) { Say "ALREADY $want -- nothing to do"; exit 0 }

# ---- flip the single line ---------------------------------------------------
$pattern = '("rpc_allow_order_methods"\s*:\s*)\w+'
$matches = [regex]::Matches($text, $pattern)
if ($matches.Count -ne 1) {
    Say "ERROR: pattern matched $($matches.Count) times (expected exactly 1) -- refusing to write"
    exit 4
}
$new = [regex]::Replace($text, $pattern, ('${1}' + $want))

$bak = "$cfg.bak-perm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $cfg -Destination $bak -Force
Say "backup  : $bak"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cfg, $new, $utf8NoBom)

$after = [System.IO.File]::ReadAllBytes($cfg)
$afterText = [System.Text.Encoding]::UTF8.GetString($after)
Say "wrote   : bytes=$($after.Length) md5=$(Md5Bytes $after)"
Say "check   : rpc_allow_order_methods = $(ReadValue $afterText)"
if ((ReadValue $afterText) -ne $want) { Say 'ERROR: verify failed after write!'; exit 5 }

Say ''
Say 'NEXT STEPS (in this order -- the config alone changes nothing):'
Say '  1) restart the strategy: QMT -> the strategy list, stop it, then start it'
Say '     (a full XtItClient restart works too, but a strategy restart is enough)'
Say '  2) confirm it took effect WITHOUT placing any order:'
Say "     $python $proxyDir\scripts\bridge_rpc_probe.py $acct"
Say "     -> expect allow_order_methods=$want"
Say '  3) with orders ON, process_in_listener must also flip to False in the'
Say '     startup log ([bigqmt_rpc] transport=redis mode process_in_listener=...)'
exit 0
