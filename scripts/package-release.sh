#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
# Builds universal (arm64 + x86_64) binaries and packs the server, Longcable.app and the
# install scripts. Output: dist/longcable-macos.tar.gz and its .sha256.
# VERSION defaults to the latest git tag without its leading "v".
set -euo pipefail
cd "$(dirname "$0")/.."
version=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}
version=${version#v}
build=(swift build -c release --arch arm64 --arch x86_64 --disable-sandbox)
"${build[@]}"
bin=$("${build[@]}" --show-bin-path)

art=build/Artwork
rm -rf "$art" && mkdir -p "$art/AppIcon.iconset"
for points in 16 32 128 256 512; do
  sips -z "$points" "$points" Artwork/AppIconMaster.png --out "$art/AppIcon.iconset/icon_${points}x${points}.png" >/dev/null
  sips -z $((points*2)) $((points*2)) Artwork/AppIconMaster.png --out "$art/AppIcon.iconset/icon_${points}x${points}@2x.png" >/dev/null
done
if ! iconutil -c icns "$art/AppIcon.iconset" -o "$art/LongcableAppIcon.icns"; then
  echo 'iconutil unavailable; packing and verifying PNG-backed ICNS with Swift' >&2
  swift Artwork/make-icons.swift "$art" --icns
fi
swift Artwork/make-icons.swift "$art"

rm -rf dist && mkdir -p dist/longcable/bin dist/longcable/scripts
app=dist/longcable/Longcable.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin/Longcable" "$app/Contents/MacOS/Longcable"
install -m 644 "$art/LongcableAppIcon.icns" "$art/LongcableMenuBarIconTemplate.pdf" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Longcable</string>
<key>CFBundleDisplayName</key><string>Longcable</string>
<key>CFBundleIdentifier</key><string>org.sapd.longcable.app</string>
<key>CFBundleExecutable</key><string>Longcable</string>
<key>CFBundleIconFile</key><string>LongcableAppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 Denis Arnst (Sapd). GPL-3.0-or-later.</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"

install -m 755 "$bin/longcable-server" dist/longcable/bin/
install -m 755 scripts/install-mac.sh scripts/uninstall-mac.sh scripts/install.sh scripts/setup-windows.ps1 dist/longcable/scripts/
install -m 644 README.md LICENSE dist/longcable/
lipo -info dist/longcable/bin/longcable-server "$app/Contents/MacOS/Longcable"
codesign --verify --strict "$app" && echo "Longcable.app $version signature OK (ad-hoc)"
dist/longcable/bin/longcable-server --validate 127.0.0.1 127.0.0.2
tar -C dist -czf dist/longcable-macos.tar.gz longcable
(cd dist && shasum -a 256 longcable-macos.tar.gz > longcable-macos.tar.gz.sha256)
cat dist/longcable-macos.tar.gz.sha256

install -m 755 scripts/install.sh dist/install.sh
install -m 644 scripts/setup-windows.ps1 dist/setup-windows.ps1
