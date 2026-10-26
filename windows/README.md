# Longcable Windows client

PowerShell 5.1+, Windows and an independently installed **usbip-win2 driver and
usbip.exe** are required. Download/install from
<https://github.com/vadimgrn/usbip-win2/releases>. Nothing is bundled or downloaded
automatically. The wrapper stops with that link when usbip.exe is missing.
Put usbip.exe on PATH or add `-ClientPath 'C:\Program Files\USBip\usbip.exe'` to commands.
Run administrator PowerShell. If your local script policy requires it, use a
process-scoped policy suitable for scripts you have inspected.

```powershell
.\longcable.ps1 check
.\longcable.ps1 list -Server 100.85.208.64
.\longcable.ps1 attach -Server 100.85.208.64 -BusID 1-1
# Or select exactly one matching VID:PID (ambiguous matches are refused):
.\longcable.ps1 attach -Server 100.85.208.64 -Device 231d:0201
.\longcable.ps1 port
.\longcable.ps1 detach -Port 1
```

Port numbers come from `port`; they are not bus IDs. Attach uses a bounded
one-shot request and `low-latency` receive mode; `-ReceiveMode zero-copy` is optional.
The wrapper checks the installed controller with `check`; it never installs drivers.

```powershell
# Foreground loop, Ctrl+C to stop:
.\longcable.ps1 reconnect -Server 100.85.208.64 -BusIDs 1-1,1-2
# Install an optional task for the current administrator, starting at logon:
.\longcable.ps1 install-reconnect -Server 100.85.208.64 -BusIDs auto
.\longcable.ps1 uninstall-reconnect
```

The task `Longcable Reconnect` starts immediately and at that user's next logon;
it does not run before login. Its PowerShell process uses an execution-policy
override for these installed scripts; it does not change the machine policy. It copies only these PowerShell scripts to
`C:\Program Files\Longcable`, remembers the external usbip.exe path, preserves
existing attachments, scans exports every five seconds and retries every two
seconds. Each native command has an eight-second timeout. Logs record state
changes and rotate at 1 MiB. A per-session mutex prevents duplicate workers.

Uninstall the task before detaching to prevent automatic reattachment. Uninstall
preserves attachments, helper files and logs; remove `C:\Program Files\Longcable`
when no worker is running if you want those gone too. Driver uninstall is managed
by usbip-win2. The newly adapted scripts have not been run against a Windows driver
in this checkout. Use a trusted LAN or Tailscale: USB/IP has no encryption or authentication.
