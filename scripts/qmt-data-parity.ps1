<#
  qmt-data-parity.ps1 -- compare the proxy's DATA endpoints between two backends.

  WHY: the bridge checkout is injected via PYTHONPATH, and that shadows not only
  xtquant.xttrader but also xtquant.xtdata -- so switching the backend changes
  the MARKET-DATA path too, not just trading.  Before the switch only
  /data/full-tick had ever been compared field by field; kline, tick-history,
  financial, calendar, sectors, index-weight and instrument had not.

  This does NOT diff whole payloads (they are large and change with the market).
  It compares what a regression would break:
      HTTP status | success flag | item count | the KEY SET of one item
  plus a couple of spot values for the endpoints where a value is meaningful.

  READ-ONLY: only GET/POST queries.  Subscriptions are checked on the BRIDGE
  side only (creating one on the live mini service would leave state behind and
  there is no DELETE route).

  USAGE (normally run against the 8003 bridge test instance)
    qmt-data-parity.ps1 -PortA 8002 -YmlA config.local.666.yml `
                        -PortB 8003 -YmlB config.local.666.yml
#>
param(
    [int]$PortA = 8002,
    [string]$YmlA = 'config.local.666.yml',
    [int]$PortB = 8003,
    [string]$YmlB = 'config.local.666.yml',
    [string]$Symbol = '600000.SH',
    [string]$Index = '000300.SH'
)
$ErrorActionPreference = 'Continue'
$proxyDir = 'G:\qmt_projects\quant-qmt-proxy'
$curl = "$env:SystemRoot\System32\curl.exe"

function Get-Key([string]$yml) {
    if (-not [System.IO.Path]::IsPathRooted($yml)) { $yml = Join-Path $proxyDir $yml }
    $t = [System.IO.File]::ReadAllText($yml, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($t, 'api_keys:\s*\r?\n\s*-\s*"?([^"\r\n]+?)"?\s*\r?\n')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}
$keyA = Get-Key $YmlA
$keyB = Get-Key $YmlB
if (-not $keyA -or -not $keyB) { Write-Output 'ERROR: could not read an api key'; exit 2 }

$tmp = Join-Path $env:TEMP 'qmt-parity'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)

function Call([int]$port, [string]$key, [string]$method, [string]$path, [string]$body) {
    $url = "http://127.0.0.1:$port$path"
    $hdr = @('-H', "Authorization: Bearer $key")
    if ($method -eq 'GET') {
        $out = & $curl -s -w "`nHTTP=%{http_code}" @hdr $url 2>&1 | Out-String
    } else {
        $f = Join-Path $tmp ("body" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
        [System.IO.File]::WriteAllText($f, $body, $enc)
        $out = & $curl -s -w "`nHTTP=%{http_code}" @hdr -X POST -H 'Content-Type: application/json' --data-binary "@$f" $url 2>&1 | Out-String
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    $code = '?'
    if ($out -match 'HTTP=(\d+)') { $code = $Matches[1] }
    $json = ($out -replace "`r?`nHTTP=\d+\s*$", '').Trim()
    return @{ code = $code; raw = $json }
}

function Shape($res) {
    $d = $null
    try { $d = $res.raw | ConvertFrom-Json } catch { }
    if ($null -eq $d) { return @{ ok = 'parse-fail'; n = '-'; keys = ('raw:' + $res.raw.Substring(0, [Math]::Min(60, $res.raw.Length))) } }
    $ok = if ($d.PSObject.Properties.Name -contains 'success') { [string]$d.success } else { '?' }
    $data = $d.data
    $items = $null
    if ($data) {
        foreach ($nm in 'items', 'rows', 'list') {
            if ($data.PSObject.Properties.Name -contains $nm) { $items = $data.$nm; break }
        }
    }
    $n = '-'
    $keys = '-'
    if ($null -ne $items) {
        if ($items -is [System.Collections.IEnumerable] -and -not ($items -is [string])) {
            $arr = @($items)
            $n = $arr.Count
            if ($n -gt 0 -and $arr[0]) { $keys = (($arr[0].PSObject.Properties.Name | Sort-Object) -join ',') }
        } else {
            $n = 1
            $keys = (($items.PSObject.Properties.Name | Sort-Object) -join ',')
        }
    } elseif ($data) {
        $keys = (($data.PSObject.Properties.Name | Sort-Object) -join ',')
    }
    if ($keys.Length -gt 78) { $keys = $keys.Substring(0, 78) + '...' }
    return @{ ok = $ok; n = $n; keys = $keys }
}

$cases = @(
    @{ name = 'kline-history';  m = 'POST'; p = '/api/v1/data/kline-history';  b = ('{"symbols":["' + $Symbol + '"],"period":"1d","start_time":"20260825","end_time":"20260915"}') },
    @{ name = 'tick-history';   m = 'POST'; p = '/api/v1/data/tick-history';   b = ('{"symbols":["' + $Symbol + '"]}') },
    @{ name = 'full-tick';      m = 'POST'; p = '/api/v1/data/full-tick';      b = ('{"symbols":["' + $Symbol + '"]}') },
    @{ name = 'financial';      m = 'POST'; p = '/api/v1/data/financial';      b = ('{"symbols":["' + $Symbol + '"],"table_names":["Balance"]}') },
    @{ name = 'trading-calendar'; m = 'POST'; p = '/api/v1/data/trading-calendar'; b = '{"market":"SH"}' },
    @{ name = 'index-weight';   m = 'POST'; p = '/api/v1/data/index-weight';   b = ('{"index_code":"' + $Index + '"}') },
    @{ name = 'instrument';     m = 'GET';  p = ('/api/v1/data/instrument/' + $Symbol + '?complete=true'); b = '' },
    @{ name = 'sectors';        m = 'GET';  p = '/api/v1/data/sectors';        b = '' }
)

Write-Output ("=== data parity: mini($PortA/$YmlA)  vs  bridge($PortB/$YmlB)   " + (Get-Date -Format 'HH:mm:ss') + " ===")
$diffs = 0
foreach ($c in $cases) {
    $ra = Call $PortA $keyA $c.m $c.p $c.b
    $rb = Call $PortB $keyB $c.m $c.p $c.b
    $sa = Shape $ra; $sb = Shape $rb
    $same = ($ra.code -eq $rb.code) -and ($sa.ok -eq $sb.ok) -and ($sa.n -eq $sb.n) -and ($sa.keys -eq $sb.keys)
    $verdict = if ($same) { 'SAME' } else { 'DIFF'; }
    if (-not $same) { $diffs++ }
    Write-Output ("{0,-17} {1,-5} {2,-46} {3,-46} {4}" -f $c.name, $verdict,
                  ("HTTP $($ra.code) ok=$($sa.ok) n=$($sa.n)"), ("HTTP $($rb.code) ok=$($sb.ok) n=$($sb.n)"), '')
    if (-not $same) {
        Write-Output ("    mini   keys: " + $sa.keys)
        Write-Output ("    bridge keys: " + $sb.keys)
        if ($ra.code -ne '200' -or $rb.code -ne '200') {
            Write-Output ("    mini   raw : " + $ra.raw.Substring(0, [Math]::Min(160, $ra.raw.Length)))
            Write-Output ("    bridge raw : " + $rb.raw.Substring(0, [Math]::Min(160, $rb.raw.Length)))
        }
    }
}

# --- subscriptions: BRIDGE ONLY (a subscription on the live mini would linger,
#     and the API has no DELETE route) -----------------------------------------
Write-Output ''
Write-Output '--- subscriptions (bridge only; mini is left untouched on purpose) ---'
$sub = Call $PortB $keyB 'POST' '/api/v1/data/subscriptions/quote' ('{"symbols":["' + $Symbol + '"],"period":"tick","count":5}')
Write-Output ("  POST /subscriptions/quote -> HTTP " + $sub.code + "  " + $sub.raw.Substring(0, [Math]::Min(200, $sub.raw.Length)))

Write-Output ''
Write-Output ("differences: $diffs / " + $cases.Count)
if ($diffs -eq 0) { Write-Output '=== all data endpoints agree between the two backends ===' }
else { Write-Output '=== review each DIFF: a data-path regression must not be migrated onto ===' }
exit $diffs
