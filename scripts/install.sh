#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
set -euo pipefail
base=${LONGCABLE_RELEASE_URL:-https://github.com/Sapd/longcable/releases/latest/download}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL "$base/longcable-macos.tar.gz" -o "$work/longcable-macos.tar.gz"
curl -fsSL "$base/longcable-macos.tar.gz.sha256" -o "$work/checksum"
# Accept exactly the expected archive name, never paths supplied by the checksum file.
read -r expected filename rest < "$work/checksum"
[[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$filename" == longcable-macos.tar.gz && -z "${rest:-}" ]] || {
  echo 'Invalid release checksum file' >&2; exit 1;
}
actual=$(shasum -a 256 "$work/longcable-macos.tar.gz")
[[ "${actual%% *}" == "$expected" ]] || { echo 'Release checksum mismatch' >&2; exit 1; }
# Release archives must stay inside the longcable directory.
tar -tzf "$work/longcable-macos.tar.gz" > "$work/contents"
while IFS= read -r entry; do
  case "$entry" in longcable/*) ;; *) echo 'Unsafe archive path' >&2; exit 1 ;; esac
  case "/$entry/" in */../*) echo 'Unsafe archive traversal' >&2; exit 1 ;; esac
done < "$work/contents"
tar -xzf "$work/longcable-macos.tar.gz" -C "$work"
cd "$work/longcable"
if [[ -n "${LONGCABLE_INSTALL_ROOT:-}" ]]; then
  # Sandbox mode installs real release files without sudo, launchctl, or open.
  root=$LONGCABLE_INSTALL_ROOT
  [[ "$root" == /* && "$root" != / ]] || { echo 'Invalid sandbox root' >&2; exit 1; }
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  [[ "$root" != / ]] || exit 1
  bash scripts/install-mac.sh --root "$root" "$@"
  mkdir -p "$root/Applications"
  rm -rf "$root/Applications/Longcable.app"
  cp -R Longcable.app "$root/Applications/Longcable.app"
  echo "Sandbox app installed: $root/Applications/Longcable.app"
else
  sudo bash scripts/install-mac.sh "$@"
  sudo rm -rf /Applications/Longcable.app
  sudo cp -R Longcable.app /Applications/Longcable.app
  open /Applications/Longcable.app
fi
