<#
  qmt-install-proxy-instance.ps1 -- register (or remove) an ADDITIONAL
  quant-qmt-proxy instance as an NSSM service, by CLONING an existing one.

  WHY CLONE INSTEAD OF "nssm install"
  ----------------------------------
  The two production instances (QMTProxy-020 / QMTProxy-666) carry a dozen NSSM
  settings that matter at runtime (AppExit defaults, AppThrottle=5000,
  AppRestartDelay=5000, AppRotateFiles/Bytes, ObjectName=LocalSystem).  A fresh
  `nssm install` starts from NSSM's defaults and silently drops them.  Cloning
  the registry key (reg copy /s) reproduces the source service byte for byte, and
  only the four per-instance values are then overwritten:
      APP_PORT / GRPC_PORT / APP_LOCAL_CONFIG / BIGQMT_ACCOUNT_ID
  plus AppStdout/AppStderr (log file names) and the optional board gate.

  Safe to clone because ImagePath is just "G:\...\nssm.exe" with NO service-name
  argument -- NSSM derives the service name from the SCM service it runs as.

  WHAT IT DOES NOT DO
  -------------------
  * It does NOT start the service (unless -Start).  Order matters: the in-client
    bridge strategy must be up first, otherwise the proxy can only fail health.
  * It does NOT touch the source instance, nor the QMT client.
  * Start type stays DEMAND (0x3) exactly like 666/020 -- the logon chain
    (QMT-Proxy-AutoStart -> restart-proxy.ps1) owns the lifecycle, so registering
    a service must not make it appear on the next boot before it is wired in.

  ROLLBACK
  --------
    powershell -File qmt-install-proxy-instance.ps1 -Name QMTProxy-2986 -Remove
  removes the service definition (stop + delete).  The config yml + start bat
  files are separate and are NOT deleted (they are inert; delete by hand).

  EXIT CODES
    0  = done (registered or removed)
    2  = bad invocation (source service missing / proxy dir missing)
    9  = refused: target service already exists (or does not, for -Remove)
   10 = a post-check failed (env or paths did not read back as written)
#>
param(
    [string]$Name          = 'QMTProxy-2986',
    [string]$Source        = 'QMTProxy-666',
    [int]$Port             = 8003,
    [int]$GrpcPort         = 50053,
    [string]$AccountId     = '666656292986',
    [string]$ConfigYml     = 'config.local.2986.yml',
    # Board gate (deny list, comma separated digit prefixes).  Empty = no gate.
    # Rationale: the broker is the final authority, an over-eager allow list would
    # kill legitimate main-board ETF/bond orders, while an under-blocked order
    # only comes back as a rejected order.  Codes whose prefix is not listed pass.
    # ChiNext 300/301/302, STAR 688/689, BSE 43/83/87/88/92 -- the BSE
    # prefixes are listed explicitly so the gate does not depend on
    # normalize_stock_code() having run first (unit test covers bare codes).
    [string]$DenyCodePrefixes = '300,301,302,688,689,43,83,87,88,92',
    [string]$ProxyDir      = 'G:\qmt_projects\quant-qmt-proxy',
    [string]$PythonPath    = 'C:\bridge-client\bridge\src;C:\bridge-client',
    [switch]$Start,
    [switch]$Remove,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$K = "$env:SystemRoot\System32"
function Say($m) { Write-Output $m }

$rootKey = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"
$srcKey  = "HKLM\SYSTEM\CurrentControlSet\Services\$Source"
$nssm    = Join-Path $ProxyDir 'nssm.exe'

function Get-Svc($n) {
    $out = & "$K\sc.exe" query $n 2>&1 | Out-String
    if ($out -match 'SERVICE_NAME') { return $out } else { return $null }
}

# ---------------------------------------------------------------- removal path
if ($Remove) {
    if (-not (Get-Svc $Name)) { Say "REFUSING: service $Name does not exist"; exit 9 }
    Say "=== removing $Name ==="
    if ($DryRun) { Say "DRYRUN stop/delete $Name"; exit 0 }
    & "$K\sc.exe" stop $Name | Out-Null
    Start-Sleep -Seconds 3
    $del = & "$K\sc.exe" delete $Name 2>&1 | Out-String
    Say $del.Trim()
    if (Get-Svc $Name) { Say "ERROR: $Name still present"; exit 10 }
    Say "OK: $Name removed"
    exit 0
}

# -------------------------------------------------------------- register path
if (Get-Svc $Name) { Say "REFUSING: service $Name already exists (use -Remove first)"; exit 9 }
if (-not (Get-Svc $Source)) { Say "REFUSING: source service $Source not found"; exit 2 }
if (-not (Test-Path -LiteralPath $nssm)) { Say "REFUSING: nssm.exe not found: $nssm"; exit 2 }
$cfg = Join-Path $ProxyDir $ConfigYml
if (-not (Test-Path -LiteralPath $cfg)) { Say "REFUSING: config not found: $cfg"; exit 2 }

Say "=== registering $Name  (clone of $Source) ==="
Say "  account   = $AccountId"
Say "  port      = $Port   grpc = $GrpcPort"
Say "  config    = $ConfigYml"
Say "  denyCode  = $DenyCodePrefixes"

if ($DryRun) {
    Say "DRYRUN: would reg copy $srcKey -> $rootKey, then nssm set the 4 per-instance values"
    exit 0
}

$cp = & "$K\reg.exe" copy $srcKey $rootKey /s /f 2>&1 | Out-String
Say ("  reg copy  : " + $cp.Trim())

Set-ItemProperty -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name) -Name DisplayName -Value $Name
& "$K\sc.exe" config $Name start= demand | Out-Null

# The env list must be COMPLETE -- nssm set replaces it wholesale.  These are
# exactly the 7 vars the two production instances carry, plus the board gate.
$envPairs = @(
    "APP_MODE=prod",
    "APP_PORT=$Port",
    "GRPC_PORT=$GrpcPort",
    "APP_SERVERS=all",
    "APP_LOCAL_CONFIG=$ConfigYml",
    "BIGQMT_ACCOUNT_ID=$AccountId",
    "BIGQMT_DENY_CODE_PREFIXES=$DenyCodePrefixes",
    "PYTHONPATH=$PythonPath"
)
$out = & $nssm set $Name AppEnvironmentExtra @envPairs 2>&1 | Out-String
Say ("  nssm env  : " + $out.Trim())
& $nssm set $Name AppStdout (Join-Path $ProxyDir ("logs\stdout-" + ($Name -replace '^QMTProxy-', '') + ".log")) | Out-Null
& $nssm set $Name AppStderr (Join-Path $ProxyDir ("logs\stderr-" + ($Name -replace '^QMTProxy-', '') + ".log")) | Out-Null

# ------------------------------------------------------------------ read back
Say "=== read back ==="
$p = Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name + "\Parameters")
Say ("  Application : " + $p.Application)
Say ("  AppDirectory: " + $p.AppDirectory)
Say ("  AppParameters: " + $p.AppParameters)
foreach ($e in $p.AppEnvironmentExtra) { Say ("  env: " + $e) }
Say ("  stdout: " + $p.AppStdout)
Say ("  Start : " + (Get-ItemProperty ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $Name)).Start + "  (3 = demand)")

$bad = @()
if ($p.AppEnvironmentExtra -notcontains "APP_PORT=$Port") { $bad += "APP_PORT" }
if ($p.AppEnvironmentExtra -notcontains "BIGQMT_ACCOUNT_ID=$AccountId") { $bad += "BIGQMT_ACCOUNT_ID" }
if ($p.AppEnvironmentExtra -notcontains "APP_LOCAL_CONFIG=$ConfigYml") { $bad += "APP_LOCAL_CONFIG" }
if ($bad.Count -gt 0) { Say ("ERROR: env read-back mismatch: " + ($bad -join ',')); exit 10 }

Say "OK: $Name registered (NOT started)"
if ($Start) { Say "starting..."; & "$K\sc.exe" start $Name | Out-Null }
exit 0
