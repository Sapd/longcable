# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
# Attaches Longcable Mic, checks Device Manager, records a clip, detaches it again.
# Only ever detaches the port it attached. Needs usbip-win2; installs nothing.
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [int]$Port = 3240,
    [string]$Bus = '2-1',
    [int]$Seconds = 5,
    [string]$Out = 'C:\Temp\longcable-mic.wav',
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
$usbip = 'C:\Program Files\USBip\usbip.exe'
if (-not (Test-Path $usbip)) { throw "usbip-win2 not found at $usbip" }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
public static class LongcableWaveIn {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct WAVEINCAPS { public short wMid, wPid; public int vDriverVersion;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
    public int dwFormats; public short wChannels, wReserved1; }
  [StructLayout(LayoutKind.Sequential)]
  struct WAVEFORMATEX { public short wFormatTag, nChannels; public int nSamplesPerSec, nAvgBytesPerSec;
    public short nBlockAlign, wBitsPerSample, cbSize; }
  [StructLayout(LayoutKind.Sequential)]
  struct WAVEHDR { public IntPtr lpData; public int dwBufferLength, dwBytesRecorded; public IntPtr dwUser;
    public int dwFlags, dwLoops; public IntPtr lpNext, reserved; }
  [DllImport("winmm.dll")] static extern int waveInGetNumDevs();
  [DllImport("winmm.dll", CharSet = CharSet.Unicode, EntryPoint = "waveInGetDevCapsW")]
  static extern int waveInGetDevCaps(IntPtr id, ref WAVEINCAPS caps, int size);
  [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, IntPtr id, ref WAVEFORMATEX f, IntPtr cb, IntPtr inst, int flags);
  [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, int size);
  [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, int size);
  [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, int size);
  [DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
  [DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
  [DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);

  public static string[] Devices() {
    int n = waveInGetNumDevs();
    var names = new string[n];
    for (int i = 0; i < n; i++) {
      var caps = new WAVEINCAPS();
      waveInGetDevCaps((IntPtr)i, ref caps, Marshal.SizeOf(caps));
      names[i] = caps.szPname;
    }
    return names;
  }

  public static int Record(int id, int seconds, string path) {
    string[] names = Devices();
    if (id < 0 || id >= names.Length) throw new Exception("No recording device " + id + ": " + string.Join(", ", names));
    var f = new WAVEFORMATEX { wFormatTag = 1, nChannels = 1, nSamplesPerSec = 48000,
      nAvgBytesPerSec = 96000, nBlockAlign = 2, wBitsPerSample = 16, cbSize = 0 };
    IntPtr h;
    int r = waveInOpen(out h, (IntPtr)id, ref f, IntPtr.Zero, IntPtr.Zero, 0);
    if (r != 0) throw new Exception("waveInOpen failed: " + r);
    int length = seconds * 96000;
    IntPtr data = Marshal.AllocHGlobal(length);
    var hdr = new WAVEHDR { lpData = data, dwBufferLength = length };
    int hsize = Marshal.SizeOf(hdr);
    IntPtr ph = Marshal.AllocHGlobal(hsize);
    Marshal.StructureToPtr(hdr, ph, false);
    try {
      if ((r = waveInPrepareHeader(h, ph, hsize)) != 0) throw new Exception("prepare failed: " + r);
      if ((r = waveInAddBuffer(h, ph, hsize)) != 0) throw new Exception("add buffer failed: " + r);
      if ((r = waveInStart(h)) != 0) throw new Exception("start failed: " + r);
      var deadline = DateTime.UtcNow.AddSeconds(seconds + 5);
      while ((((WAVEHDR)Marshal.PtrToStructure(ph, typeof(WAVEHDR))).dwFlags & 1) == 0 && DateTime.UtcNow < deadline)
        Thread.Sleep(50);
      waveInReset(h);
      var done = (WAVEHDR)Marshal.PtrToStructure(ph, typeof(WAVEHDR));
      waveInUnprepareHeader(h, ph, hsize);
      var pcm = new byte[done.dwBytesRecorded];
      Marshal.Copy(data, pcm, 0, pcm.Length);
      using (var w = new BinaryWriter(File.Create(path))) {
        w.Write(new[] { (byte)'R', (byte)'I', (byte)'F', (byte)'F' }); w.Write(36 + pcm.Length);
        w.Write(new[] { (byte)'W', (byte)'A', (byte)'V', (byte)'E', (byte)'f', (byte)'m', (byte)'t', (byte)' ' });
        w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(48000); w.Write(96000);
        w.Write((short)2); w.Write((short)16);
        w.Write(new[] { (byte)'d', (byte)'a', (byte)'t', (byte)'a' }); w.Write(pcm.Length); w.Write(pcm);
      }
      return pcm.Length;
    } finally {
      waveInClose(h);
      Marshal.FreeHGlobal(ph);
      Marshal.FreeHGlobal(data);
    }
  }
}
'@

function Get-OwnPort {
    $text = (& $usbip port 2>&1) -join "`n"
    $pattern = "Port (\d+):[^\n]*\n(?:[^\n]*\n){0,2}?\s*-> usbip://$([regex]::Escape($Server)):$Port/$([regex]::Escape($Bus))"
    $m = [regex]::Match($text, $pattern)
    if ($m.Success) { return [int]$m.Groups[1].Value } else { return $null }
}

# Recording devices before the attach: the one this check adds is the new entry,
# even when another Longcable Mic is attached already.
$before = [LongcableWaveIn]::Devices()
$own = Get-OwnPort
# Never detach an attachment that was there before (someone may be in a call).
$attachedHere = $null -eq $own
if ($attachedHere) {
    & $usbip --tcp-port $Port attach -r $Server -b $Bus --receive-mode=low-latency | Out-Host
    for ($i = 0; $i -lt 20 -and $null -eq $own; $i++) { Start-Sleep -Milliseconds 500; # Recording devices before the attach: the one this check adds is the new entry,
# even when another Longcable Mic is attached already.
$before = [LongcableWaveIn]::Devices()
$own = Get-OwnPort }
    if ($null -eq $own) { throw "Attach of $Bus from ${Server}:$Port did not show up in 'usbip port'" }
}
Write-Host "ATTACHED port $own"
try {
    $device = $null
    for ($i = 0; $i -lt 30; $i++) {
        $device = Get-PnpDevice -FriendlyName '*Longcable*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Present }
        if ($device -and ($device | Where-Object { $_.Status -eq 'OK' })) { break }
        Start-Sleep -Milliseconds 500
    }
    foreach ($d in $device) {
        $code = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
        Write-Host ("PNP {0} | {1} | {2} | problem {3}" -f $d.Status, $d.Class, $d.FriendlyName, $code)
    }
    if (-not $device) { Write-Host 'PNP none found'; Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' } | Format-Table -AutoSize | Out-Host }
    $id = -1
    for ($i = 0; $i -lt 30 -and $id -lt 0; $i++) {
        $after = [LongcableWaveIn]::Devices()
        if (-not $attachedHere) {
            $id = [Array]::FindIndex($after, [Predicate[string]]{ param($n) $n -like '*Longcable*' })
        } elseif ($after.Count -gt $before.Count) {
            # waveIn ids follow device order; the first position that differs is the new one.
            for ($k = 0; $k -lt $after.Count; $k++) {
                if ($k -ge $before.Count -or $after[$k] -ne $before[$k]) { $id = $k; break }
            }
        } else { Start-Sleep -Milliseconds 500 }
    }
    Write-Host ("WAVEIN " + ([LongcableWaveIn]::Devices() -join ' | ') + " -> recording #$id")
    if ($id -lt 0) { throw 'The attached microphone never appeared as a recording device' }
    New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
    $bytes = [LongcableWaveIn]::Record($id, $Seconds, $Out)
    Write-Host "RECORDED $bytes bytes to $Out"
} finally {
    if ($attachedHere -and -not $Keep) {
        & $usbip detach -p $own | Out-Host
        Write-Host "DETACHED port $own"
    } elseif (-not $attachedHere) {
        Write-Host "LEFT ATTACHED port $own (it was attached before this check)"
    }
}
