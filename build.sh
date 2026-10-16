#!/bin/zsh
# MacMP4 建置腳本:編譯 GUI App + CLI 並打包成 .app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacMP4"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ARCH=$(uname -m)
TARGET="${ARCH}-apple-macos13.0"

echo "==> 清理舊建置"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 編譯 GUI (${ARCH})"
swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
    Sources/Engine.swift Sources/Model.swift Sources/App.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> 編譯 CLI"
swiftc -O -swift-version 5 -target "$TARGET" \
    Sources/Engine.swift CLI/main.swift \
    -o "$BUILD_DIR/macmp4-cli"

echo "==> 產生圖示"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
if swift assets/makeicon.swift "$BUILD_DIR/icon_1024.png" >/dev/null 2>&1; then
    gen() { sips -z "$1" "$1" "$BUILD_DIR/icon_1024.png" --out "$ICONSET/$2" >/dev/null; }
    gen 16   icon_16x16.png
    gen 32   icon_16x16@2x.png
    gen 32   icon_32x32.png
    gen 64   icon_32x32@2x.png
    gen 128  icon_128x128.png
    gen 256  icon_128x128@2x.png
    gen 256  icon_256x256.png
    gen 512  icon_256x256@2x.png
    gen 512  icon_512x512.png
    gen 1024 icon_512x512@2x.png
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" \
        && echo "    圖示完成" || echo "    (icns 轉換失敗,使用系統預設圖示)"
else
    echo "    (圖示產生失敗,使用系統預設圖示)"
fi

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacMP4</string>
    <key>CFBundleDisplayName</key><string>MacMP4</string>
    <key>CFBundleExecutable</key><string>MacMP4</string>
    <key>CFBundleIdentifier</key><string>local.jimmy.MacMP4</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video File</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.mpeg-2-transport-stream</string>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc 簽名"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "✅ 建置完成:"
echo "   App: $APP"
echo "   CLI: $BUILD_DIR/macmp4-cli"
