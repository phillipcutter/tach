#!/bin/sh
# Builds the collector for every supported platform and packages Tach.app into ./build.
# TACH_VERSION sets the app version; TACH_UNIVERSAL=1 builds the app for both Apple silicon and Intel.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${TACH_VERSION:-0.1.0}
BUILD=${TACH_BUILD:-1}

echo "collector"
cd "$ROOT/collector"
mkdir -p bin
for t in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64; do
  os=${t%/*}; arch=${t#*/}
  CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath -ldflags "-s -w" -o "bin/tach-collector-$os-$arch" ./cmd/tach-collector
done

[ "$1" = "collector" ] && exit 0

echo "app"
cd "$ROOT/app"
if [ "$TACH_UNIVERSAL" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Tach
else
  swift build -c release
  BIN=.build/release/Tach
fi
APP="$ROOT/build/Tach.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/collector"
cp "$BIN" "$APP/Contents/MacOS/Tach"
cp "$ROOT"/collector/bin/tach-collector-* "$APP/Contents/Resources/collector/"
[ -f "$ROOT/app/Resources/Tach.icns" ] && cp "$ROOT/app/Resources/Tach.icns" "$APP/Contents/Resources/Tach.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tach</string>
  <key>CFBundleDisplayName</key><string>Tach</string>
  <key>CFBundleIdentifier</key><string>app.tach.Tach</string>
  <key>CFBundleExecutable</key><string>Tach</string>
  <key>CFBundleIconFile</key><string>Tach</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "built $APP"
