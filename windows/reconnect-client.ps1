# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9.]+$')][string]$Server,
    [ValidateSet('low-latency','zero-copy')][string]$ReceiveMode='low-latency',
    [ValidatePattern('^(auto|1-[0-9]{1,2}(,1-[0-9]{1,2})*)$')][string]$BusIDs='auto',
    [Parameter(Mandatory=$true)][string]$ClientPath
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'client-discovery.ps1')
$requestedIDs=@(Get-RequestedBusIDs $BusIDs)
$parsed = $null
if (-not [Net.IPAddress]::TryParse($Server,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'An IPv4 server address is required' }
$Server=$parsed.ToString()
if (-not [IO.Path]::IsPathRooted($ClientPath) -or -not (Test-Path -LiteralPath $ClientPath -PathType Leaf)) { throw 'usbip.exe is missing; install https://github.com/vadimgrn/usbip-win2/releases' }
$clientPath=$ClientPath
$mutexName='Local\LongcableReconnect-'+$Server
$mutex = [Threading.Mutex]::new($false,$mutexName)
$owned = $false
$log = Join-Path $PSScriptRoot 'reconnect.log'
function Write-State([string]$state) {
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1048576) {
        if (Test-Path "$log.1") { Remove-Item "$log.1" }
        Move-Item $log "$log.1"
    }
    $line = (Get-Date -Format o) + ' ' + $state
    Add-Content -Encoding UTF8 -Path $log -Value $line
    Write-Output $line
}

try {
    try { $owned=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned=$true }
    if (-not $owned) { exit 0 }
    $lastStates=@{}
    $automatic=$BusIDs -eq 'auto'
    $devices=$requestedIDs
    $nextScan=[DateTime]::MinValue
    $lastDiscoveryError=$null
    while ($true) {
        if($automatic -and [DateTime]::UtcNow -ge $nextScan) {
            try {
                $discovered=Invoke-Client "list -r $Server"
                if($discovered.code -ne 0){throw 'Server unavailable'}
                $devices=@(Get-ExportedBusIDs $discovered.output)
                if($lastDiscoveryError){Write-State 'Server discovery restored'}
                $lastDiscoveryError=$null
            } catch {
                $message='Discovery waiting: '+$_.Exception.Message
                if($message -ne $lastDiscoveryError){Write-State $message; $lastDiscoveryError=$message}
            }
            $nextScan=[DateTime]::UtcNow.AddSeconds(5)
        }
        foreach ($busID in $devices) {
        try {
            $ports=Invoke-Client 'port'
            $connected=$ports.code -eq 0 -and ($ports.output -match ('(?m)^\s*->\s+usbip://' + [Regex]::Escape($Server) + ':3240/' + [Regex]::Escape($busID) + '\s*$'))
            if (-not $connected) {
                $attached=Invoke-Client "attach -r $Server -b $busID --receive-mode=$ReceiveMode --once"
                $connected=$attached.code -eq 0
            }
            $state=if($connected){"connected ($ReceiveMode)"}else{'waiting for server/device'}
        } catch { $state='waiting: ' + $_.Exception.Message }
        if ($state -ne $lastStates[$busID]) { Write-State "$busID $state"; $lastStates[$busID]=$state }
        }
        Start-Sleep -Seconds 2
    }
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
