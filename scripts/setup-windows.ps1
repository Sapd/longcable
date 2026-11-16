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
    [switch]$NoRegistry
)
$ErrorActionPreference = 'Stop'
function Say([string]$text, [string]$color = '') {
    if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
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
if ($Server -notmatch '^[A-Za-z0-9.\-:\[\]%_]+$') { Fail "That doesn't look like a Mac address: $Server" }
$Server = $Server.Trim('[', ']')
$BusIds = @($BusIds | Where-Object { $_ } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
foreach ($bus in $BusIds) {
    if ($bus -notmatch '^\d+-[\d.]+$') { Fail "Invalid bus ID: $bus" }
}

$usbip = 'C:\Program Files\USBip\usbip.exe'
if (-not (Test-Path $usbip)) {
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
        # Without the full list it can't tell unplugged from removed: attach only,
        # and keep everything else as it is.
        $legacy = $true
        $Sync = $false
        $BusIds = $offered
    } else {
        $reply = $answer.Text
        $body = ($reply -split "`r`n`r`n", 2)[-1]
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
$attached = @(); $already = @(); $waiting = @(); $failed = @(); $removed = @()
foreach ($bus in $BusIds) {
    if (Test-Attached $bus) { $already += $bus; continue }
    $result = Invoke-Usbip ($portArgs + @('attach', '-r', $Server, '-b', $bus, '--receive-mode=low-latency'))
    if (Test-Attached $bus) { $attached += $bus }
    elseif ($offered -notcontains $bus) { $waiting += $bus }
    else { $failed += [pscustomobject]@{ Bus = $bus; Why = $result.Text } }
}

# Devices this script left retrying in the background, so a later run can cancel
# them once the Mac stops sharing them (usbip-win2 can't list pending retries).
$waitingFile = Join-Path $env:ProgramData 'Longcable\waiting.txt'
$waitingBefore = @()
if (Test-Path $waitingFile) { $waitingBefore = @(Get-Content $waitingFile | Where-Object { $_ -match '^(.+),(\d+),(\d+-[\d.]+)$' }) }
$waitingKeep = @()
foreach ($line in $waitingBefore) {
    $null = $line -match '^(.+),(\d+),(\d+-[\d.]+)$'
    $entry = [pscustomobject]@{ Host = $Matches[1]; Port = [int]$Matches[2]; Bus = $Matches[3] }
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
    New-Item -ItemType Directory -Force -Path (Split-Path $waitingFile) | Out-Null
    if ($waitingKeep.Count -gt 0) { Set-Content -Path $waitingFile -Value $waitingKeep -Encoding ASCII }
    elseif (Test-Path $waitingFile) { Remove-Item $waitingFile }
} catch { }

# 3. Detach and stop retrying what this Mac no longer shares.
if ($Sync) {
    foreach ($device in (Get-Attached)) {
        if ((Test-ThisMac $device.Host $device.Port) -and ($BusIds -notcontains $device.Bus)) {
            $result = Invoke-Usbip @('detach', '-p', "$($device.Hub)")
            if ($result.Code -eq 0) { $removed += $device.Bus }
            else { Say "Could not detach $($device.Bus): $($result.Text)" 'Yellow' }
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

# 6. What happened, device by device.
Say ''
foreach ($bus in $attached) { Say "  Connected        $bus" 'Green' }
foreach ($bus in $already) { Say "  Already connected $bus" }
foreach ($bus in $waiting) { Say "  Waiting          $bus  (not plugged in on the Mac; connects by itself when it is)" 'Yellow' }
foreach ($item in $failed) { Say "  Not connected    $($item.Bus)  ($($item.Why))" 'Red' }
foreach ($bus in $removed) { Say "  Removed          $bus  (no longer shared)" }
if ($BusIds.Count -eq 0 -and $removed.Count -eq 0) {
    Say 'Nothing is shared yet. Tick devices in the Longcable app on the Mac, then run this command again.'
}
if ($saved) { Say 'Windows will reconnect these after restarts and dropped connections.' }
if ($legacy) {
    Say 'The Longcable service on the Mac is older, so this only attached devices. Update Longcable on the Mac to also remove devices you stop sharing.' 'Yellow'
} else {
    Say 'After you change what is shared on the Mac, run this same command again.'
}
$global:LASTEXITCODE = [int]($failed.Count -gt 0)
} catch {
    $global:LASTEXITCODE = 1
    if ("$_" -ne 'longcable-stop') { throw }
}
# Run as a file (powershell -File), report success or failure as the exit code.
# Run from memory (the pasted command) there is no file, and exit would close the window.
if ($PSCommandPath) { exit $global:LASTEXITCODE }
