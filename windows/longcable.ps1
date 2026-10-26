# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
param(
    [Parameter(Position=0,Mandatory=$true)]
    [ValidateSet('check','list','attach','detach','port','reconnect','install-reconnect','uninstall-reconnect')][string]$Command,
    [string]$Server='',
    [string]$BusID='',
    [ValidatePattern('^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$')][string]$Device='',
    [ValidateRange(0,65535)][int]$Port=0,
    [string]$BusIDs='auto',
    [ValidateSet('low-latency','zero-copy')][string]$ReceiveMode='low-latency',
    [string]$ClientPath=''
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'client-discovery.ps1')
$taskName='Longcable Reconnect'
$destination=Join-Path $env:ProgramFiles 'Longcable'
function Assert-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run PowerShell as administrator' }
}
if ($Command -eq 'uninstall-reconnect') {
    Assert-Administrator
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    # A bounded native command may still be exiting; retain logs and helper files.
    'Reconnect task removed. Attachments, helper files and logs are preserved.'
    return
}
if (-not $ClientPath) {
    $client=Get-Command usbip.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($client) { $ClientPath=$client.Source }
    else { throw 'Install usbip-win2 and its driver: https://github.com/vadimgrn/usbip-win2/releases . Add usbip.exe to PATH or pass -ClientPath.' }
}
if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf) -or [IO.Path]::GetExtension($ClientPath) -ne '.exe') { throw 'usbip.exe missing: https://github.com/vadimgrn/usbip-win2/releases' }
$clientPath=(Resolve-Path -LiteralPath $ClientPath).Path
if ($Command -in @('list','attach','reconnect','install-reconnect')) {
    $parsed=$null
    if (-not [Net.IPAddress]::TryParse($Server,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Supply -Server with the Mac IPv4 address' }
    # Normalize before interpolating into native command arguments.
    $Server=$parsed.ToString()
}
function Invoke-Checked([string]$arguments) {
    $result=Invoke-Client $arguments
    if ($result.code -ne 0) { throw "usbip.exe failed ($($result.code)): $($result.error) $($result.output)" }
    return $result.output
}
switch ($Command) {
    'check' { Invoke-Checked 'port'; 'usbip.exe and its installed controller responded.' }
    'port' { Invoke-Checked 'port' }
    'list' { Invoke-Checked "list -r $Server" }
    'attach' {
        if (($BusID -ne '') -eq ($Device -ne '')) { throw 'Supply exactly one of -BusID or -Device VID:PID' }
        if ($Device) {
            $listing=Invoke-Checked "list -r $Server"
            $matchesByModel=@()
            foreach ($line in ($listing -split "`r?`n")) {
                if ($line -match ('^\s*(1-(?:[1-9]|1[0-6]))\s+:.*\(' + [Regex]::Escape($Device) + '\)')) { $matchesByModel+=$Matches[1] }
            }
            if ($matchesByModel.Count -ne 1) { throw 'VID:PID must match exactly one exported device; use list and -BusID' }
            $BusID=$matchesByModel[0]
        }
        $null=@(Get-RequestedBusIDs $BusID)
        if ($BusID -eq 'auto' -or $BusID.Contains(',')) { throw 'Choose one bus ID' }
        Invoke-Checked "attach -r $Server -b $BusID --receive-mode=$ReceiveMode --once"
    }
    'detach' {
        if (-not $PSBoundParameters.ContainsKey('Port')) { throw 'Supply -Port from the port command (not the bus ID)' }
        Invoke-Checked "detach -p $Port"
    }
    'reconnect' {
        $null=@(Get-RequestedBusIDs $BusIDs)
        & (Join-Path $PSScriptRoot 'reconnect-client.ps1') -Server $Server -BusIDs $BusIDs -ReceiveMode $ReceiveMode -ClientPath $clientPath
    }
    'install-reconnect' {
        Assert-Administrator
        $null=@(Get-RequestedBusIDs $BusIDs)
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        foreach ($file in @('longcable.ps1','client-discovery.ps1','reconnect-client.ps1')) {
            $source=(Resolve-Path (Join-Path $PSScriptRoot $file)).Path
            $target=Join-Path $destination $file
            if ($source -ne $target) { Copy-Item -LiteralPath $source -Destination $target -Force }
        }
        $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $executable=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments="-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$destination\reconnect-client.ps1`" -Server $Server -BusIDs $BusIDs -ReceiveMode $ReceiveMode -ClientPath `"$clientPath`""
        $action=New-ScheduledTaskAction -Execute $executable -Argument $arguments -WorkingDirectory $destination
        $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $taskName }
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        "Installed $taskName for $user at logon. Log: $destination\reconnect.log"
    }
}
