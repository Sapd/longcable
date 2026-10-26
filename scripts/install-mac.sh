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
    --help) echo "Usage: $0 [--root DIR | --dry-run] [--skip-build] LISTEN_IPV4 PEERS [VID PID LOCATION LABEL ...]"; exit 0 ;;
    --*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
(($# >= 2)) || { echo 'Supply listen IPv4 and comma-separated peers (or any)' >&2; exit 1; }
if [[ -n "$root" ]]; then
  [[ "$root" == /* && "$root" != / ]] || { echo '--root must be an absolute sandbox directory, not /' >&2; exit 1; }
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  [[ "$root" != / ]] || exit 1
elif ! $dry_run && [[ $EUID != 0 ]]; then
  echo 'Build first as your user, then run sudo scripts/install-mac.sh --skip-build ...' >&2
  exit 1
fi
if ! $skip_build; then
  mkdir -p "$project/.build/tmp" "$project/.build/cache"
  export TMPDIR="$project/.build/tmp" CLANG_MODULE_CACHE_PATH="$project/.build/cache" SWIFTPM_MODULECACHE_OVERRIDE="$project/.build/cache"
  swift build -c release --disable-sandbox
fi
binary="$project/.build/release/longcable-server"
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
    launchctl bootout system/org.sapd.longcable
  fi
fi
mv -f "$support/longcable-server.new" "$support/longcable-server"
mv -f "$staged" "$job"
if [[ -z "$root" ]]; then launchctl bootstrap system "$job"; fi
echo "Installed: $job"
cat "$job"
