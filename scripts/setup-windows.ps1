# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Server,
    [string[]]$BusIds,
    [switch]$NoRegistry
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator, then run this script again.'
}
$usbip = 'C:\Program Files\USBip\usbip.exe'
if (-not (Test-Path $usbip)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'Install usbip-win2 from https://github.com/vadimgrn/usbip-win2/releases then run this script again (winget is unavailable).'
    }
    & winget install --id vadimgrn.usbip-win2 -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $usbip)) { throw 'usbip-win2 installation failed. Restart Windows if the driver installer requests it, then retry.' }
}
function Invoke-Usbip {
    param([string[]]$Arguments)
    $output = & $usbip @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "usbip $Arguments failed: $output" }
    return $output
}
if (-not $BusIds -or $BusIds.Count -eq 0) {
    $listing = Invoke-Usbip -Arguments @('list', '-r', $Server)
    $BusIds = @($listing | ForEach-Object {
        if ("$_" -match '^\s*(\d+-[\d.]+)\s*:') { $Matches[1] }
    } | Select-Object -Unique)
}
$ports = (Invoke-Usbip -Arguments @('port')) -join "`n"
$attached = 0
$skipped = 0
foreach ($bus in $BusIds) {
    if ($bus -notmatch '^\d+-[\d.]+$') { throw "Invalid bus ID: $bus" }
    # usbip port identifies the remote endpoint as usbip://SERVER:3240/BUSID.
    $endpoint = 'usbip://' + $Server + ':3240/' + $bus
    if ($ports -match ([regex]::Escape($endpoint) + '(?=\s|$)')) {
        Write-Host "Already attached: $bus"
        $skipped++
        continue
    }
    Invoke-Usbip -Arguments @('attach', '-r', $Server, '-b', $bus, '--receive-mode=low-latency') | Out-Host
    $attached++
}
Invoke-Usbip -Arguments @('port', '--stash') | Out-Host
if (-not $NoRegistry) {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\usbip2_ude\Parameters'
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name ReattachMaxAttempts -Value 1000 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name ReattachFirstDelay -Value 5 -PropertyType DWord -Force | Out-Null
    Write-Host 'Retry settings saved. Reboot Windows to apply them.'
}
Write-Host "Server $Server : $attached attached, $skipped already attached; devices stashed for reconnection."
if ($BusIds.Count -eq 0) { Write-Host 'No devices listed. Tick devices in Longcable and click Allow on the Mac if prompted, then run this script again.' }
