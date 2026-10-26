#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sandbox=$(mktemp -d "$PWD/build/install-test.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
scripts/install-mac.sh --root "$sandbox/root" --skip-build 0.0.0.0 192.168.1.20,192.168.1.21 231d 0201 1234 LEFT >/dev/null
scripts/install-mac.sh --dry-run --skip-build 127.0.0.1 any > "$sandbox/preview.plist"
python3 - "$sandbox" <<'PY'
import pathlib, plistlib, sys
p=pathlib.Path(sys.argv[1]); root=p/'root'
job=root/'Library/LaunchDaemons/org.sapd.longcable.plist'
d=plistlib.loads(job.read_bytes())
assert d['Label']=='org.sapd.longcable'
assert d['ProgramArguments']==['/Library/Application Support/Longcable/longcable-server','0.0.0.0','192.168.1.20,192.168.1.21','231d','0201','1234','LEFT']
assert d['KeepAlive'] and d['RunAtLoad'] and d['ThrottleInterval']==5
assert job.stat().st_mode & 0o777 == 0o644
assert (root/'Library/Application Support/Longcable/longcable-server').stat().st_mode & 0o777 == 0o755
preview=plistlib.loads((p/'preview.plist').read_bytes())
assert preview['ProgramArguments'][1:]==['127.0.0.1','any']
print('PASS: sandbox install, plist arguments, launchd settings, permissions, dry-run preview (5 checks)')
PY
cp "$sandbox/root/Library/LaunchDaemons/org.sapd.longcable.plist" "$sandbox/before.plist"
if scripts/install-mac.sh --root "$sandbox/root" --skip-build 0.0.0.0 invalid >/dev/null 2>&1; then echo 'Invalid configuration accepted' >&2; exit 1; fi
cmp "$sandbox/before.plist" "$sandbox/root/Library/LaunchDaemons/org.sapd.longcable.plist"
echo 'PASS: invalid configuration preserves installed plist (1 check)'
touch "$sandbox/root/keep-me"
scripts/uninstall-mac.sh --root "$sandbox/root" --dry-run >/dev/null
test -f "$sandbox/root/Library/LaunchDaemons/org.sapd.longcable.plist"
scripts/uninstall-mac.sh --root "$sandbox/root" >/dev/null
test -f "$sandbox/root/keep-me"
test ! -e "$sandbox/root/Library/LaunchDaemons/org.sapd.longcable.plist"
test ! -e "$sandbox/root/Library/Application Support/Longcable"
test ! -e "$sandbox/root/Library/Logs/Longcable"
echo 'PASS: dry-run uninstall and clean sandbox removal (2 checks)'
mkdir -p "$sandbox/fake-bin"
cat > "$sandbox/fake-bin/tailscale" <<'FAKE'
#!/bin/bash
if [[ "$1" == ip && "$2" == -4 ]]; then echo 100.64.1.2; else exit 1; fi
FAKE
chmod +x "$sandbox/fake-bin/tailscale"
PATH="$sandbox/fake-bin:$PATH" scripts/install-mac.sh --dry-run --skip-build > "$sandbox/tailscale.plist"
LONGCABLE_LAN_ADDRESS=192.168.51.23 LONGCABLE_LAN_NETMASK=0xfffffe00 scripts/install-mac.sh --root "$sandbox/lan" --skip-build >/dev/null
python3 - "$sandbox" <<'PYTEST'
import pathlib, plistlib, sys
p = pathlib.Path(sys.argv[1])
tail = plistlib.loads((p/'tailscale.plist').read_bytes())
lan = plistlib.loads((p/'lan/Library/LaunchDaemons/org.sapd.longcable.plist').read_bytes())
assert tail['ProgramArguments'][1:] == ['0.0.0.0', '100.64.0.0/10']
assert lan['ProgramArguments'][1:] == ['0.0.0.0', '192.168.50.0/23']
print('PASS: no-argument Tailscale and LAN detection (2 checks)')
PYTEST
echo '10 installer checks passed; no launchctl or sudo used'
