# Copyright 2026 Denis Arnst (Sapd) - https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
#
# Connects this PC to a Longcable Mac. "Connect a PC" in the Longcable app gives you
# the command to run; run the same command again whenever you share, stop sharing or
# add devices on the Mac. The script asks the Mac which devices it shares (including
# unplugged ones) and makes the PC match: it attaches what is missing, keeps trying
# devices that are unplugged, detaches what the Mac no longer shares, and saves the
# list for reconnecting after Windows restarts. Other servers' devices are never touched.
#
#   & ([scriptblock]::Create((irm <release-url>/setup-windows.ps1))) -Server mac
#   ... -Server mac -AutoSync                   # also keep the PC in step every minute
#   ... -Server mac -RemoveAutoSync             # stop that again
#   ... -Server mac -Sync -BusIds '1-1','2-1'   # manual: use exactly this list
#
# Running it from memory like that needs no script file, so the execution policy
# does not matter. The script itself is ASCII only, as irm may decode it as Latin-1.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Server,
    # Use exactly these instead of asking the Mac (manual override).
    [AllowEmptyCollection()][string[]]$BusIds,
    # With -BusIds: it is the Mac's complete list; also detach anything else from this Mac.
    [switch]$Sync,
    [ValidateRange(1, 65535)][int]$Port = 3240,
    # Save the reconnect list even if that forgets remembered devices that aren't connected now.
    [switch]$SaveAnyway,
    [switch]$NoRegistry,
    # Install a Windows scheduled task that runs this sync every minute, at startup
    # and at login (a local copy of this script, as the system account).
    [switch]$AutoSync,
    # Remove that task again; devices stay as they are.
    [switch]$RemoveAutoSync,
    # Used by the task: no screen output, notable runs go to the log file.
    [switch]$Quiet,
    # Used by the task: the identity the Mac reported when AutoSync was set up. A
    # different answer at the same address (another network, another device) is ignored.
    [string]$MacId
)
# This script's own text, to install it for AutoSync (also when run from memory).
$selfText = $MyInvocation.MyCommand.ScriptBlock.ToString()
$ErrorActionPreference = 'Stop'
$logLines = New-Object System.Collections.Generic.List[string]
function Say([string]$text, [string]$color = '') {
    if ($Quiet) { $logLines.Add($text); return }
    if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
}
# Everything this script keeps on the PC lives in one folder that only administrators
# and the system can change: the copy the task runs, the log, and the retry list. The
# task runs as SYSTEM, so none of it may be writable by ordinary users.
$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$stateDir = Join-Path $programFiles 'Longcable'
$installedScript = Join-Path $stateDir 'setup-windows.ps1'
$logFile = Join-Path $stateDir 'sync.log'
$lastRunFile = Join-Path $stateDir 'last-run.txt'
$waitingFile = Join-Path $stateDir 'waiting.txt'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskFolder = '\Longcable\'
function Get-LongcableTasks { @(Get-ScheduledTask -TaskPath $taskFolder -ErrorAction SilentlyContinue) }
# The folder and everything in it: writable only by SYSTEM, Administrators or
# TrustedInstaller, owned by one of them, and no links. Repairs the permissions if
# needed; fails if it can't. Nothing is written to the folder before this passes.
$state = @{ Safe = $false }
function Assert-SafeFolder {
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    # Rights that change something: write data, append, extended attributes, delete children,
    # attributes, delete, change permissions, take ownership, generic all and generic write.
    $writeRights = 0x500D0156
    function Test-SafeItem($item) {
        $acl = Get-Acl -LiteralPath $item.FullName
        try { $owner = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $false }
        if ($trusted -notcontains $owner) { return $false }
        foreach ($rule in $acl.Access) {
            if ($rule.AccessControlType -ne 'Allow' -or -not ([int]$rule.FileSystemRights -band $writeRights)) { continue }
            try { $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $false }
            if ($trusted -notcontains $sid) { return $false }
        }
        return $true
    }
    function Get-Links { @(@(Get-Item -LiteralPath $stateDir -Force) + @(Get-ChildItem -LiteralPath $stateDir -Force -Recurse -Attributes ReparsePoint)) |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } }
    function Test-Safe {
        if (@(Get-Links).Count -gt 0) { return $false }
        foreach ($item in @(@(Get-Item -LiteralPath $stateDir -Force) + @(Get-ChildItem -LiteralPath $stateDir -Force -Recurse))) {
            if (-not (Test-SafeItem $item)) { return $false }
        }
        return $true
    }
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
    if (Test-Safe) { $state.Safe = $true; return }
    $links = @(Get-Links)
    if ($links.Count -gt 0) {
        Fail "$stateDir is or contains a link ($($links[0].FullName)), which nothing here creates. Delete it, then run the command again."
    }
    # The folder gets fixed permissions; what is inside goes back to inheriting them.
    & icacls.exe $stateDir /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    & icacls.exe $stateDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
    if (Get-ChildItem -LiteralPath $stateDir -Force) { & icacls.exe (Join-Path $stateDir '*') /reset /T /C /Q | Out-Null }
    if (-not (Test-Safe)) { Fail "Could not make $stateDir writable only by administrators. Nothing was changed." }
    $state.Safe = $true
}
# Writes a file in the safe folder via a temporary file, so a reader never sees half of it.
function Write-StateFile([string]$path, [string[]]$lines) {
    if (-not $state.Safe) { throw "$stateDir is not protected" }
    $temp = "$path.new"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    Set-Content -LiteralPath $temp -Value $lines -Encoding ASCII
    Move-Item -LiteralPath $temp -Destination $path -Force
}
# Quiet runs log what changed or failed; the same problem every minute is logged once.
function Write-Log {
    if (-not $Quiet -or -not $state.Safe) { return }
    try {
        $summary = ($logLines -join ' | ')
        $last = if (Test-Path -LiteralPath $lastRunFile) { (Get-Content -LiteralPath $lastRunFile -Raw).Trim() } else { '' }
        if ($summary -eq $last) { return }
        Write-StateFile $lastRunFile @($summary)
        if ($logLines.Count -eq 0) { return }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $old = @(if (Test-Path -LiteralPath $logFile) { Get-Content -LiteralPath $logFile -Tail 400 })
        Write-StateFile $logFile ($old + @($logLines | Where-Object { "$_".Trim() } | ForEach-Object { "$stamp  $_" }))
    } catch { }
}
# Stops the script without 'exit': run from memory in an interactive console,
# 'exit' would close the window before the message can be read.
function Fail([string]$text) {
    Say $text 'Red'
    throw 'longcable-stop'
}
try {

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'Please open PowerShell or Windows Terminal "as administrator" (right-click it), then paste the command again.'
}
$addressPattern = '^[A-Za-z0-9.\-:\[\]%_]+$'
if ($Server -notmatch $addressPattern) { Fail "That doesn't look like a Mac address: $Server" }
$Server = $Server.Trim('[', ']')
if ($MacId -and $MacId -notmatch '^[A-Za-z0-9-]{1,64}$') { Fail 'Invalid -MacId.' }
if ($AutoSync -and ($Sync -or $PSBoundParameters.ContainsKey('BusIds'))) {
    Fail '-AutoSync follows what the Mac shares, so it cannot be combined with -Sync or -BusIds.'
}
Assert-SafeFolder
# One run at a time (a manual run and the task, or tasks for two Macs). The lock is a
# file in the protected folder, so ordinary users can't hold it to block syncing.
$lock = $null
$lockDeadline = (Get-Date).AddSeconds($(if ($Quiet) { 0 } else { 60 }))
while (-not $lock) {
    try {
        $lock = [IO.File]::Open((Join-Path $stateDir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [System.IO.IOException] {
        if ((Get-Date) -ge $lockDeadline) {
            if ($Quiet) { $logLines.Clear(); throw 'longcable-busy' }
            Fail 'Another Longcable setup is running on this PC. Try again in a minute.'
        }
        Start-Sleep -Milliseconds 500
    }
}
$BusIds = @($BusIds | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
foreach ($bus in $BusIds) {
    if ($bus -notmatch '^\d+-[\d.]+$') { Fail "Invalid bus ID: $bus" }
}

$usbip = Join-Path $programFiles 'USBip\usbip.exe'
if (-not (Test-Path $usbip)) {
    # The task never installs software; only a run started by a person does.
    if ($Quiet) { Fail "usbip-win2 is not installed ($usbip). Nothing was changed." }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail 'Please install usbip-win2 from https://github.com/vadimgrn/usbip-win2/releases, then run the command again.'
    }
    Say 'Installing usbip-win2...'
    & winget install --id vadimgrn.usbip-win2 -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $usbip)) {
        Fail 'Installing usbip-win2 did not finish. If Windows asks to restart, do that, then run the command again.'
    }
}

# Runs usbip without letting Windows PowerShell 5.1 turn stderr text into errors.
# Returns the exit code and all output lines as plain text.
function Invoke-Usbip([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $lines = @(& $usbip @Arguments 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines; Text = ($lines -join ' ').Trim() }
}
$portArgs = if ($Port -ne 3240) { @('--tcp-port', "$Port") } else { @() }

# The same Mac can be reached by IP or by name (for example Tailscale MagicDNS).
function Normalize([string]$name) { ($name.Trim('[', ']') -replace '%.*$', '').ToLowerInvariant() }
function Resolve-Addresses([string]$name) {
    $name = Normalize $name
    $found = @($name)
    try { $found += @([System.Net.Dns]::GetHostAddresses($name) | ForEach-Object { Normalize $_.IPAddressToString }) } catch { }
    return $found
}
$serverAddresses = Resolve-Addresses $Server
$sameHostCache = @{}
function Test-ThisMac([string]$name, [int]$servicePort) {
    if ($servicePort -ne $Port) { return $false }
    if (-not $sameHostCache.ContainsKey($name)) {
        $sameHostCache[$name] = [bool](Resolve-Addresses $name | Where-Object { $serverAddresses -contains $_ })
    }
    return $sameHostCache[$name]
}

# The task's own -Server/-Port, read back from its arguments.
function Get-TaskTarget($task) {
    $arguments = "$($task.Actions[0].Arguments)"
    $server = if ($arguments -match '-Server\s+(\S+)') { $Matches[1] } else { '' }
    $port = if ($arguments -match '-Port\s+(\d+)') { [int]$Matches[1] } else { 3240 }
    return [pscustomobject]@{ Server = $server; Port = $port }
}
if ($RemoveAutoSync) {
    # Found by what the task points at, so the Mac's other name or address works too.
    $mine = @(Get-LongcableTasks | Where-Object { $t = Get-TaskTarget $_; $t.Server -and (Test-ThisMac $t.Server $t.Port) })
    foreach ($task in $mine) {
        Stop-ScheduledTask -TaskPath $taskFolder -TaskName $task.TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskPath $taskFolder -TaskName $task.TaskName -Confirm:$false
    }
    if ($mine.Count -gt 0) { Say "Stopped keeping this PC in step with $Server automatically. Devices stay as they are." }
    else { Say "This PC wasn't kept in step with $Server automatically." }
    $others = @(Get-LongcableTasks)
    if ($others.Count -gt 0) {
        Say ('Still syncing automatically with: ' + (($others | ForEach-Object { (Get-TaskTarget $_).Server }) -join ', ') +
            '. Run this command with that address to stop it too.')
    } else {
        foreach ($file in @($installedScript, $logFile, $lastRunFile)) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
    }
    $global:LASTEXITCODE = 0
    return
}

# Attached devices: "Port NN: ..." followed by "-> usbip://HOST:PORT/BUSID".
function Get-Attached {
    $result = @()
    $hub = $null
    foreach ($line in (Invoke-Usbip @('port')).Lines) {
        if ($line -match '^Port (\d+):') { $hub = [int]$Matches[1] }
        elseif ($line -match '->\s*usbip://(.+):(\d+)/(\d+-[\d.]+)\s*$' -and $null -ne $hub) {
            $result += [pscustomobject]@{ Hub = $hub; Host = $Matches[1]; Port = [int]$Matches[2]; Bus = $Matches[3] }
        }
    }
    return $result
}
function Test-Attached([string]$bus) {
    [bool](Get-Attached | Where-Object { $_.Bus -eq $bus -and (Test-ThisMac $_.Host $_.Port) })
}

# 1. Is the Mac there? Nothing is attached, detached or saved if it isn't.
$listing = Invoke-Usbip ($portArgs + @('list', '-r', $Server))
if ($listing.Code -ne 0) {
    Fail ("Can't reach the Mac at $Server. Is Longcable running there, and is this PC on the same network or " +
          "Tailscale? If the Mac shows this PC with an Allow button, click it, then run the command again.`n" +
          "usbip said: $($listing.Text)")
}
$offered = @($listing.Lines | ForEach-Object { if ($_ -match '^\s*(\d+-[\d.]+)\s*:') { $Matches[1] } } | Select-Object -Unique)

# Ask the Mac which devices it shares, plugged in or not (GET /longcable/v1/shared on
# the USB/IP port). A raw socket, so no proxy settings get in the way.
# Result: Kind 'ok' (Text = reply), 'legacy' (the service closed without answering:
# a Longcable from before the list), or 'error' (couldn't talk to it; Why says why).
function Get-SharedList {
    # The service listens on IPv4; prefer an IPv4 address for names.
    $target = $Server
    try {
        $v4 = @([System.Net.Dns]::GetHostAddresses($Server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })
        if ($v4.Count -gt 0) { $target = $v4[0].IPAddressToString }
    } catch { }
    $client = New-Object System.Net.Sockets.TcpClient
    $memory = New-Object IO.MemoryStream
    $phase = 'connect'
    try {
        if (-not $client.ConnectAsync($target, $Port).Wait(5000)) {
            return [pscustomobject]@{ Kind = 'error'; Why = "no connection to ${target}:$Port within 5 s" }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000; $stream.WriteTimeout = 5000
        $phase = 'send'
        $request = [Text.Encoding]::ASCII.GetBytes("GET /longcable/v1/shared HTTP/1.0`r`nHost: longcable`r`n`r`n")
        $stream.Write($request, 0, $request.Length)
        $phase = 'read'
        $buffer = New-Object byte[] 4096
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $memory.Write($buffer, 0, $count)
            if ($memory.Length -gt 65536) { break }
        }
    } catch {
        # An older service closes right after reading "GET ", so the PC sees a
        # connection reset while waiting for the reply, before any byte. Judged by
        # the socket error code, not by the (translated) message. Anything else -
        # no connection, a timeout, a reset after part of the reply - is an error.
        $code = $null
        $inner = $_.Exception
        while ($inner) {
            if ($inner -is [System.Net.Sockets.SocketException]) { $code = "$($inner.SocketErrorCode)"; break }
            $inner = $inner.InnerException
        }
        if (-not ($phase -eq 'read' -and $memory.Length -eq 0 -and $code -eq 'ConnectionReset')) {
            $why = $_.Exception.Message
            if ($_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
            if ($code) { $why = "$why [$code]" }
            return [pscustomobject]@{ Kind = 'error'; Why = $why }
        }
    } finally { $client.Close() }
    if ($memory.Length -eq 0) { return [pscustomobject]@{ Kind = 'legacy' } }
    return [pscustomobject]@{ Kind = 'ok'; Text = [Text.Encoding]::ASCII.GetString($memory.ToArray()) }
}
$legacy = $false
if (-not $PSBoundParameters.ContainsKey('BusIds')) {
    $answer = Get-SharedList
    if ($answer.Kind -eq 'error') { Start-Sleep -Seconds 1; $answer = Get-SharedList }
    if ($answer.Kind -eq 'error') {
        Fail "Couldn't get the list of shared devices from the Mac ($($answer.Why)). Nothing was changed. Check the connection, then run the command again."
    }
    if ($answer.Kind -eq 'legacy') {
        if ($MacId -or $AutoSync) {
            Fail 'The Longcable service on the Mac is older and cannot be synced automatically. Update Longcable on the Mac, then run the command again. Nothing was changed.'
        }
        # Without the full list it can't tell unplugged from removed: attach only,
        # and keep everything else as it is.
        $legacy = $true
        $Sync = $false
        $BusIds = $offered
    } else {
        $reply = $answer.Text
        $head, $body = $reply -split "`r`n`r`n", 2
        $replyId = if ($head -match '(?m)^X-Longcable-Id:\s*([A-Za-z0-9-]{1,64})\s*$') { $Matches[1] } else { '' }
        if ($MacId -and $replyId -ne $MacId) {
            Fail "Something other than the Mac this PC was set up with answered at $Server (reported '$replyId'). Nothing was changed."
        }
        $lines = @($body -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $valid = $reply.StartsWith('HTTP/1.0 200') -and $lines.Count -ge 2 -and $lines[0] -eq 'longcable 1' -and $lines[-1] -eq 'end'
        # Between the header and "end"; 1..0 would count down in PowerShell.
        $ids = @(if ($valid -and $lines.Count -gt 2) { $lines[1..($lines.Count - 2)] })
        if (-not $valid -or ($ids | Where-Object { $_ -notmatch '^\d+-[\d.]+$' })) {
            Fail 'The Mac sent an answer this script does not understand. Nothing was changed. Update Longcable on the Mac (or copy the command from Connect a PC again), then run it.'
        }
        $Sync = $true
        $BusIds = @($ids | Select-Object -Unique)
    }
}

# 2. Attach what is shared. A shared device the Mac doesn't offer right now is
#    unplugged: usbip-win2 keeps trying it, so it connects once it's plugged in.
# Retries this script already started (see waiting.txt below): don't start another.
# Retries end with a restart of Windows, so the list only counts for the current boot.
$bootId = 'boot ' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('yyyyMMddHHmmss')
function Read-Waiting {
    @(if (Test-Path -LiteralPath $waitingFile) {
        $lines = @(Get-Content -LiteralPath $waitingFile)
        if ($lines.Count -gt 0 -and $lines[0] -eq $bootId) { $lines | Select-Object -Skip 1 | ForEach-Object {
            if ($_ -match '^([^,]+),(\d{1,5}),(\d+-[\d.]+)$') {
                $entry = [pscustomobject]@{ Line = $_; Host = $Matches[1]; Port = [int]$Matches[2]; Bus = $Matches[3] }
                if ($entry.Host -match $addressPattern -and $entry.Host -notmatch '^-') { $entry }
            }
        } }
    })
}
$waitingEntries = Read-Waiting
$retrying = @($waitingEntries | Where-Object { Test-ThisMac $_.Host $_.Port } | ForEach-Object { $_.Bus })
$attached = @(); $already = @(); $waiting = @(); $failed = @(); $removed = @()
foreach ($bus in $BusIds) {
    if (Test-Attached $bus) { $already += $bus; continue }
    if ($offered -notcontains $bus -and $retrying -contains $bus) { $waiting += $bus; continue }
    $result = Invoke-Usbip ($portArgs + @('attach', '-r', $Server, '-b', $bus, '--receive-mode=low-latency'))
    if (Test-Attached $bus) { $attached += $bus }
    elseif ($offered -notcontains $bus) { $waiting += $bus }
    else { $failed += [pscustomobject]@{ Bus = $bus; Why = $result.Text } }
}

# Devices this script left retrying in the background, so a later run can cancel
# them once the Mac stops sharing them (usbip-win2 can't list pending retries).
$waitingKeep = @()
foreach ($entry in $waitingEntries) {
    $line = $entry.Line
    if (-not (Test-ThisMac $entry.Host $entry.Port)) { $waitingKeep += $line; continue }
    # Without the Mac's full list, keep tracking every retry as it is.
    if (-not $Sync) {
        # Connected now (or re-added below): no longer waiting.
        if ($waiting -notcontains $entry.Bus -and $attached -notcontains $entry.Bus -and $already -notcontains $entry.Bus) { $waitingKeep += $line }
        continue
    }
    if ($BusIds -notcontains $entry.Bus) {
        $null = Invoke-Usbip (@('--tcp-port', "$($entry.Port)", 'attach', '--stop', '-r', $entry.Host, '-b', $entry.Bus))
    }
}
$waitingKeep += @($waiting | ForEach-Object { "$Server,$Port,$_" })
try {
    if ($waitingKeep.Count -gt 0) { Write-StateFile $waitingFile (@($bootId) + $waitingKeep) }
    elseif (Test-Path -LiteralPath $waitingFile) { Remove-Item -LiteralPath $waitingFile }
} catch { }

# 3. Detach and stop retrying what this Mac no longer shares.
if ($Sync) {
    foreach ($device in (Get-Attached)) {
        if ((Test-ThisMac $device.Host $device.Port) -and ($BusIds -notcontains $device.Bus)) {
            $result = Invoke-Usbip @('detach', '-p', "$($device.Hub)")
            if ($result.Code -eq 0) { $removed += $device.Bus }
            else { $failed += [pscustomobject]@{ Bus = $device.Bus; Why = "could not detach: $($result.Text)" } }
        }
    }
}

# 4. Save the list usbip-win2 reattaches after restarts and dropped connections.
#    'usbip port --stash' saves exactly the devices attached right now, and only
#    usbip-win2's driver can write that list. So don't save if that would forget a
#    device that is still wanted but not connected (unplugged, or from another server).
$stashedRun = Invoke-Usbip @('list', '--stashed')
$stashed = @(); $unreadable = $false
foreach ($line in $stashedRun.Lines) {
    if (-not $line.Trim()) { continue }
    if ($line -match '^(.+):(\d+)/(\d+-[\d.]+),') {
        $stashed += [pscustomobject]@{ Host = $Matches[1]; Port = [int]$Matches[2]; Bus = $Matches[3] }
    } else { $unreadable = $true }
}
$attachedNow = Get-Attached
$wouldForget = @($stashed | Where-Object {
    $entry = $_
    $isAttached = [bool]($attachedNow | Where-Object { $_.Bus -eq $entry.Bus -and (Normalize $_.Host) -eq (Normalize $entry.Host) -and $_.Port -eq $entry.Port })
    $mine = Test-ThisMac $entry.Host $entry.Port
    # Attach-only (no full list): forget nothing that isn't connected right now.
    -not $isAttached -and (-not $mine -or -not $Sync -or ($BusIds -contains $entry.Bus))
})
if ($Sync) {
    # Stop background retries for this Mac's devices that are no longer shared.
    foreach ($entry in $stashed) {
        if ((Test-ThisMac $entry.Host $entry.Port) -and ($BusIds -notcontains $entry.Bus)) {
            $null = Invoke-Usbip (@('--tcp-port', "$($entry.Port)", 'attach', '--stop', '-r', $entry.Host, '-b', $entry.Bus))
        }
    }
}
$saved = $false
if ($stashedRun.Code -ne 0 -or $unreadable) {
    Say 'Did not update the reconnect list: could not read the current one from usbip-win2.' 'Yellow'
} elseif ($wouldForget.Count -gt 0 -and -not $SaveAnyway) {
    Say ("Did not update the reconnect list, so it keeps remembering these devices that aren't connected right now: " +
         (($wouldForget | ForEach-Object { "$($_.Bus) on $($_.Host)" }) -join ', ') + '.') 'Yellow'
    Say 'Everything above is connected for now. Run the command again once they are plugged in (or add -SaveAnyway to forget them).'
} else {
    $result = Invoke-Usbip @('port', '--stash')
    if ($result.Code -eq 0) { $saved = $true } else { Say "Could not save the reconnect list: $($result.Text)" 'Yellow' }
}

# 5. Retry settings for usbip-win2's automatic reconnect.
if (-not $NoRegistry) {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\usbip2_ude\Parameters'
    $old = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($old.ReattachMaxAttempts -ne 1000 -or $old.ReattachFirstDelay -ne 5) {
        if (-not (Test-Path $key)) { New-Item -Path $key | Out-Null }
        New-ItemProperty -Path $key -Name ReattachMaxAttempts -Value 1000 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $key -Name ReattachFirstDelay -Value 5 -PropertyType DWord -Force | Out-Null
        Say 'Turned on automatic reconnecting (usbip-win2 retry settings). Restart Windows once to apply it.'
    }
}

# 6. Keep the PC in step automatically (opt-in). The task runs a copy of this script
#    from the admin-only folder, as SYSTEM, and only acts for the Mac identity seen now.
$autoSyncOn = $false
$autoSyncFailed = $false
if ($AutoSync) {
    try {
        if (-not $replyId) { throw 'the Mac did not report its identity (update Longcable on the Mac)' }
        if (-not $selfText -or $selfText -notmatch 'GET /longcable/v1/shared') { throw 'could not read this script to install it' }
        Write-StateFile $installedScript @($selfText)
        if ((Get-Content -LiteralPath $installedScript -Raw).Trim() -ne $selfText.Trim()) { throw 'the installed copy does not match' }
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$installedScript`"", '-Server', $Server, '-Quiet', '-MacId', $replyId)
        if ($Port -ne 3240) { $arguments += @('-Port', "$Port") }
        if ($NoRegistry) { $arguments += '-NoRegistry' }
        $action = New-ScheduledTaskAction -Execute $powershellExe -Argument ($arguments -join ' ')
        $triggers = @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -AtLogOn),
            (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
            -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable
        # One task per Mac: replace any task already pointing at it (also under another name).
        foreach ($task in @(Get-LongcableTasks | Where-Object { $t = Get-TaskTarget $_; $t.Server -and (Test-ThisMac $t.Server $t.Port) })) {
            Unregister-ScheduledTask -TaskPath $taskFolder -TaskName $task.TaskName -Confirm:$false
        }
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::ASCII.GetBytes("$Server|$Port"))).Replace('-', '').Substring(0, 8)
        $taskName = 'Sync ' + ($Server -replace '[^A-Za-z0-9.\-]', '-') + " $Port $hash"
        Register-ScheduledTask -TaskPath $taskFolder -TaskName $taskName -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings -Force | Out-Null
        $autoSyncOn = $true
    } catch {
        $autoSyncFailed = $true
        Say "Automatic syncing was not set up: $($_.Exception.Message)" 'Red'
    }
}

# 7. What happened, device by device.
Say ''
foreach ($bus in $attached) { Say "  Connected        $bus" 'Green' }
foreach ($bus in $already) { Say "  Already connected $bus" }
foreach ($bus in $waiting) { Say "  Waiting          $bus  (not plugged in on the Mac; connects by itself when it is)" 'Yellow' }
foreach ($item in $failed) { Say "  Not connected    $($item.Bus)  ($($item.Why))" 'Red' }
foreach ($bus in $removed) { Say "  Removed          $bus  (no longer shared)" }
if ($BusIds.Count -eq 0 -and $removed.Count -eq 0) {
    Say 'Nothing is shared yet. Tick devices in the Longcable app on the Mac, then run this command again.'
}
if ($saved -and -not $Quiet) { Say 'Windows will reconnect these after restarts and dropped connections.' }
if ($autoSyncOn) {
    Say 'This PC now checks the Mac every minute (and at startup and login) and follows its changes by itself.' 'Green'
    Say "It skips runs when a different Mac answers at $Server. Log: $logFile"
    Say 'To stop it, run the same command with -RemoveAutoSync instead of -AutoSync. Run it with -AutoSync again to update it.'
} elseif ($Quiet) {
} elseif ($legacy) {
    Say 'The Longcable service on the Mac is older, so this only attached devices. Update Longcable on the Mac to also remove devices you stop sharing.' 'Yellow'
} else {
    Say 'After you change what is shared on the Mac, run this same command again.'
}
# Quiet runs only log when something happened.
if ($Quiet -and ($attached.Count + $removed.Count + $failed.Count) -eq 0) { $logLines.Clear() }
Write-Log
$global:LASTEXITCODE = [int]($failed.Count -gt 0 -or $autoSyncFailed)
} catch {
    if ("$_" -eq 'longcable-busy') { $global:LASTEXITCODE = 0 }
    else {
        $global:LASTEXITCODE = 1
        if ($Quiet) { if ("$_" -ne 'longcable-stop') { $logLines.Add("Error: $_") }; Write-Log }
        if ("$_" -ne 'longcable-stop') { throw }
    }
} finally {
    if ($lock) { $lock.Dispose() }
}
# Run as a file (powershell -File), report success or failure as the exit code.
# Run from memory (the pasted command) there is no file, and exit would close the window.
if ($PSCommandPath) { exit $global:LASTEXITCODE }
