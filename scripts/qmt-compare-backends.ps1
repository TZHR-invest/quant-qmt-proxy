<#
  qmt-compare-backends.ps1 -- snapshot a proxy backend, then diff two snapshots.

  WHY: the switch is only "verified" if the bridge serves the same numbers the
  miniQMT link served.  Doing that by eye, twice (666 and 020), at the end of a
  trading day is how mistakes get through.  So: capture before, capture after,
  diff mechanically.

  IT IS READ-ONLY.  It opens a trading session, queries, closes the session.
  It never places, changes or cancels anything.

  USAGE
    # before the switch (miniQMT is still answering on 8002)
    qmt-compare-backends.ps1 -Capture mini-before -Port 8002 `
        -Account 666810082889 -ConfigYml config.local.666.yml

    # after switch-proxy-backend.ps1 moved 8002 to the bridge
    qmt-compare-backends.ps1 -Capture bridge-after -Port 8002 `
        -Account 666810082889 -ConfigYml config.local.666.yml

    # diff them (two explicit names: an array parameter would let PowerShell
    # bind the second value to a positional parameter instead)
    qmt-compare-backends.ps1 -CompareA mini-before -CompareB bridge-after

  Snapshots land in <proxyDir>\logs\cmp\ (or -OutDir).  -CompareA/-CompareB
  accept bare labels and resolve them inside that directory.

  WHAT IS EXPECTED TO DIFFER (listed separately so real differences stand out)
    health.backend        mini -> bridge   (this is the point of the switch)
    allow_order_methods   False -> True    (only during the P2 test)
    probe                 the probe line names the allow flag
#>
param(
    [string]$Capture = '',
    [int]$Port = 8002,
    [string]$Account = '666810082889',
    [string]$ConfigYml = 'config.local.666.yml',
    [string]$Symbol = '600000.SH',
    [string]$CompareA = '',
    [string]$CompareB = '',
    [string]$OutDir = '',
    [double]$Tol = 0.005
)
$ErrorActionPreference = 'Stop'

$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$curl = "$env:SystemRoot\System32\curl.exe"
if ($OutDir -eq '') { $OutDir = "$proxyDir\logs\cmp" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not [System.IO.Path]::IsPathRooted($ConfigYml)) { $ConfigYml = Join-Path $proxyDir $ConfigYml }

# NOTE: PowerShell variable names are CASE-INSENSITIVE, so these whitelists
# must not be called $expected/$market -- the accumulators inside
# Diff-Snapshots would silently shadow them with empty arrays and every
# whitelisted field would be reported as a real difference.
#
# Fields introduced by D3/D6 exist only on the patched proxy; a pre-patch
# service (which is what production runs until the switch restarts it) has
# them absent, so they legitimately differ between before/after.
# 2026-09-15: `health.xtquant_mode` was missed in the first version -- it is
# absent from a pre-patch service and present ("prod") afterwards, so a
# before/after compare reported it as a structural difference even though it
# says nothing about which trader is wired up.  Measured, not guessed: the
# production proxy was running 00:19 code at 10:35 while the source was patched
# at 08:59 (migration doc section 46.5).
$WHITELIST = @('health.backend', 'health.xtquant_mode', 'health.status',
              'health.sessions_total', 'health.sessions_real',
              'health.sessions_connected', 'allow_order_methods', 'probe',
              'timestamp', 'label', 'port')

# KNOWN, ACCEPTED cross-backend gaps (migration doc section 35, G1/G2).
# They are REAL differences, so they must not be silently whitelisted away --
# they get their own bucket and the reader still has to confirm the consumer
# does not use them.  Keeping them out of the STRUCTURAL count is what makes the
# exit code mean "no NEW difference", which is the only thing worth gating on:
# gating on a number that is always 22 trains the operator to ignore it
# (measured 2026-09-15 10:43 on account 666810082889: the whole mini<->bridge
# difference set was exactly fetch_balance + secu_account on 21 positions).
$KNOWN_GAPS = @('asset.fetch_balance')
$POSITION_GAPS = @('secu_account')

function Say($m) { Write-Output $m }

# ---------------------------------------------------------------- compare mode
function Resolve-Snapshot([string]$name) {
    if (Test-Path -LiteralPath $name) { return $name }
    foreach ($cand in @("$OutDir\$name.json", "$OutDir\$name")) {
        if (Test-Path -LiteralPath $cand) { return $cand }
    }
    return $null
}

function Flat-Map($obj, [string]$prefix = '') {
    # flatten nested objects; arrays are skipped (positions handled separately)
    $map = @{}
    foreach ($p in $obj.PSObject.Properties) {
        $path = if ($prefix -eq '') { $p.Name } else { "$prefix.$($p.Name)" }
        $v = $p.Value
        if ($null -eq $v) { $map[$path] = '' ; continue }
        if ($v -is [System.Management.Automation.PSCustomObject]) {
            $sub = Flat-Map $v $path
            foreach ($k in $sub.Keys) { $map[$k] = $sub[$k] }
        } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
            continue
        } else {
            $map[$path] = $v
        }
    }
    return $map
}

function Is-Num($v) { return ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) }

function Diff-Snapshots([string]$aPath, [string]$bPath) {
    # Read as UTF-8 EXPLICITLY.  Get-Content -Raw defaults to the ANSI/GBK code
    # page on this machine; decoding our UTF-8 snapshot that way mangles the
    # Chinese instrument names AND can swallow a following quote or backslash
    # into a double-byte GBK character, producing invalid JSON.
    $A = [System.IO.File]::ReadAllText($aPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $B = [System.IO.File]::ReadAllText($bPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Say ''
    Say "================ COMPARE  A=$($A.label)  B=$($B.label) ================"
    Say ("A: port=$($A.port) account=$($A.account) backend=$($A.health.backend)")
    Say ("B: port=$($B.port) account=$($B.account) backend=$($B.health.backend)")

    $fa = Flat-Map $A
    $fb = Flat-Map $B
    $keys = @($fa.Keys + $fb.Keys | Sort-Object -Unique)
    # Market-driven fields move on their own between two captures, so they can
    # only match when both sides are captured in the same quiet window (after
    # the close, prices are frozen).  Anything structural must match EXACTLY --
    # that is the difference between "the bridge agrees with miniQMT" and "the
    # market moved while I was looking".
    $MOVERS = @('asset.market_value', 'asset.total_asset', 'tick.last_price')
    $ok = 0; $expected = @(); $real = @(); $market = @(); $gaps = @()
    foreach ($k in $keys) {
        if ($k -like 'positions*') { continue }
        $va = $fa[$k]; $vb = $fb[$k]
        $same = $false
        if ($null -eq $va -and $null -eq $vb) { $same = $true }
        elseif (Is-Num $va -and (Is-Num $vb)) { $same = ([math]::Abs([double]$va - [double]$vb) -le $Tol) }
        else { $same = ("$va" -eq "$vb") }
        if ($same) { $ok++; continue }
        $line = "{0,-26} {1,-24} -> {2,-24}" -f $k, "$va", "$vb"
        if ($WHITELIST -contains $k) { $expected += $line }
        elseif ($KNOWN_GAPS -contains $k) { $gaps += $line }
        elseif ($MOVERS -contains $k) { $market += $line }
        else { $real += $line }
    }

    # positions: compare as a set, keyed by stock_code
    $pa = @{}; foreach ($p in @($A.positions)) { $pa[[string]$p.stock_code] = $p }
    $pb = @{}; foreach ($p in @($B.positions)) { $pb[[string]$p.stock_code] = $p }
    Say ''
    Say "positions: A=$($pa.Count)  B=$($pb.Count)"
    $onlyA = @($pa.Keys | Where-Object { -not $pb.ContainsKey($_) } | Sort-Object)
    $onlyB = @($pb.Keys | Where-Object { -not $pa.ContainsKey($_) } | Sort-Object)
    if ($onlyA.Count -eq 0 -and $onlyB.Count -eq 0) { Say '  code set: identical'; $ok++ }
    else {
        if ($onlyA.Count) { $real += "positions only in A: $($onlyA -join ', ')" }
        if ($onlyB.Count) { $real += "positions only in B: $($onlyB -join ', ')" }
    }
    $pFields = @('volume', 'can_use_volume', 'frozen_volume', 'on_road_volume', 'yesterday_volume',
                 'open_price', 'avg_price', 'last_price', 'market_value', 'profit_rate',
                 'instrument_name', 'secu_account')
    $MFIELDS = @('last_price', 'market_value', 'profit_rate')
    $pdiffStruct = @(); $pdiffMarket = @(); $pdiffGaps = @()
    foreach ($code in ($pa.Keys | Sort-Object)) {
        if (-not $pb.ContainsKey($code)) { continue }
        foreach ($f in $pFields) {
            $va = $pa[$code].$f; $vb = $pb[$code].$f
            $same = $false
            if (Is-Num $va -and (Is-Num $vb)) { $same = ([math]::Abs([double]$va - [double]$vb) -le $Tol) }
            else { $same = ("$va" -eq "$vb") }
            if ($same) { $ok++ }
            else {
                $l = "{0,-12} {1,-18} {2,-22} -> {3}" -f $code, $f, "$va", "$vb"
                if ($POSITION_GAPS -contains $f) { $pdiffGaps += $l }
                elseif ($MFIELDS -contains $f) { $pdiffMarket += $l }
                else { $pdiffStruct += $l }
            }
        }
    }
    if ($pdiffStruct.Count -eq 0 -and $pdiffMarket.Count -eq 0 -and $pdiffGaps.Count -eq 0) {
        Say '  per-field: all identical (within tolerance)'
    } else {
        Say "  per-field STRUCTURAL differences: $($pdiffStruct.Count)"
        foreach ($d in $pdiffStruct) { Say "    ! $d" }
        Say "  per-field market-driven differences: $($pdiffMarket.Count)  (last_price / market_value / profit_rate)"
        foreach ($d in $pdiffMarket) { Say "    ~ $d" }
        if ($pdiffGaps.Count) {
            Say "  per-field KNOWN GAPS: $($pdiffGaps.Count)  (accepted; section 35 G1/G2 -- confirm the consumer ignores them)"
            foreach ($d in $pdiffGaps) { Say "    = $d" }
        }
    }

    Say ''
    Say "fields identical: $ok"
    if ($expected.Count) {
        Say ''
        Say "--- expected to differ ($($expected.Count)) ---"
        foreach ($l in $expected) { Say "  $l" }
    }
    if ($gaps.Count) {
        Say ''
        Say "--- KNOWN ACCEPTED GAPS ($($gaps.Count)) -- not counted as structural, but never silent ---"
        foreach ($l in $gaps) { Say "  = $l" }
    }
    if ($market.Count) {
        Say ''
        Say "--- market-driven drift ($($market.Count)) -- only matches in a quiet window ---"
        foreach ($l in $market) { Say "  ~ $l" }
    }
    Say ''
    $drift = $market.Count + $pdiffMarket.Count
    $struct = $real.Count + $pdiffStruct.Count
    $gapN = $gaps.Count + $pdiffGaps.Count
    if ($struct -eq 0) {
        if ($drift -eq 0) {
            Say "=== VERDICT: EQUIVALENT (no differences at all; $gapN known gap(s)) ==="
        } else {
            Say "=== VERDICT: STRUCTURALLY EQUIVALENT -- $struct structural difference(s), $drift market-driven, $gapN known gap(s) ==="
            Say '    (everything that must match does match; the rest are prices that moved between the two captures)'
        }
        $script:DIFF_RC = 0
        return
    }
    Say "=== VERDICT: $struct STRUCTURAL DIFFERENCE(S) -- review each, do NOT proceed on trust ==="
    foreach ($l in $real) { Say "  ! $l" }
    foreach ($l in $pdiffStruct) { Say "  ! $l" }
    $script:DIFF_RC = 1
    return
}

if ($CompareA -ne '' -or $CompareB -ne '') {
    if ($CompareA -eq '' -or $CompareB -eq '') { Say 'ERROR: -CompareA and -CompareB must be given together'; exit 2 }
    $a = Resolve-Snapshot $CompareA
    $b = Resolve-Snapshot $CompareB
    if (-not $a) { Say "ERROR: snapshot not found: $CompareA"; exit 2 }
    if (-not $b) { Say "ERROR: snapshot not found: $CompareB"; exit 2 }
    # NOT `exit (Diff-Snapshots ...)`: the parentheses capture the function's
    # whole output stream into the exit value, so the diff would never print.
    $script:DIFF_RC = 0
    Diff-Snapshots $a $b
    exit $script:DIFF_RC
}
if ($Capture -eq '') { Say 'ERROR: pass -Capture <label>, or -CompareA <a> -CompareB <b>'; exit 2 }

# ---------------------------------------------------------------- capture mode
Say "=== capture '$Capture'  port=$Port account=$Account ==="
if (-not (Test-Path -LiteralPath $ConfigYml)) { Say "ERROR: config yml not found: $ConfigYml"; exit 2 }
$km = [regex]::Match([System.IO.File]::ReadAllText($ConfigYml, [System.Text.Encoding]::UTF8), 'api_keys:\s*\r?\n\s*-\s*"?([^"\r\n]+?)"?\s*\r?\n')
if (-not $km.Success) { Say 'ERROR: could not read api_keys[0]'; exit 2 }
$H = @('-H', ("Authorization: Bearer " + $km.Groups[1].Value.Trim()))
$base = "http://127.0.0.1:$Port"
$enc = New-Object System.Text.UTF8Encoding($false)

function CGet([string]$url) { return (& $curl -s @H $url 2>&1 | Out-String) }
function CPost([string]$url, [string]$json, [string]$tmpName) {
    # request bodies live in _tmp\ so the snapshot listing stays unambiguous
    $tmpDir = Join-Path $OutDir '_tmp'
    if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $f = Join-Path $tmpDir $tmpName
    [System.IO.File]::WriteAllText($f, $json, $enc)
    return (& $curl -s @H -X POST -H 'Content-Type: application/json' --data-binary "@$f" $url 2>&1 | Out-String)
}
function AsJson($s) { try { return ($s | ConvertFrom-Json) } catch { return $null } }

$health = AsJson (CGet "$base/health/ready")
if (-not $health) { Say "ERROR: $base/health/ready did not answer -- is the service up and the key right?"; exit 3 }

$sess = AsJson (CPost "$base/api/v1/trading/sessions" ('{"account_id": "' + $Account + '", "account_type": "STOCK"}') '_session-req.json')
$sid = $null
if ($sess -and $sess.data) { $sid = $sess.data.session_id }
if (-not $sid) { Say 'ERROR: could not open a session (see logs)'; exit 4 }

# Re-read health NOW THAT A SESSION IS OPEN.  `backend` and `status` are derived
# from the open sessions, so the read above (which is only a liveness gate) can
# never report them: it says status=idle backend=none even on a perfectly wired
# bridge.  Measured 2026-09-15 -- migration doc section 46.4.
$healthOpen = AsJson (CGet "$base/health/ready")
if ($healthOpen -and $healthOpen.data) { $health = $healthOpen }
Say ("health (with the session open): status=" + $health.data.status + " backend=" + $health.data.backend)

$assetRaw = AsJson (CGet "$base/api/v1/trading/sessions/$sid/asset")
$posRaw = AsJson (CGet "$base/api/v1/trading/sessions/$sid/positions")
$ordRaw = AsJson (CGet "$base/api/v1/trading/sessions/$sid/orders")
$trdRaw = AsJson (CGet "$base/api/v1/trading/sessions/$sid/trades")
$tickRaw = AsJson (CPost "$base/api/v1/data/full-tick" ('{"symbols": ["' + $Symbol + '"]}') '_tick-req.json')

$positions = @()
if ($posRaw -and $posRaw.data -and $posRaw.data.items) {
    foreach ($p in @($posRaw.data.items)) {
        $positions += [PSCustomObject]@{
            stock_code = [string]$p.stock_code
            volume = $p.volume
            can_use_volume = $p.can_use_volume
            frozen_volume = $p.frozen_volume
            on_road_volume = $p.on_road_volume
            yesterday_volume = $p.yesterday_volume
            open_price = $p.open_price
            market_value = $p.market_value
            avg_price = $p.avg_price
            last_price = $p.last_price
            profit_rate = $p.profit_rate
            instrument_name = [string]$p.instrument_name
            secu_account = [string]$p.secu_account
        }
    }
}

$probe = ''
$probeFile = "$proxyDir\scripts\bridge_rpc_probe.py"
if (Test-Path -LiteralPath $probeFile) {
    $probe = (& "$proxyDir\.venv\Scripts\python.exe" $probeFile $Account 2>&1 | Out-String).Trim()
}
$allow = $null
if ($probe -match 'allow_order_methods=(\w+)') { $allow = $Matches[1] }

$tickLast = $null
if ($tickRaw -and $tickRaw.data -and $tickRaw.data.items) {
    try { $tickLast = $tickRaw.data.items[0].tick.last_price } catch { }
}

$snap = [PSCustomObject]@{
    label = $Capture
    timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    port = $Port
    account = $Account
    health = $health.data
    probe = $probe
    allow_order_methods = $allow
    asset = $(if ($assetRaw -and $assetRaw.data) { $assetRaw.data } else { $null })
    positions = $positions
    counts = [PSCustomObject]@{
        positions = $positions.Count
        orders = $(if ($ordRaw -and $ordRaw.data -and $ordRaw.data.items) { @($ordRaw.data.items).Count } else { 0 })
        trades = $(if ($trdRaw -and $trdRaw.data -and $trdRaw.data.items) { @($trdRaw.data.items).Count } else { 0 })
    }
    tick = [PSCustomObject]@{ symbol = $Symbol; last_price = $tickLast }
}

$out = Join-Path $OutDir "$Capture.json"
[System.IO.File]::WriteAllText($out, ($snap | ConvertTo-Json -Depth 8), $enc)
[void](& $curl -s -o NUL -X DELETE @H "$base/api/v1/trading/sessions/$sid" 2>&1)

Say ("health   : status=" + $snap.health.status + " backend=" + $snap.health.backend + " sessions_real=" + $snap.health.sessions_real)
Say ("probe    : " + $probe)
Say ("asset    : " + ($snap.asset | ConvertTo-Json -Compress))
Say ("positions: " + $positions.Count + "  orders=" + $snap.counts.orders + " trades=" + $snap.counts.trades)
Say ("tick     : " + $Symbol + " last=" + $tickLast)
Say "snapshot -> $out"
exit 0
