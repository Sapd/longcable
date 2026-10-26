#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
set -euo pipefail
root=''
dry_run=false
while (($#)); do
  case "$1" in
    --root) root=${2:?Missing sandbox directory}; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --help) echo "Usage: $0 [--root DIR] [--dry-run] (removes Longcable settings and logs)"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [[ -n "$root" ]]; then
  [[ "$root" == /* && "$root" != / && -d "$root" ]] || { echo 'Invalid sandbox root' >&2; exit 1; }
  root=$(cd "$root" && pwd -P)
  [[ "$root" != / ]] || exit 1
elif ! $dry_run && [[ $EUID != 0 ]]; then echo 'Run with sudo' >&2; exit 1; fi
if $dry_run; then
  echo "Would stop org.sapd.longcable and remove Longcable binary, plist, settings, socket and logs under ${root:-/}"
  exit 0
fi
if [[ -z "$root" ]] && launchctl print system/org.sapd.longcable >/dev/null 2>&1; then
  launchctl bootout system/org.sapd.longcable
fi
rm -f "$root/Library/LaunchDaemons/org.sapd.longcable.plist"
rm -rf "$root/Library/Application Support/Longcable" "$root/Library/Logs/Longcable" "$root/var/run/longcable"
echo 'Longcable removed'
