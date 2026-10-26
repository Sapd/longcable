#!/bin/bash
# Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
# Licensed under GPL-3.0-or-later; see LICENSE.
# Builds universal (arm64 + x86_64) binaries and packs them with the install scripts.
# Output: dist/longcable-macos.tar.gz and its .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
build=(swift build -c release --arch arm64 --arch x86_64 --disable-sandbox)
"${build[@]}"
bin=$("${build[@]}" --show-bin-path)
rm -rf dist && mkdir -p dist/longcable/bin dist/longcable/scripts
install -m 755 "$bin/longcable-server" "$bin/Longcable" dist/longcable/bin/
install -m 755 scripts/install-mac.sh scripts/uninstall-mac.sh dist/longcable/scripts/
install -m 644 README.md LICENSE dist/longcable/
lipo -info dist/longcable/bin/longcable-server dist/longcable/bin/Longcable
dist/longcable/bin/longcable-server --validate 127.0.0.1 127.0.0.2
tar -C dist -czf dist/longcable-macos.tar.gz longcable
(cd dist && shasum -a 256 longcable-macos.tar.gz > longcable-macos.tar.gz.sha256)
cat dist/longcable-macos.tar.gz.sha256
