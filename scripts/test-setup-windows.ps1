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
$stateDir = Join-Path $env:ProgramW6432 'Longcable'
$waitingFile = Join-Path $stateDir 'waiting.txt'
$logFile = Join-Path $stateDir 'sync.log'
$beforeFile = 'C:\Temp\longcable-e2e-before.txt'
function Stashed { @((Get-ItemProperty $stateKey -Name PersistentDevices -ErrorAction SilentlyContinue).PersistentDevices) }
function Mine { @(Stashed | Where-Object { $_ -match ',3241,' }) }
function Others { @(Stashed | Where-Object { $_ -notmatch ',3241,' } | Sort-Object) }
function Attached3241 { @((& 'C:\Program Files\USBip\usbip.exe' port) -match ':3241/') }
function Waiting3241 { if (Test-Path $waitingFile) { @(Get-Content $waitingFile | Where-Object { $_ -match ',3241,' }) } else { @() } }
# The task for this test Mac, found by its arguments (its name carries a hash).
function MyTask { @(Get-ScheduledTask -TaskPath '\Longcable\' -ErrorAction SilentlyContinue |
  Where-Object { $_.Actions[0].Arguments -match "-Server $([regex]::Escape($Ip)) " -and $_.Actions[0].Arguments -match '-Port 3241' }) }
# Runs the task once and waits for it to finish (267009 = still running).
function RunTask {
  $task = @(MyTask)[0]
  Start-ScheduledTask -TaskPath '\Longcable\' -TaskName $task.TaskName
  $deadline = (Get-Date).AddSeconds(90)
  do { Start-Sleep -Seconds 2; $info = Get-ScheduledTaskInfo -TaskPath '\Longcable\' -TaskName $task.TaskName }
  while (($info.LastTaskResult -eq 267009 -or $info.LastRunTime -lt $script:started) -and (Get-Date) -lt $deadline)
  return $info.LastTaskResult
}
$script:started = Get-Date
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
    Setup $Ip 3241 '-AutoSync -Sync'
    Check 'refuses -AutoSync with -Sync' ($lastExit -eq 1 -and @(MyTask).Count -eq 0)
    # A folder ordinary users can write to must be repaired before anything runs from it.
    & icacls.exe $stateDir /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
    Setup $Ip 3241 '-AutoSync'
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'says it now syncs every minute' ($lastOutput -match 'checks the Mac every minute')
    $task = @(MyTask)
    Check 'one task registered' ($task.Count -eq 1)
    if ($task.Count -eq 1) {
      $task = $task[0]
      $arg = $task.Actions[0].Arguments
      Check 'task runs the local copy quietly for this Mac and port' ($arg -match 'Program Files\\Longcable\\setup-windows.ps1' -and $arg -match '-Port 3241' -and $arg -match '-Quiet')
      Check 'task is bound to the identity this Mac reported' ($arg -match '-MacId [0-9a-f]{12}-test')
      Check 'task starts PowerShell by its full path' ($task.Actions[0].Execute -match '^[A-Z]:\\Windows\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$')
      Check 'task runs as the system account' ($task.Principal.UserId -eq 'SYSTEM' -or $task.Principal.UserId -eq 'S-1-5-18')
      Check 'task repeats every minute' (@($task.Triggers | Where-Object { $_.Repetition.Interval -eq 'PT1M' }).Count -eq 1)
      Check 'task also runs at startup and login' (@($task.Triggers).Count -eq 3)
      Check 'task waits for a network' ($task.Settings.RunOnlyIfNetworkAvailable)
    }
    $copy = Join-Path $stateDir 'setup-windows.ps1'
    Check 'local copy matches the script' ((Test-Path $copy) -and ((Get-Content -Raw $copy).Trim() -eq (Invoke-RestMethod $ScriptUrl).Trim()))
    $writers = @((Get-Acl $stateDir).Access | Where-Object {
      $_.AccessControlType -eq 'Allow' -and ([int]$_.FileSystemRights -band 0x500D0156) } |
      ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
    Check 'files in the folder stay readable after the repair' ((Get-Content -Raw $copy) -match 'GET /longcable/v1/shared')
    Check 'only SYSTEM and administrators can change the folder' (@($writers | Where-Object { $_ -notin @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') }).Count -eq 0)
    # A file inside that ordinary users can change must be caught too, not only the folder.
    & icacls.exe $copy /grant '*S-1-5-32-545:M' /Q | Out-Null
    Setup $Ip 3241 '-AutoSync'
    $userWrite = @((Get-Acl $copy).Access | Where-Object { $_.AccessControlType -eq 'Allow' -and
      $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545' -and ([int]$_.FileSystemRights -band 0x500D0156) })
    Check 'a user-writable file inside was repaired' ($userWrite.Count -eq 0)
    $again = ($lastExit -eq 0 -and @(MyTask).Count -eq 1)
    Check 'running it again keeps one task' $again
    if (-not $again) { Write-Host "FAIL detail: exit $lastExit, tasks $(@(MyTask).Count): $($lastOutput -replace "`n", ' / ')" }
  }
  'autosyncrun' {
    # The Mac now also shares 1-7 (unplugged). The task, not this command, must follow.
    $result = RunTask
    Check 'task followed the change on the Mac (1-7 now retried)' ((@(Waiting3241) -match ',1-7$').Count -eq 1)
    Check 'task finished without error' ($result -eq 0)
    if ($result -ne 0) {
      Write-Host "   | task result: $result"
      if (Test-Path $logFile) { Get-Content $logFile -Tail 15 | ForEach-Object { Write-Host "   | log: $_" } }
    }
    Check 'mic still attached' ((Attached3241).Count -eq 1)
  }
  'autosyncwrongmac' {
    # Something else answers at the address now (another id), sharing 1-6 and not 1-7.
    $result = RunTask
    Check 'task reports failure' ($result -eq 1)
    Check 'nothing changed: 1-6 not attached, 1-7 still retried' ((@(Waiting3241) -match ',1-6$').Count -eq 0 -and (@(Waiting3241) -match ',1-7$').Count -eq 1)
    # The test server restarted: usbip-win2 reconnects the mic by itself.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Attached3241).Count -ne 1 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    Check 'mic reconnected by usbip-win2, not by the task' ((Attached3241).Count -eq 1)
    $lines = @(Get-Content $logFile | Where-Object { $_ -match 'Something other than the Mac' })
    Check 'logged once' ($lines.Count -eq 1)
    $null = RunTask
    $lines = @(Get-Content $logFile | Where-Object { $_ -match 'Something other than the Mac' })
    Check 'the same problem again is not logged again' ($lines.Count -eq 1)
  }
  'autosyncremove' {
    Setup $Ip 3241 '-RemoveAutoSync'
    Check 'exit code 0' ($lastExit -eq 0)
    Check 'task removed' (@(MyTask).Count -eq 0)
    Check 'local copy and log removed' (-not (Test-Path (Join-Path $stateDir 'setup-windows.ps1')) -and -not (Test-Path $logFile))
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
