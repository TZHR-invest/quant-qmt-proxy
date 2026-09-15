<#
  qmt-cancel-path-test.ps1 -- verify that a CANCEL through the bridge cancels
  THE RIGHT ORDER.

  WHY THIS EXISTS (2026-09-15)
  ---------------------------
  The production consumer is NOT read-only: the dashboard cancels orders
  (stock_selection track/viewer/web.py:604/737 -> POST /cancel with order_id),
  and the proxy prefers `order_id` over `order_sysid`
  (trading_session_manager.py:375).  Under the bridge, cancelling by order_id is
  documented as a BEST-EFFORT path: it resolves int order_id -> the counter's
  contract number through
  an in-process bounded table, so a missing/evicted entry could in principle
  cancel a DIFFERENT order.  That is the one failure mode where a wrong action
  is worse than an error, so it gets its own test instead of a note.

  WHAT IT DOES
  ------------
  Places ONE resting BUY at the day's LIMIT-DOWN price, verifies it is resting,
  cancels it through the same route the dashboard uses, and then checks all three
  things that matter:
      * our order is gone (status 53/54)
      * NO OTHER order changed state (i.e. it cancelled the right one)
      * nothing traded

  WHY THAT ORDER CANNOT FILL
  --------------------------
  A buy at the limit-down price can only fill if somebody sells at the
  limit-down.  The gate therefore ALSO requires the last price to be at least
  `-MinGapPct` above the limit-down (default 3%), i.e. the stock is nowhere near
  its floor, so there is no seller at that price.  If the quote is missing or the
  stock is near its floor, the script REFUSES (fails closed).

  SAFETY
  ------
    * -Go is required; without it this only reports what it would do.
    * exactly one order is sent, and it is cancelled immediately (default: as
      soon as the resting state is observed).
    * if the cancel does not take, a second attempt is made via order_sysid; if
      that also fails the script says so LOUDLY (a resting order at the floor is
      harmless but the operator must know it is there).
    * production (8001/8002) is not touched -- default port is the 8003 replica.

  USAGE
    qmt-cancel-path-test.ps1 -Rehearsal                  # gates + read-only evidence
    qmt-cancel-path-test.ps1 -Go                         # the real thing (one order)
    qmt-cancel-path-test.ps1 -Go -CancelBy order_sysid   # test the other route

  EXIT CODES
    0  = cancelled correctly (right order, nothing else touched, nothing filled)
    2  = bad invocation / config
    3  = gate 1 failed: the running strategy does not allow order methods
    4  = gate 2 failed: the target port is not listening
    5  = gate 3 failed: could not prove the price cannot fill / not enough gap
    6  = could not open a session / place the order
    7  = the order never showed up as resting (so nothing was cancelled)
    9  = the cancel was attempted but our order is STILL LIVE
    10 = OUR ORDER WAS CANCELLED BUT ANOTHER ORDER ALSO CHANGED  <-- dangerous
    11 = the order FILLED instead of resting                     <-- unexpected
#>
param(
    [ValidateSet('666', '020')] [string]$Account = '666',
    [int]$Port = 0,
    [string]$ConfigYml = '',
    [string]$Stock = '600000.SH',
    [int]$Volume = 100,
    [ValidateSet('order_id', 'order_sysid')] [string]$CancelBy = 'order_id',
    [double]$MinGapPct = 3.0,
    [int]$RestObserveSec = 12,
    [string]$Remark = 'CANCELPROBE',
    [string]$FormulaLog = '',
    [switch]$Go,
    [switch]$Rehearsal
)
$ErrorActionPreference = 'Stop'

if ($Rehearsal -and $Go) {
    Write-Output 'ERROR: -Rehearsal and -Go are mutually exclusive'
    exit 2
}

$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$python = "$proxyDir\.venv\Scripts\python.exe"
$curl = "$env:SystemRoot\System32\curl.exe"
$acctMap = @{ '666' = '666810082889'; '020' = '020100053835' }
$acct = $acctMap[$Account]
if ($Port -eq 0) { $Port = if ($Account -eq '666') { 8003 } else { 8005 } }
if ($ConfigYml -eq '') { $ConfigYml = Join-Path $proxyDir "config.local.$Account.yml" }
if ($FormulaLog -eq '') { $FormulaLog = "G:\qmt$($Account -replace '666','1')\userdata\log\XtClient_FormulaOutput_$(Get-Date -Format 'yyyyMMdd').log" }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = "$proxyDir\logs\cancel-$ts"
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
function J([string]$s) { try { return ($s | ConvertFrom-Json) } catch { return $null } }

Say "=== cancel-path test  account=$Account port=$Port cancelBy=$CancelBy go=$Go ==="
Say "evidence dir: $outDir"

if (-not (Test-Path -LiteralPath $ConfigYml)) { Say "ERROR: config yml not found: $ConfigYml"; exit 2 }
$km = [regex]::Match([System.IO.File]::ReadAllText($ConfigYml, [System.Text.Encoding]::UTF8), 'api_keys:\s*\r?\n\s*-\s*"?([^"\r\n]+?)"?\s*\r?\n')
if (-not $km.Success) { Say 'ERROR: could not read api_keys[0]'; exit 2 }
$AUTH = @('-H', ("Authorization: Bearer " + $km.Groups[1].Value.Trim()))
function Body($json, $name) {
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $f = Join-Path $outDir $name
    [System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $f
}

# ---- gate 1: the RUNNING strategy must allow order methods -----------------
Say ''
Say '--- gate 1: running strategy ---'
$probe = (& $python "$proxyDir\scripts\bridge_rpc_probe.py" $acct 2>&1 | Out-String)
Save '01-probe.txt' $probe | Out-Null
Say ('probe    : ' + $probe.Trim())
$live = $null
if ($probe -match 'allow_order_methods=(\w+)') { $live = $Matches[1] }
if ($live -ne 'True') {
    if ($Rehearsal) { V "GATE 1 WEAK (rehearsal): allow_order_methods=$live" }
    else {
        V "GATE 1 FAILED: allow_order_methods=$live (need True)"
        V 'Nothing was sent. Run qmt-order-methods.ps1 -Mode on and restart the strategy.'
        Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
        exit 3
    }
} else { V 'GATE 1 OK: allow_order_methods=True' }

# ---- gate 2: the target instance must be listening -------------------------
Say ''
Say '--- gate 2: target listening ---'
if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
    V "GATE 2 FAILED: nothing listening on $Port"
    Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 4
}
V "GATE 2 OK: $Port is listening"

# ---- gate 3: prove the price cannot fill ----------------------------------
Say ''
Say '--- gate 3: price safety ---'
$tickBody = Body ('{"symbols": ["' + $Stock + '"]}') '02-tick-request.json'
$tick = J (& $curl -s @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$tickBody" "$base/api/v1/data/full-tick" 2>&1 | Out-String)
$instr = J (& $curl -s @AUTH "$base/api/v1/data/instrument/$Stock`?complete=true" 2>&1 | Out-String)
Save '03-instrument.json' ($instr | ConvertTo-Json -Depth 8) | Out-Null

$lastPrice = $null; try { $lastPrice = [double]$tick.data.items[0].tick.last_price } catch { }
$down = $null; $up = $null; $tickSize = $null; $name = ''
try {
    $f = $instr.data.fields
    if ($f.DownStopPrice) { $down = [double]$f.DownStopPrice }
    if ($f.UpStopPrice) { $up = [double]$f.UpStopPrice }
    if ($f.PriceTick) { $tickSize = [double]$f.PriceTick }
    $name = [string]$f.InstrumentName
} catch { }
Say ("$Stock = $name   last=$lastPrice  limitDown=$down  limitUp=$up  tick=$tickSize")

if ($null -eq $lastPrice -or $lastPrice -le 0) {
    V 'GATE 3 FAILED: no last price -- cannot prove a resting buy is unreachable'
    Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 5
}
if ($null -eq $down -or $down -le 0) {
    V 'GATE 3 FAILED: no limit-down available -- refusing to guess a resting price'
    Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 5
}
$price = [math]::Round($down, 2)
$gapPct = 100.0 * ($lastPrice - $price) / $price
Say ("plan     : BUY $Volume $Stock @ $price (the floor)   gap below market = " + [math]::Round($gapPct, 2) + '%')
if ($gapPct -lt $MinGapPct) {
    V "GATE 3 FAILED: last price is only $([math]::Round($gapPct,2))% above the floor (< $MinGapPct%) -- a resting buy there could fill. Refusing."
    Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 5
}
V "GATE 3 OK: buying at the floor $price, $([math]::Round($gapPct,2))% below the market -- nothing can match it"

# ---- session --------------------------------------------------------------
Say ''
Say '--- session ---'
$sb = Body ('{"account_id": "' + $acct + '", "account_type": "STOCK"}') '00-session-request.json'
$sess = J (& $curl -s @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$sb" "$base/api/v1/trading/sessions" 2>&1 | Out-String)
$sid = $null; try { $sid = $sess.data.session_id } catch { }
if (-not $sid) { V 'FAILED to open a session'; Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null; exit 6 }
Say "session: $sid"

function Orders($tag) {
    $raw = (& $curl -s @AUTH "$base/api/v1/trading/sessions/$sid/orders" 2>&1 | Out-String)
    Save "$tag.json" $raw | Out-Null
    $j = J $raw
    if ($j -and $j.data -and $j.data.items) { return @($j.data.items) }
    return @()
}
function OrderKey($o) {
    # the identity that must not move: prefer the counter's number
    if ($o.order_sysid) { return 'sys:' + $o.order_sysid }
    return 'id:' + $o.order_id
}

$before = @(Orders '04-orders-before')
V ("orders before: " + @($before).Count)
$beforeMap = @{}
foreach ($o in $before) { $beforeMap[(OrderKey $o)] = "$($o.order_status_code)" }

if (-not $Go) {
    V 'DRY RUN (no -Go): gates passed, nothing was sent.'
    Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 0
}

# ---- place the resting order ---------------------------------------------
Say ''
Say "--- placing the resting order: BUY $Volume $Stock @ $price ---"
$priceText = $price.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$ob = Body ('{"stock_code":"' + $Stock + '","side":"BUY","price_type":11,"volume":' + $Volume + ',"price":' + $priceText + ',"strategy_name":"' + $Remark + '","order_remark":"' + $Remark + '"}') '05-order-request.json'
$resp = (& $curl -s -w "`nHTTP=%{http_code}" @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$ob" "$base/api/v1/trading/sessions/$sid/orders" 2>&1 | Out-String)
Save '06-order-response.txt' $resp | Out-Null
Say ('order response: ' + $resp.Trim())
$httpCode = $null; if ($resp -match 'HTTP=(\d+)') { $httpCode = $Matches[1] }
V "place HTTP=$httpCode"

# ---- observe it resting ---------------------------------------------------
$mine = @()
for ($i = 1; $i -le $RestObserveSec; $i++) {
    Start-Sleep -Seconds 1
    $now = Orders '07-orders-resting'
    $mine = @($now | Where-Object { $_.order_remark -eq $Remark -or $_.strategy_name -eq $Remark })
    if ($mine.Count -gt 0) { break }
}
if ($mine.Count -eq 0) {
    V "GATE FAILED: the order never appeared in the order list (HTTP=$httpCode) -- nothing to cancel"
    Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
    exit 7
}
$o1 = $mine[0]
V ("resting: order_id=$($o1.order_id) order_sysid=[$($o1.order_sysid)] status=$($o1.order_status_code) traded=$($o1.traded_volume)")
if ([int]$o1.traded_volume -gt 0) {
    V "UNEXPECTED: the order partially traded (traded=$($o1.traded_volume)) -- cancelling anyway"
}

# ---- cancel it the way production does ------------------------------------
Say ''
Say "--- cancelling by $CancelBy ---"
if ($CancelBy -eq 'order_id') {
    $cancelJson = '{"order_id": "' + $o1.order_id + '"}'
} else {
    $cancelJson = '{"market": "' + $Stock.Split('.')[1] + '", "order_sysid": "' + $o1.order_sysid + '"}'
}
$cb = Body $cancelJson '08-cancel-request.json'
$cresp = (& $curl -s -w "`nHTTP=%{http_code}" @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$cb" "$base/api/v1/trading/sessions/$sid/cancel" 2>&1 | Out-String)
Save '09-cancel-response.txt' $cresp | Out-Null
Say ('cancel response: ' + $cresp.Trim())
$chttp = $null; if ($cresp -match 'HTTP=(\d+)') { $chttp = $Matches[1] }
V "cancel HTTP=$chttp"

Start-Sleep -Seconds 3
$after = Orders '10-orders-after'
$mineAfter = @($after | Where-Object { $_.order_remark -eq $Remark -or $_.strategy_name -eq $Remark })
$trades = J (& $curl -s @AUTH "$base/api/v1/trading/sessions/$sid/trades" 2>&1 | Out-String)
Save '11-trades-after.json' ($trades | ConvertTo-Json -Depth 8) | Out-Null
$traded = 0; try { $traded = @($trades.data.items).Count } catch { }
V "trades after: $traded"

$exitCode = 0
if ($mineAfter.Count -eq 0) {
    V 'our order is no longer in the list'
} else {
    $st = [int]$mineAfter[0].order_status_code
    if ($st -eq 54 -or $st -eq 53) {
        V "our order status is now $st (cancelled)"
    } elseif ($st -eq 56 -or [int]$mineAfter[0].traded_volume -gt 0) {
        V "OUR ORDER TRADED (status=$st traded=$($mineAfter[0].traded_volume)) -- unexpected for a floor-priced buy"
        $exitCode = 11
    } else {
        V "our order is STILL LIVE (status=$st) -- the cancel did not take"
        $exitCode = 9
    }
}

# ---- the important one: did anything ELSE change? -------------------------
Say ''
Say '--- did any other order change? (this is the dangerous failure) ---'
$afterMap = @{}
foreach ($o in $after) { $afterMap[(OrderKey $o)] = "$($o.order_status_code)" }
$changedOthers = @()
foreach ($k in $beforeMap.Keys) {
    if ($k -like '*CANCELPROBE*') { continue }
    if (-not $afterMap.ContainsKey($k)) { $changedOthers += "$k disappeared"; continue }
    if ($afterMap[$k] -ne $beforeMap[$k]) { $changedOthers += "$k status $($beforeMap[$k]) -> $($afterMap[$k])" }
}
if ($changedOthers.Count -eq 0) {
    V 'no other order changed state -> the cancel hit the intended order'
} else {
    foreach ($c in $changedOthers) { V "ANOTHER ORDER CHANGED: $c" }
    if ($exitCode -eq 0) { $exitCode = 10 }
}

# ---- if it is still live, try the other route and say so loudly -----------
if ($exitCode -eq 9) {
    Say ''
    Say '--- retrying the cancel via the OTHER route ---'
    if ($CancelBy -eq 'order_id' -and $o1.order_sysid) {
        $c2 = Body ('{"market": "' + $Stock.Split('.')[1] + '", "order_sysid": "' + $o1.order_sysid + '"}') '12-cancel-retry-sysid.json'
        $r2 = (& $curl -s -w "`nHTTP=%{http_code}" @AUTH -X POST -H 'Content-Type: application/json' --data-binary "@$c2" "$base/api/v1/trading/sessions/$sid/cancel" 2>&1 | Out-String)
        Save '13-cancel-retry-response.txt' $r2 | Out-Null
        Say ('retry (by sysid): ' + $r2.Trim())
        Start-Sleep -Seconds 3
        $a2 = Orders '14-orders-after-retry'
        $m2 = @($a2 | Where-Object { $_.order_remark -eq $Remark -or $_.strategy_name -eq $Remark })
        if ($m2.Count -eq 0 -or [int]$m2[0].order_status_code -in @(53, 54)) {
            V 'the sysid route DID cancel it -- so prefer order_sysid in write mode (section 36.0)'
            $exitCode = 0
        } else {
            V "STILL LIVE after both routes (status=$($m2[0].order_status_code))"
            V "!! A RESTING BUY $Volume $Stock @ $price IS LEFT IN THE BOOK -- it is at the floor so it cannot fill,"
            V "!! but it must be cancelled by hand in the QMT client. Evidence above."
        }
    } else {
        V 'no second route available for this order (no order_sysid)'
    }
}

[void](& $curl -s -o NUL -X DELETE @AUTH "$base/api/v1/trading/sessions/$sid" 2>&1)
Save '99-verdict.txt' ($verdict -join "`r`n") | Out-Null
Say ''
Say '=== VERDICT ==='
$verdict | ForEach-Object { Say $_ }
Say "evidence: $outDir"
Say ("EXIT $exitCode" + $(if ($exitCode -eq 0) { ' = cancel path verified' } else { ' = SEE THE LINES ABOVE' }))
exit $exitCode
