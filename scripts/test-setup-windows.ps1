# Copyright 2026 Denis Arnst (Sapd) - https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
#
# One step of the end-to-end test of setup-windows.ps1, run on the Windows PC as
# administrator. scripts/test-setup-e2e.sh on the Mac drives the steps: it restarts
# a Longcable test server on port 3241 with what each step shares, serves the
# script over HTTP, and calls this file over SSH. Each step runs the exact command
# Connect a PC builds, in a PowerShell with ExecutionPolicy Restricted. Entries for
# other servers/ports must stay unchanged throughout.
param([string]$Step, [string]$Ip, [string]$Name, [string]$ScriptUrl)
$ErrorActionPreference = 'Stop'
$stateKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\usbip2_ude\State'
$waitingFile = Join-Path $env:ProgramData 'Longcable\waiting.txt'
$beforeFile = 'C:\Temp\longcable-e2e-before.txt'
function Stashed { @((Get-ItemProperty $stateKey -Name PersistentDevices -ErrorAction SilentlyContinue).PersistentDevices) }
function Mine { @(Stashed | Where-Object { $_ -match ',3241,' }) }
function Others { @(Stashed | Where-Object { $_ -notmatch ',3241,' } | Sort-Object) }
function Attached3241 { @((& 'C:\Program Files\USBip\usbip.exe' port) -match ':3241/') }
function Waiting3241 { if (Test-Path $waitingFile) { @(Get-Content $waitingFile | Where-Object { $_ -match ',3241,' }) } else { @() } }
$fail = 0
function Check([string]$what, [bool]$ok) {
  if ($ok) { Write-Host "PASS $what" } else { Write-Host "FAIL $what"; $script:fail++ }
}
# The command exactly as Connect a PC builds it, plus test-only -Port/-NoRegistry.
function Setup([string]$server, [int]$port = 3241, [string]$extra = '') {
  $command = "& ([scriptblock]::Create((irm '$ScriptUrl'))) -Server '$server' -Port $port -NoRegistry $extra; exit `$LASTEXITCODE"
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Restricted -Command $command 2>&1 | ForEach-Object { "$_" })
  $script:lastExit = $LASTEXITCODE
  $script:lastOutput = $output -join "`n"
  $output | ForEach-Object { Write-Host "   | $_" }
}
Write-Host "=== $Step"
switch ($Step) {
  'start' { Others | Set-Content $beforeFile; Write-Host "Other entries: $((Others) -join ' ; ')"; exit 0 }
  'first' {
    Setup $Ip
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'mic attached' ((Attached3241).Count -eq 1)
    Check 'mic remembered' (((Mine) -join ';') -eq "$Ip,3241,2-1,,1")
  }
  'again' {
    Setup $Ip
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'still one attachment' ((Attached3241).Count -eq 1)
  }
  'unplugged' {
    Setup $Ip
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'mic still attached' ((Attached3241).Count -eq 1)
    Check 'mic still remembered' (((Mine) -join ';') -eq "$Ip,3241,2-1,,1")
    Check 'unplugged 1-9 retried in the background' (((Waiting3241) -join ';') -eq "$Ip,3241,1-9")
  }
  'truncated' {
    # The Mac's list is cut off before "end": nothing may change.
    Setup $Ip
    Check 'exit code 1' ($lastExit -eq 1)
    Check 'says nothing was changed' ($lastOutput -match 'Nothing was changed')
    # Restarting the test server dropped the mic's connection; usbip-win2 reattaches
    # it by itself, so only check the script didn't attach or remove anything.
    Check 'attached or removed nothing' ($lastOutput -notmatch 'Connected|Removed')
    Check 'saved entry untouched' (((Mine) -join ';') -eq "$Ip,3241,2-1,,1")
    Check 'waiting 1-9 still tracked' (((Waiting3241) -join ';') -eq "$Ip,3241,1-9")
  }
  'byname' {
    Setup $Name
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'same Mac recognised (no second attachment)' ((Attached3241).Count -eq 1)
    Check 'still exactly one entry for this Mac' ((Mine).Count -eq 1)
    Check 'retry for no-longer-shared 1-9 cancelled' ((Waiting3241).Count -eq 0)
  }
  'unreachable' {
    Setup $Ip 3299
    Check 'exit code 1' ($lastExit -eq 1)
    Check 'mic untouched' ((Attached3241).Count -eq 1)
    Check 'saved entries untouched' ((Mine).Count -eq 1)
  }
  'oldservice' {
    # Runs after 'unplugged': the mic is attached and 1-9 is waiting. An older
    # service can't say what's shared, so nothing may be removed or forgotten.
    Setup $Ip
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'told the Mac service is older' ($lastOutput -match 'The Longcable service on the Mac is older')
    Check 'attach-only: mic still attached' ((Attached3241).Count -eq 1)
    Check 'attach-only: entry kept' (((Mine) -join ';') -eq "$Ip,3241,2-1,,1")
    Check 'attach-only: waiting 1-9 still tracked' (((Waiting3241) -join ';') -eq "$Ip,3241,1-9")
  }
  'autosync' {
    Setup $Ip 3241 '-AutoSync'
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'says it now syncs every minute' ($lastOutput -match 'checks the Mac every minute')
    $task = Get-ScheduledTask -TaskPath '\Longcable\' -TaskName "Sync $Ip 3241" -ErrorAction SilentlyContinue
    Check 'task registered' ($null -ne $task)
    if ($task) {
      $arg = $task.Actions[0].Arguments
      Check 'task runs the local copy quietly for this Mac and port' ($arg -match 'Program Files\\Longcable\\setup-windows.ps1' -and $arg -match "-Server $Ip" -and $arg -match '-Port 3241' -and $arg -match '-Quiet')
      Check 'task runs as the system account' ($task.Principal.UserId -eq 'SYSTEM' -or $task.Principal.UserId -eq 'S-1-5-18')
      Check 'task repeats every minute' (@($task.Triggers | Where-Object { $_.Repetition.Interval -eq 'PT1M' }).Count -eq 1)
      Check 'task also runs at startup and login' (@($task.Triggers).Count -eq 3)
    }
    $copy = Join-Path $env:ProgramFiles 'Longcable\setup-windows.ps1'
    Check 'local copy matches the script' ((Test-Path $copy) -and ((Get-Content -Raw $copy).Trim() -eq (Invoke-RestMethod $ScriptUrl).Trim()))
  }
  'autosyncrun' {
    # The Mac now also shares 1-7 (unplugged). The task, not this command, must follow.
    Start-ScheduledTask -TaskPath '\Longcable\' -TaskName "Sync $Ip 3241"
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not ((Waiting3241) -match ',1-7$')) { Start-Sleep -Seconds 2 }
    Check 'task followed the change on the Mac (1-7 now retried)' ((@(Waiting3241) -match ',1-7$').Count -eq 1)
    # Wait for the run to finish (267009 = still running), then check its result.
    do { Start-Sleep -Seconds 1; $info = Get-ScheduledTaskInfo -TaskPath '\Longcable\' -TaskName "Sync $Ip 3241" }
    while ($info.LastTaskResult -eq 267009 -and (Get-Date) -lt $deadline.AddSeconds(30))
    Check 'task finished without error' ($info.LastTaskResult -eq 0)
    if ($info.LastTaskResult -ne 0) {
      Write-Host "   | task result: $($info.LastTaskResult)"
      $log = Join-Path $env:ProgramData 'Longcable\sync.log'
      if (Test-Path $log) { Get-Content $log -Tail 15 | ForEach-Object { Write-Host "   | log: $_" } }
    }
    Check 'mic still attached' ((Attached3241).Count -eq 1)
  }
  'autosyncremove' {
    Setup $Ip 3241 '-RemoveAutoSync'
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'task removed' ($null -eq (Get-ScheduledTask -TaskPath '\Longcable\' -TaskName "Sync $Ip 3241" -ErrorAction SilentlyContinue))
    Check 'local copy removed' (-not (Test-Path (Join-Path $env:ProgramFiles 'Longcable\setup-windows.ps1')))
    Check 'devices stay as they are' ((Attached3241).Count -eq 1)
  }
  'removeall' {
    Setup $Ip 3241 '-Sync -BusIds @()'
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'manual override: mic detached' ((Attached3241).Count -eq 0)
    Check 'nothing remembered for this Mac' ((Mine).Count -eq 0)
  }
}
$before = @(Get-Content $beforeFile -ErrorAction SilentlyContinue)
Check "other servers' entries unchanged" (((Others) -join ';') -eq ($before -join ';'))
if ($fail -gt 0) { exit 1 }
