<#
  qmt-register-check.ps1 -- READ-ONLY verifier for the four-piece strategy
  registration of BIGQMT_BRIDGE, per installation.

  WHY THIS EXISTS
  ---------------
  Registering the bridge strategy is done through the QMT UI (the editor then
  encrypts the .py and writes the XML itself).  The scary failure mode is not
  "it did not register" -- that is obvious -- it is "it registered, but bound to
  the WRONG account", because then the 020 installation would open
  bigqmt:rpc:req:666810082889, i.e. collide with the 666 production bridge
  (migration doc section 39.7).  The UI cannot be trusted to have picked the
  right account; this script reads the result out of the XML instead.

  It also works as a positive control: run it for 666 (which is known good) and
  for 020 (which should report NOT REGISTERED until the UI step is done).

  Nothing here writes anything.

  USAGE
    qmt-register-check.ps1 -Account 666     # expect REGISTERED + bound to 666
    qmt-register-check.ps1 -Account 020     # expect NOT REGISTERED before the UI step
  Exit 0 = as expected for that account, 1 = problem, 2 = bad invocation.
#>
param(
    [ValidateSet('666', '020')] [string]$Account = '666'
)
$ErrorActionPreference = 'Continue'

$map = @{
    # 'Others' = the other accounts this SAME terminal can log into.  Measured
    # 2026-09-15: the 020 terminal logs in BOTH 020100053835 and 902010000340
    # (its message log shows two successful-login lines), so the UI account picker offers
    # two choices and "bound to the wrong one" is a live possibility -- it must be
    # reported as a failure, not as an unknown value.
    '666' = @{ Dir = 'G:\qmt1'; Acct = '666810082889'; Others = @('020100053835') }
    '020' = @{ Dir = 'G:\qmt';  Acct = '020100053835'; Others = @('666810082889', '902010000340') }
}
$dir = $map[$Account].Dir
$acct = $map[$Account].Acct
$others = @($map[$Account].Others)

$fails = New-Object System.Collections.ArrayList
function Say($m) { Write-Output $m }
function Bad($m) { [void]$fails.Add($m); Write-Output ("  FAIL: " + $m) }
function Ok($m) { Write-Output ("  ok  : " + $m) }

$cfg = Join-Path $dir 'config\indexUserConfig.xml'
$py = Join-Path $dir 'python\BIGQMT_BRIDGE.py'
$steps = Join-Path $dir 'indexConfig\formulainitstepsinof'

Say ("=== BIGQMT_BRIDGE registration check  account=$Account ($acct)  dir=$dir ===")

# ---- expected account key, from THIS install's own authAndConfig.xml --------
$expectedKey = ''
$authFiles = @(Get-ChildItem -Path (Join-Path $dir 'userdata\users') -Recurse -Filter 'authAndConfig.xml' -ErrorAction SilentlyContinue)
foreach ($a in $authFiles) {
    $t = [System.IO.File]::ReadAllText($a.FullName, [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($t, '2____[0-9A-Za-z_]+')) {
        if ($m.Value -like "*$acct*") { $expectedKey = $m.Value; break }
    }
    if ($expectedKey -ne '') { break }
}
if ($expectedKey -ne '') { Say ("  this install's own account key for $acct : " + $expectedKey) }
else { Say ("  (could not read this install's own account key -- will only check that the account number appears)") }

# ---- piece 1: the strategy code file ---------------------------------------
Say ''
Say '--- piece 1: python\BIGQMT_BRIDGE.py ---'
if (Test-Path -LiteralPath $py) {
    $b = [System.IO.File]::ReadAllBytes($py)
    $head = [System.Text.Encoding]::ASCII.GetString($b[0..([Math]::Min(31, $b.Length - 1))])
    $plain = $head -match '^(#|\s|"""|import|from)'
    Ok ("present: " + $b.Length + " bytes, head looks " + $(if ($plain) { 'PLAIN-text' } else { 'ENCODED (editor product)' }))
    if (-not $plain) { Say ("        head: " + $head) }
} else {
    Bad "missing $py"
}

# ---- piece 2 + 3: catalog line and item in indexUserConfig.xml -------------
Say ''
Say '--- pieces 2/3: config\indexUserConfig.xml ---'
if (-not (Test-Path -LiteralPath $cfg)) {
    Bad "missing $cfg"
} else {
    $xml = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8)
    Say ("  file: " + (Get-Item -LiteralPath $cfg).Length + " bytes")

    $cat = @([regex]::Matches($xml, '<catalog[^>]*name="BIGQMT_BRIDGE"[^>]*/?>'))
    if ($cat.Count -eq 1) { Ok 'catalog entry present (exactly 1)' }
    elseif ($cat.Count -eq 0) { Bad 'no <catalog ... name="BIGQMT_BRIDGE" ...> entry (piece 2 missing)' }
    else { Bad ("$($cat.Count) catalog entries named BIGQMT_BRIDGE (expected 1)") }

    $keys = @([regex]::Matches($xml, 'm_strAccountKey="([^"]*)"'))
    $items = @([regex]::Matches($xml, '<item\b[^>]*BIGQMT_BRIDGE'))
    Say ("  <item> elements mentioning BIGQMT_BRIDGE: " + $items.Count + " ; m_strAccountKey attributes: " + $keys.Count)
    if ($keys.Count -eq 0) {
        Bad 'no m_strAccountKey found (piece 3 missing)'
    } else {
        foreach ($k in $keys) {
            $v = $k.Groups[1].Value
            if ($v -like "*$acct*") { Ok ("bound to THIS account: " + $v) }
            else {
                $hit = @($others | Where-Object { $v -like "*$_*" })
                if ($hit.Count -gt 0) {
                    Bad ("BOUND TO THE WRONG ACCOUNT: " + $v + "  (that is " + ($hit -join '/') + ")" + `
                         "  <-- the UI account picker offered more than one choice; redo the registration and pick the right account")
                } else {
                    Bad ("m_strAccountKey present but names neither this account nor any known sibling: " + $v)
                }
            }
            if ($expectedKey -ne '' -and $v -ne $expectedKey) {
                Bad ("m_strAccountKey does not match this install's own key.  expected=" + $expectedKey)
            }
        }
    }

    # the item also carries the account in an HTML-escaped JSON blob
    $qs = @([regex]::Matches($xml, 'm_qsAccount&quot;\s*:\s*&quot;([^&]*)&quot;'))
    if ($qs.Count -eq 0) { Say '  note: no m_qsAccount field found in the item (older layout?)' }
    foreach ($q in $qs) {
        $v = $q.Groups[1].Value
        if ($v -eq $acct) { Ok ("m_qsAccount = " + $v) }
        elseif (@($others) -contains $v) { Bad ("m_qsAccount is ANOTHER account of this terminal: " + $v) }
        else { Bad ("m_qsAccount is unexpected: " + $v) }
    }

    $auto = @([regex]::Matches($xml, 'name=.BIGQMT_BRIDGE.[^>]*startupAutorun="1"|startupAutorun="1"[^>]*name=.BIGQMT_BRIDGE.'))
    if ($auto.Count -ge 1) { Ok 'startupAutorun="1" present on the BIGQMT_BRIDGE item' }
    else {
        # the attribute order is not guaranteed -- fall back to a proximity test
        if ($xml -match 'BIGQMT_BRIDGE[\s\S]{0,20000}?startupAutorun="1"') { Ok 'startupAutorun="1" found near the BIGQMT_BRIDGE item' }
        else { Bad 'startupAutorun="1" NOT found (the strategy would not auto-start after a terminal restart)' }
    }
}

# ---- piece 4: indexConfig\formulainitstepsinof -----------------------------
Say ''
Say '--- piece 4: indexConfig\formulainitstepsinof ---'
if (-not (Test-Path -LiteralPath $steps)) {
    Bad "missing $steps"
} else {
    $hit = @(Get-Content -LiteralPath $steps | Where-Object { $_ -match '^\s*BIGQMT_BRIDGE\s*,' })
    if ($hit.Count -eq 1) { Ok ("present: " + $hit[0].Trim()) }
    elseif ($hit.Count -eq 0) { Bad 'no BIGQMT_BRIDGE line' }
    else { Bad ("$($hit.Count) BIGQMT_BRIDGE lines (expected 1)") }
}

# ---- verdict ---------------------------------------------------------------
Say ''
Say '================ VERDICT ================'
if ($fails.Count -eq 0) {
    Say ("  REGISTERED and bound to $acct -- all four pieces look right")
    exit 0
}
Say ("  PROBLEM -- " + $fails.Count + " failed check(s):")
foreach ($f in $fails) { Say ("    ! " + $f) }
exit 1
