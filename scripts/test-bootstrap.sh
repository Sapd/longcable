#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sandbox=$(mktemp -d "$PWD/build/bootstrap-test.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/release/longcable/bin" "$sandbox/release/longcable/scripts" "$sandbox/release/longcable/Longcable.app/Contents"
cp .build/release/longcable-server "$sandbox/release/longcable/bin/"
cp scripts/install-mac.sh "$sandbox/release/longcable/scripts/"
echo sandbox-app > "$sandbox/release/longcable/Longcable.app/Contents/test"
tar -C "$sandbox/release" -czf "$sandbox/release/longcable-macos.tar.gz" longcable
(cd "$sandbox/release" && shasum -a 256 longcable-macos.tar.gz > longcable-macos.tar.gz.sha256)
export LONGCABLE_RELEASE_URL="file://$sandbox/release" LONGCABLE_INSTALL_ROOT="$sandbox/root"
LONGCABLE_LAN_ADDRESS=192.168.42.10 LONGCABLE_LAN_NETMASK=255.255.255.0 bash scripts/install.sh >/dev/null
test -f "$sandbox/root/Applications/Longcable.app/Contents/test"
python3 - "$sandbox/root" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
job = plistlib.loads((root/'Library/LaunchDaemons/org.sapd.longcable.plist').read_bytes())
assert job['ProgramArguments'][1:] == ['0.0.0.0', '192.168.42.0/24']
PY
# Replacing an older copy and forwarding explicit arguments also work.
touch "$sandbox/root/Applications/Longcable.app/obsolete"
bash scripts/install.sh 127.0.0.1 127.0.0.2 >/dev/null
test ! -e "$sandbox/root/Applications/Longcable.app/obsolete"
python3 - "$sandbox/root" <<'PY'
import pathlib, plistlib, sys
job = pathlib.Path(sys.argv[1])/'Library/LaunchDaemons/org.sapd.longcable.plist'
assert plistlib.loads(job.read_bytes())['ProgramArguments'][1:] == ['127.0.0.1', '127.0.0.2']
PY
# A corrupt download must fail before replacing existing files.
printf 'corruption' >> "$sandbox/release/longcable-macos.tar.gz"
if bash scripts/install.sh >/dev/null 2>&1; then echo 'Checksum failure accepted' >&2; exit 1; fi
test -f "$sandbox/root/Applications/Longcable.app/Contents/test"
echo 'PASS: bootstrap download, checksum, auto-detect, argument forwarding, app replacement and corrupt archive rejection (6 checks); no sudo, launchctl or open used'
