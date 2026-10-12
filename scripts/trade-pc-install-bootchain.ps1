# 部署位置：C:\temp\install-bootchain.ps1（一次性，需提权运行；已跑过 2026-09-15 23:39）
# install-bootchain.ps1 -- ONE-SHOT privileged fix for trade-pc (ASCII only; run as admin)
# 1. register DSH-BootChain (logon, elevated) -> qmt-boot-chain.ps1
# 2. repoint the HKCU Run keys so nothing starts WSL at medium integrity any more
# 3. bring this boot's trading chain up: run the SYSTEM task QMT-Proxy-AutoStart
$log = 'C:\temp\bootchain-install.log'
function Say([string]$m) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
    Add-Content -LiteralPath $log -Value $line
    Write-Output $line
}
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$admin = $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say ('=== install-bootchain start  admin=' + $admin + ' ===')
if (-not $admin) { Say 'ERROR: not elevated -- re-run from an elevated prompt'; exit 1 }

# --- 1) register the boot-chain task
$script = 'C:\Users\wbaif\scripts\qmt-boot-chain.ps1'
if (-not (Test-Path -LiteralPath $script)) { Say ('ERROR missing ' + $script); exit 1 }
try {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $script + '"')
    $trg = New-ScheduledTaskTrigger -AtLogOn -User 'DESKTOP-V9NFKCR\wbaif'
    $trg.Delay = 'PT15S'
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $prn = New-ScheduledTaskPrincipal -UserId 'DESKTOP-V9NFKCR\wbaif' -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'DSH-BootChain' -Action $act -Trigger $trg -Settings $set -Principal $prn -Force | Out-Null
    $t = Get-ScheduledTask -TaskName 'DSH-BootChain'
    Say ('task DSH-BootChain registered state=' + $t.State + ' runLevel=' + $t.Principal.RunLevel)
} catch { Say ('ERROR registering task: ' + $_.Exception.Message); exit 1 }

# --- 2) HKCU Run keys: no more medium-integrity wsl.exe launches
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
Set-ItemProperty -Path $run -Name 'DSH-Web-AutoStart' -Value 'schtasks.exe /run /tn DSH-BootChain' -PropertyType String -Force
Say 'set DSH-Web-AutoStart = schtasks.exe /run /tn DSH-BootChain'
Remove-ItemProperty -Path $run -Name 'DSH-BootChain-AutoStart' -Force -ErrorAction SilentlyContinue
Say 'removed DSH-BootChain-AutoStart (superseded by the task)'
(Get-ItemProperty -Path $run).PSObject.Properties | Where-Object { $_.Name -like 'DSH*' } | ForEach-Object { Say ('  run: ' + $_.Name + ' = ' + $_.Value) }

# --- 3) run the chain now (the boot script is idempotent)
$out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String).Trim()
Say ('boot-chain now: ' + ($out -replace "`r?`n", ' | '))
schtasks.exe /run /tn QMT-Proxy-AutoStart 2>&1 | ForEach-Object { Say ('schtasks run QMT-Proxy-AutoStart: ' + $_) }
Start-Sleep -Seconds 20
foreach ($s in 'QMTProxy-020','QMTProxy-666','QMTProxy-2986') {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    Say ('service ' + $s + ' = ' + $svc.Status)
}
Say '=== install-bootchain done (proxy startup continues in the background, up to 15 min) ==='
