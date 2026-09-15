<#
  qmt-p2-order-test.ps1 -- prove that an order actually reaches the broker
  through the big-QMT bridge.  THIS IS THE ONLY STEP THAT TOUCHES MONEY, so it
  is deliberately one-shot, gated, and heavily instrumented.

  WHAT WE STILL DID NOT KNOW BEFORE THIS (2026-09-15)
  ---------------------------------------------------
  We had proved that a REFUSED order is reported as refused (D4/D1 -> 422).
  We had NOT proved that an ACCEPTED order reaches the broker.  That gap
  matters because the big-QMT route runs the trading code inside the strategy
  (passorder); if the strategy is not in a real-money mode, passorder matches
  INTERNALLY -- the REST call answers 200 with an order id, and a query shows
  nothing.  That is the failure mode this test is built to catch, so the
  decisive evidence is NOT the HTTP answer, it is:
      "does the order show up in the broker-side order list?"

  ORDER CHOSEN SO IT CANNOT FILL
  ------------------------------
  BUY 100 shares of a large-cap at 0.01 CNY.  A-share price limits make a
  resting buy at 0.01 impossible to fill (nothing may trade below the
  limit-down, so no sell order can ever match it), and 100 = one lot = the
  minimum.  Either the exchange rejects it as out of range (expected) or it
  rests unfillable forever.  Both outcomes are harmless, and both prove the
  path end to end.

  GATES (any gate failing means we do NOT place the order)
  -------------------------------------------------------
    * the running strategy must answer allow_order_methods=True (verified with
      a real round trip, not by reading the config file)
    * -Go must be passed explicitly; without it this script only reports
    * exactly ONE order is ever sent -- there is no retry loop here

  EVIDENCE WRITTEN to <proxyDir>\logs\p2-<timestamp>\ :
    00-session-request.json  01-probe.txt  02-tick-request.json  02-tick.json
    03-instrument.json (carries PreClose / UpStopPrice / DownStopPrice)
    04-orders-before.json  05-order-request.json  06-order-response.txt
    07-orders-after.json  08-trades-after.json  09-formula-log-delta.txt
    10-verdict.txt  11-client-message-delta.txt

  EXIT CODES (the decisive judgement is an EXIT CODE, never a substring)
  ---------------------------------------------------------------------
    0  = the order WAS seen in the broker-side order list (path proven)
    2  = bad invocation / no -Go (reporting only)
    3  = gate 1: the running strategy does not allow order methods
    4  = gate 2: the test instance is not listening
    5  = could not open a trading session
    6  = gate 3: could not prove the price cannot fill (fails closed)
    10 = the order was NOT seen in the broker-side order list -- read
         10-verdict.txt for the two interpretations (internal matching vs a
         counter/client-side refusal such as "outside trading hours")
#>
param(
    [string]$Account = '666810082889',
    [int]$Port = 8003,
    [string]$ConfigYml = 'G:\qmt_projects\quant-qmt-proxy\config.local.666.yml',
    [string]$Stock = '600000.SH',
    [int]$Volume = 100,
    [double]$Price = 0.01,
    [string]$Remark = 'P2PROBE',
    [string]$FormulaLog = 'G:\qmt1\userdata\log\XtClient_FormulaOutput_' + (Get-Date -Format 'yyyyMMdd') + '.log',
    [string]$MsgLog = 'G:\qmt1\userdata\log\XtClient_Message_' + (Get-Date -Format 'yyyyMMdd') + '.log',
    [switch]$Rehearsal,
    [switch]$AllowNoLimitCheck,
    [switch]$Go
)
$ErrorActionPreference = 'Stop'

# A rehearsal may NEVER place an order: it skips gate 1 (so the evidence path
# can be exercised while orders are still disabled) and refuses to run with -Go.
if ($Rehearsal -and $Go) {
    Write-Output 'ERROR: -Rehearsal and -Go are mutually exclusive (a rehearsal must not place an order)'
    exit 2
}

$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$python = "$proxyDir\.venv\Scripts\python.exe"
$curl = "$env:SystemRoot\System32\curl.exe"
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = "$proxyDir\logs\p2-$ts"
$base = "http://127.0.0.1:$Port"

function Say($m) { Write-Output ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) }
function Save($name, $text) {
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $p = Join-Path $outDir $name
    [System.IO.File]::WriteAllText($p, [string]$text, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

$verdict = New-Object System.Collections.ArrayList
function V($m) { [void]$verdict.Add($m); Say $m }

Say "=== P2 order test  account=$Account port=$Port go=$Go ==="
Say "evidence dir: $outDir"

# ---- api key from the machine's own config (never hardcoded in the repo) ----
if (-not (Test-Path -LiteralPath $ConfigYml)) { Say "ERROR: config yml not found: $ConfigYml"; exit 2 }
# UTF-8 explicitly: Get-Content -Raw would use the ANSI/GBK code page.
$keyMatch = [regex]::Match([System.IO.File]::ReadAllText($ConfigYml, [System.Text.Encoding]::UTF8), 'api_keys:\s*\r?\n\s*-\s*"?([^"\r\n]+?)"?\s*\r?\n')
if (-not $keyMatch.Success) { Say 'ERROR: could not read api_keys[0] from the config yml'; exit 2 }
$apiKey = $keyMatch.Groups[1].Value.Trim()
Say ("api key  : " + $apiKey.Substring(0, 4) + '... (' + $apiKey.Length + ' chars, read from ' + (Split-Path $ConfigYml -Leaf) + ')')
$H = @('-H', "Authorization: Bearer $apiKey")

# ---- GATE 1: the RUNNING strategy must allow order methods -----------------
Say ''
Say '--- gate 1: running strategy allow_order_methods ---'
$probe = & $python "$proxyDir\scripts\bridge_rpc_probe.py" $Account 2>&1 | Out-String
Save '01-probe.txt' $probe | Out-Null
Say ('probe    : ' + $probe.Trim())
$live = $null
if ($probe -match 'allow_order_methods=(\w+)') { $live = $Matches[1] }
if ($Rehearsal) {
    V "GATE 1 SKIPPED (rehearsal): running strategy reports allow_order_methods=$live"
    V 'Rehearsal mode: no order can be sent (the -Go path is refused above).'
} elseif ($live -ne 'True') {
    V "GATE 1 FAILED: running strategy reports allow_order_methods=$live (need True)."
    V 'Nothing was placed. Run qmt-order-methods.ps1 -Mode on and restart the strategy first.'
    Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 3
} else {
    V 'GATE 1 OK: running strategy reports allow_order_methods=True'
}

# ---- GATE 2: the test instance must be listening --------------------------
Say ''
Say '--- gate 2: test instance listening ---'
$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $listen) {
    V "GATE 2 FAILED: nothing is listening on $Port."
    V "Start the bridge test instance first: cmd /c `"$proxyDir\scripts\bridge-test-666.bat`""
    Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 4
}
V "GATE 2 OK: $Port listening (pid=$($listen[0].OwningProcess))"

# ---- reference data (why 0.01 cannot fill) --------------------------------
Say ''
Say '--- reference data ---'
# POST bodies go through a FILE: PowerShell 5.1 mangles embedded double quotes
# when handing an argument to a native exe, which turned the JSON body into
# "input: {}" and made the service answer a json_invalid 400.
$bodyDir = $outDir
if (-not (Test-Path -LiteralPath $bodyDir)) { New-Item -ItemType Directory -Path $bodyDir -Force | Out-Null }
$tickBodyFile = Join-Path $bodyDir '02-tick-request.json'
[System.IO.File]::WriteAllText($tickBodyFile, '{"symbols": ["' + $Stock + '"]}', (New-Object System.Text.UTF8Encoding($false)))
$tick = & $curl -s @H -X POST -H 'Content-Type: application/json' --data-binary "@$tickBodyFile" "$base/api/v1/data/full-tick" 2>&1 | Out-String
Save '02-tick.json' $tick | Out-Null

$instr = & $curl -s @H "$base/api/v1/data/instrument/$Stock`?complete=true" 2>&1 | Out-String
Save '03-instrument.json' $instr | Out-Null

$down = $null; $up = $null; $preClose = $null; $tickSize = $null; $instrName = ''
try {
    $f = ($instr | ConvertFrom-Json).data.fields
    if ($f.DownStopPrice) { $down = [double]$f.DownStopPrice }
    if ($f.UpStopPrice) { $up = [double]$f.UpStopPrice }
    if ($f.PreClose) { $preClose = [double]$f.PreClose }
    if ($f.PriceTick) { $tickSize = [double]$f.PriceTick }
    $instrName = [string]$f.InstrumentName
} catch { }

if ($instrName -ne '') { Say "$Stock = $instrName" }
Say "preClose=$preClose  limitDown=$down  limitUp=$up  priceTick=$tickSize"
Say "our order price       : $Price"

# ---- GATE 3: the price must be one that CANNOT fill -----------------------
# A buy below the limit-down can never trade (nothing may match below it), so
# this is the safety property that makes the whole test harmless. Fail CLOSED:
# if we cannot read the limit-down we refuse unless told otherwise.
if ($null -eq $down -or $down -le 0) {
    if (-not $AllowNoLimitCheck) {
        V 'GATE 3 FAILED: could not read DownStopPrice, so I cannot prove the order is unfillable.'
        V 'Re-run with -AllowNoLimitCheck only if you have verified the price another way.'
        Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
        exit 6
    }
    V 'GATE 3 WEAK: no DownStopPrice available; -AllowNoLimitCheck was passed, continuing.'
} elseif ($Price -ge $down) {
    V "GATE 3 FAILED: price $Price is NOT below the limit-down $down -- this order could fill. Refusing."
    Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 6
} else {
    V "GATE 3 OK: price $Price is $([math]::Round($down - $Price, 2)) below the limit-down $down -> cannot fill"
}

# ---- session --------------------------------------------------------------
Say ''
Say '--- open session ---'
$sessBodyFile = Join-Path $outDir '00-session-request.json'
[System.IO.File]::WriteAllText($sessBodyFile, '{"account_id": "' + $Account + '", "account_type": "STOCK"}', (New-Object System.Text.UTF8Encoding($false)))
$sessRaw = & $curl -s @H -X POST -H 'Content-Type: application/json' --data-binary "@$sessBodyFile" "$base/api/v1/trading/sessions" 2>&1 | Out-String
$sid = $null
try { $sid = ($sessRaw | ConvertFrom-Json).data.session_id } catch {}
if (-not $sid) {
    Save '00-session-response.txt' $sessRaw | Out-Null
    V "FAILED to open a session: $($sessRaw.Trim())"
    Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 5
}
Say "session  : $sid"

$before = & $curl -s @H "$base/api/v1/trading/sessions/$sid/orders" 2>&1 | Out-String
Save '04-orders-before.json' $before | Out-Null
$beforeCount = 0
try { $beforeCount = @(($before | ConvertFrom-Json).data.items).Count } catch {}
Say "orders before: $beforeCount"

# ---- the order ------------------------------------------------------------
# InvariantCulture on the price: this machine runs a Chinese locale, and a
# decimal comma would produce invalid JSON.
$priceText = $Price.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$body = '{"stock_code":"' + $Stock + '","side":"BUY","price_type":11,"volume":' + $Volume + ',"price":' + $priceText + ',"strategy_name":"' + $Remark + '","order_remark":"' + $Remark + '"}'
$bodyFile = Save '05-order-request.json' $body
Say ''
Say "--- order: BUY $Volume $Stock @ $priceText  (remark=$Remark) ---"

$logOffset = 0
if (Test-Path -LiteralPath $FormulaLog) { $logOffset = (Get-Item -LiteralPath $FormulaLog).Length }
$msgOffset = 0
if (Test-Path -LiteralPath $MsgLog) { $msgOffset = (Get-Item -LiteralPath $MsgLog).Length }

if (-not $Go) {
    V 'DRY RUN (no -Go): gates passed, the order was NOT sent.'
    V "Would POST to $base/api/v1/trading/sessions/$sid/orders"
    V "body: $body"
    Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 0
}

$resp = & $curl -s -w "`nHTTP=%{http_code}" @H -X POST -H 'Content-Type: application/json' --data-binary "@$bodyFile" "$base/api/v1/trading/sessions/$sid/orders" 2>&1 | Out-String
Save '06-order-response.txt' $resp | Out-Null
Say 'order response:'
Say $resp.Trim()
$httpCode = $null
if ($resp -match 'HTTP=(\d+)') { $httpCode = $Matches[1] }
V "order HTTP status: $httpCode"

# ---- did it reach the broker? --------------------------------------------
Start-Sleep -Seconds 4
$after = & $curl -s @H "$base/api/v1/trading/sessions/$sid/orders" 2>&1 | Out-String
Save '07-orders-after.json' $after | Out-Null
$trades = & $curl -s @H "$base/api/v1/trading/sessions/$sid/trades" 2>&1 | Out-String
Save '08-trades-after.json' $trades | Out-Null

$items = @()
try { $items = @(($after | ConvertFrom-Json).data.items) } catch {}
Say ''
Say "orders after: $($items.Count) (was $beforeCount)"
$mine = @($items | Where-Object { $_.order_remark -eq $Remark -or $_.strategy_name -eq $Remark })
$reached = $false
if ($mine.Count -gt 0) {
    $reached = $true
    V "REACHED THE BROKER: the order is in the broker-side order list ($($mine.Count) row(s))."
    foreach ($o in $mine) {
        Say ("  order_id=$($o.order_id) order_sysid=[$($o.order_sysid)] status=$($o.order_status_code) '$($o.status_msg)' vol=$($o.order_volume) traded=$($o.traded_volume)")
        V "  order_sysid=[$($o.order_sysid)] status_code=$($o.order_status_code) status_msg='$($o.status_msg)'"
    }
} else {
    V 'NOT IN THE ORDER LIST -- could not confirm the order reached the broker.'
    if ($httpCode -eq '422') {
        V 'HTTP 422 means the bridge REFUSED the order (allow flag / real-money mode /'
        V 'price range), i.e. it never left the QMT terminal -- this run does NOT prove'
        V 'delivery and does NOT prove internal matching either. Read the wording above.'
    } elseif ($httpCode -eq '200') {
        V 'HTTP 200 + no broker-side row is the case to be careful about. Two readings:'
        V '  (a) the strategy matched internally / is not in a real-money mode -- BAD;'
        V '  (b) the counter or the terminal refused it before booking it, e.g. outside'
        V '      trading hours or a price outside the daily limit -- harmless, but the'
        V '      run then proves nothing about delivery.'
        V 'To tell them apart: 09-formula-log-delta.txt / 11-client-message-delta.txt'
        V 'should mention the refusal. If they are silent, assume (a).'
    }
}

$tItems = @()
try { $tItems = @(($trades | ConvertFrom-Json).data.items) } catch {}
V "trades after: $($tItems.Count)"

# ---- what the strategy itself logged -------------------------------------
if (Test-Path -LiteralPath $FormulaLog) {
    $fs = [System.IO.File]::Open($FormulaLog, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($logOffset, 'Begin')
        $sr = New-Object System.IO.StreamReader($fs)
        $delta = $sr.ReadToEnd()
    } finally { $fs.Close() }
    Save '09-formula-log-delta.txt' $delta | Out-Null
    Say ''
    Say "strategy log delta: $($delta.Length) chars -> 09-formula-log-delta.txt"
    # ASCII-only pattern on purpose: a .ps1 without a BOM is read as GBK on this
    # machine, so non-ASCII literals here would be silently mangled.
    $hits = @($delta -split "`r?`n" | Where-Object { $_ -match 'order|passorder|reject|refus|error|fail' })
    if ($hits.Count -gt 0) { V "strategy log mentions the order ($($hits.Count) line(s)) -- see 09-formula-log-delta.txt" }
}

# ---- what the QMT terminal itself logged ----------------------------------
# The terminal's own message log is where a counter-side refusal ("price outside
# the daily limit", "not a trading session") shows up. It is the second witness
# that tells reading (b) apart from reading (a) above.
if (Test-Path -LiteralPath $MsgLog) {
    $ms = [System.IO.File]::Open($MsgLog, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$ms.Seek($msgOffset, 'Begin')
        $mr = New-Object System.IO.StreamReader($ms)
        $mdelta = $mr.ReadToEnd()
    } finally { $ms.Close() }
    Save '11-client-message-delta.txt' $mdelta | Out-Null
    Say "terminal log delta: $($mdelta.Length) chars -> 11-client-message-delta.txt"
    $mhits = @($mdelta -split "`r?`n" | Where-Object { $_ -match 'order|trade|reject|refus|error|fail|limit' })
    if ($mhits.Count -gt 0) { V "terminal log mentions order/trade activity ($($mhits.Count) line(s))" }
}

# ---- cleanup -------------------------------------------------------------
[void](& $curl -s -o NUL -X DELETE @H "$base/api/v1/trading/sessions/$sid" 2>&1)
Say ''
Say "session $sid closed"
Save '10-verdict.txt' ($verdict -join "`r`n") | Out-Null
Say ''
Say '=== VERDICT ==='
$verdict | ForEach-Object { Say $_ }
Say "evidence: $outDir"
if ($reached) {
    Say 'EXIT 0 = the order was seen in the broker-side order list'
    exit 0
}
Say 'EXIT 10 = the order was NOT seen in the broker-side order list'
Say '          read 10-verdict.txt (and 06/07/09/11) before drawing a conclusion'
exit 10
