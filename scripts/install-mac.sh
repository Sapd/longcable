#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
set -euo pipefail
cd "$(dirname "$0")/.."
project=$PWD
root=''
dry_run=false
skip_build=false
while (($#)); do
  case "$1" in
    --root) root=${2:?Missing sandbox directory}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --skip-build) skip_build=true; shift ;;
    --help) echo "Usage: $0 [--root DIR | --dry-run] [--skip-build] [LISTEN_IPV4 PEERS [VID PID LOCATION LABEL ...]]"; exit 0 ;;
    --*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
if (($# == 0)); then
  # The LAN address override suppresses Tailscale probes for deterministic sandbox tests.
  tail_ip=''
  if [[ -z "${LONGCABLE_LAN_ADDRESS:-}" ]]; then
    tail_cli=$(command -v tailscale || true)
    for cli in "$tail_cli" /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
      if [[ -n "$cli" && -x "$cli" ]]; then
        tail_ip=$("$cli" ip -4 2>/dev/null || true)
        if [[ "$tail_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
        tail_ip=''
      fi
    done
  fi
  if [[ -n "$tail_ip" ]]; then
    peers=100.64.0.0/10
    echo "Detected Tailscale ($tail_ip): listening on 0.0.0.0, allowing tailnet $peers" >&2
  else
    lan_ip=${LONGCABLE_LAN_ADDRESS:-}
    netmask=${LONGCABLE_LAN_NETMASK:-}
    if [[ -z "$lan_ip" ]]; then
      interface=$(/sbin/route -n get default | awk '/interface:/ {print $2; exit}')
      [[ -n "$interface" ]] || { echo 'No primary LAN interface; supply explicit LISTEN_IPV4 PEERS' >&2; exit 1; }
      lan_ip=$(/usr/sbin/ipconfig getifaddr "$interface")
      netmask=$(/sbin/ifconfig "$interface" | awk '/inet / {print $4; exit}')
    fi
    [[ -n "$netmask" ]] || { echo 'LAN detection requires a netmask (LONGCABLE_LAN_NETMASK for tests)' >&2; exit 1; }
    # Convert the interface address and hexadecimal/dotted netmask without assuming /24.
    peers=$(LAN_IP="$lan_ip" LAN_MASK="$netmask" /usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('Foundation');
function env(k) { return ObjC.unwrap($.NSProcessInfo.processInfo.environment.objectForKey(k)); }
var octets = env('LAN_IP').split('.').map(Number);
var raw = env('LAN_MASK');
var dotted = raw.split('.').map(Number);
if (!/^0x[0-9a-fA-F]{8}$/.test(raw) && !(dotted.length === 4 && dotted.every(n => Number.isInteger(n) && n >= 0 && n <= 255))) throw Error('Invalid LAN netmask');
var mask = raw.indexOf('0x') === 0 ? parseInt(raw, 16) >>> 0 : dotted.reduce((a,b) => ((a << 8) | b) >>> 0, 0);
var bits = mask.toString(2);
if (!/^1*0*$/.test(bits.padStart(32, '0')) || octets.length !== 4 || octets.some(n => !Number.isInteger(n) || n < 0 || n > 255)) throw Error('Invalid LAN address or netmask');
var ip = octets.reduce((a,b) => ((a << 8) | b) >>> 0, 0);
var network = (ip & mask) >>> 0;
[24,16,8,0].map(n => (network >>> n) & 255).join('.') + '/' + bits.replace(/0/g, '').length;
JXA
)
    echo "Detected LAN: listening on 0.0.0.0, allowing subnet $peers" >&2
  fi
  echo 'Override with: sudo scripts/install-mac.sh LISTEN_IPV4 IPV4_OR_CIDR[,IPV4_OR_CIDR...]' >&2
  set -- 0.0.0.0 "$peers"
fi
(($# >= 2)) || { echo 'Supply both listen IPv4 and peers, or neither' >&2; exit 1; }
if [[ -n "$root" ]]; then
  [[ "$root" == /* && "$root" != / ]] || { echo '--root must be an absolute sandbox directory, not /' >&2; exit 1; }
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  [[ "$root" != / ]] || exit 1
elif ! $dry_run && [[ $EUID != 0 ]]; then
  echo 'Build first as your user, then run sudo scripts/install-mac.sh --skip-build ...' >&2
  exit 1
fi
# A release download ships a prebuilt binary in bin/; a source checkout builds one.
binary="$project/bin/longcable-server"
if [[ -x "$binary" ]]; then
  skip_build=true
else
  binary="$project/.build/release/longcable-server"
fi
if ! $skip_build; then
  mkdir -p "$project/.build/tmp" "$project/.build/cache"
  export TMPDIR="$project/.build/tmp" CLANG_MODULE_CACHE_PATH="$project/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$project/.build/cache"
  swift build -c release --disable-sandbox
fi
"$binary" --validate "$@" >&2
# These arguments have been validated: IPv4 addresses, hexadecimal IDs, alphanumeric labels.
xml_escape() { printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"; }
plist() {
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.sapd.longcable</string>
<key>ProgramArguments</key><array>
<string>/Library/Application Support/Longcable/longcable-server</string>
PLIST
  for arg in "$@"; do printf '<string>%s</string>\n' "$(xml_escape "$arg")"; done
  cat <<'PLIST'
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>/Library/Logs/Longcable/launchd.log</string>
<key>StandardErrorPath</key><string>/Library/Logs/Longcable/launchd.log</string>
</dict></plist>
PLIST
}
if $dry_run; then plist "$@"; exit 0; fi
support="$root/Library/Application Support/Longcable"
job="$root/Library/LaunchDaemons/org.sapd.longcable.plist"
mkdir -p "$support" "$(dirname "$job")" "$root/Library/Logs/Longcable"
# Validate saved target identities before replacing an existing installation.
if [[ -z "$root" ]]; then "$binary" --preflight-install "$@"; fi
staged="$job.staging"
trap 'rm -f "$staged"' EXIT
plist "$@" > "$staged"
/usr/bin/plutil -lint "$staged"
chmod 644 "$staged"
install -m 755 "$binary" "$support/longcable-server.new"
if [[ -z "$root" ]]; then
  chown root:wheel "$support" "$support/longcable-server.new" "$staged"
  chmod 755 "$support"
  if launchctl print system/org.sapd.longcable >/dev/null 2>&1; then
    launchctl bootout system/org.sapd.longcable || true
    # bootout returns before launchd has removed the job; bootstrapping too early fails with error 5.
    for _ in {1..20}; do
      launchctl print system/org.sapd.longcable >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
fi
mv -f "$support/longcable-server.new" "$support/longcable-server"
mv -f "$staged" "$job"
if [[ -z "$root" ]]; then
  for attempt in 1 2 3; do
    launchctl bootstrap system "$job" && break
    [[ $attempt == 3 ]] && { echo "launchctl bootstrap failed; run: sudo launchctl bootstrap system $job" >&2; exit 1; }
    sleep 2
  done
fi
echo "Installed: $job"
cat "$job"
