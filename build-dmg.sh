#!/bin/zsh
# Build a reproducible, minimal drag-to-Applications disk image.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
ARCH=$(uname -m)
DMG_NAME="MacMP4-v${VERSION}-macos-${ARCH}.dmg"
./build.sh
codesign --verify --deep --strict build/MacMP4.app
STAGING=$(mktemp -d "${TMPDIR:-/private/tmp}/macmp4-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto build/MacMP4.app "$STAGING/MacMP4.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE docs/INSTALL.txt "$STAGING/"
hdiutil create -volname "MacMP4" -srcfolder "$STAGING" -format UDZO -ov "build/$DMG_NAME"
hdiutil verify "build/$DMG_NAME"
(cd build && shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt)
echo "DMG: build/$DMG_NAME"
