# Longcable

A slim native macOS USB/IP server and SwiftUI menu-bar app. Uses IOUSBHost whole-device capture as **root**, with no custom
kext, DriverKit extension or SIP changes. Capture removes the device from Mac apps
until the remote session releases it. Compatible with usbip-win2 on Windows and
Linux `usbip` clients (TCP 3240).

Denis's original native implementation was hardware-tested with two VKB Gladiator
EVO sticks (231d:0201 / 231d:0200) and a Steam Controller puck (28de:1304).
Those observations predate this standalone extraction; this checkout has unit and
sandbox installer tests, not fresh hardware validation.

Requires macOS 13+, Xcode command-line tools / Swift 5.9+. No package dependencies.

```sh
swift build
swift test
swift run longcable-server list  # external device VID/PID/location, no capture
swift build -c release
sudo scripts/install-mac.sh --skip-build 100.85.208.64 100.86.73.38
swift run Longcable             # Share devices in the menu-bar app
```

The installer builds release by default. `--skip-build` uses the existing release
binary, avoiding a root-owned build cache. In restricted agent environments, run
`swift build --disable-sandbox` / `swift test --disable-sandbox` if nested SwiftPM
sandboxing is unavailable. Installer build caches and temporary files stay in `.build/`.

For a preview without sudo or launchctl:

```sh
scripts/install-mac.sh --dry-run 0.0.0.0 192.168.1.20,192.168.1.21
scripts/install-mac.sh --root "$PWD/build/sandbox" --skip-build 0.0.0.0 192.168.1.20
scripts/uninstall-mac.sh --root "$PWD/build/sandbox"
```

Listen may be a specific IPv4 or `0.0.0.0`. The second argument is one peer IPv4,
a comma-separated allowlist, or `any` (prints a loud security warning).
**USB/IP is unauthenticated and unencrypted: use Tailscale or a trusted LAN.**

Optional device arguments are repeated `VID PID LOCATION LABEL` groups (hex IDs,
unique alphanumeric label). Example: `231d 0201 02131200 VKBLEFT0201`. Group order
fixes bus IDs `1-1` through `1-16`; named external devices follow their VID/PID across
ports. Identical models are refused. Serial-less devices receive the configured
software serial; existing hardware serials are preserved. Keep labels/order stable.
Apple vendor `05ac` devices are hidden and cannot be added from the app. Only an
explicit VID/PID/location configuration permits them, pinned to that location.

Settings: `/Library/Application Support/Longcable/`; local control socket:
`/var/run/longcable/control.sock`; logs: `/Library/Logs/Longcable/`; launchd:
`org.sapd.longcable`. `longcable-server --control status|share|unshare|reconnect [BUSID]`
provides local controls. Changes require root or the signed-in console user.
`sudo scripts/uninstall-mac.sh` stops Longcable and removes its binary, configuration,
socket and logs. The app can be run from the checkout; no app bundle installer is included.

Windows: install the official [usbip-win2](https://github.com/vadimgrn/usbip-win2/releases)
(signed drivers, CLI and a GUI), then in administrator PowerShell:

```powershell
$usbip = 'C:\Program Files\USBip\usbip.exe'
& $usbip list -r 100.85.208.64
& $usbip attach -r 100.85.208.64 -b 1-1 --receive-mode=low-latency
& $usbip port --stash   # remember attached devices; reattached at every boot
```

No extra client is needed. Without `--once`, usbip-win2 keeps retrying after a dropped
connection, and stashed devices come back after a reboot. Longcable keeps bus IDs stable
across reconnects and Mac port changes, so stashed entries stay valid. Tested with
usbip-win2 0.9.8.1: server restart (back after ~30 s), 30 s network drop, Windows reboot.
On Linux, load `vhci-hcd`, then use `usbip list -r MAC_IP` and
`sudo usbip attach -r MAC_IP -b 1-1`.

Limits: no isochronous transfers, alternate setting 0 only, 16 devices/clients,
64 pending transfers and 8 MiB pending data per session, 1 MiB per transfer.
Sleep/wake, Linux interoperability and long-duration reliability need further
hardware testing. GPL-3.0-or-later; copyright 2026 Denis Arnst (Sapd).
