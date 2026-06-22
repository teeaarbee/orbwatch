#!/bin/zsh
# Builds OrbWatch in release mode and packages it into a double-clickable
# OrbWatch.app. Pass --install to also copy it into /Applications.
set -e
cd "$(dirname "$0")"

echo "▸ building release…"
swift build -c release

APP="OrbWatch.app"
BIN=".build/release/OrbWatch"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OrbWatch"

echo "▸ rendering app icon…"
"$BIN" --export-icon "$APP/Contents/Resources" >/dev/null
rm -rf "$APP/Contents/Resources/AppIcon.iconset"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OrbWatch</string>
  <key>CFBundleDisplayName</key><string>OrbWatch</string>
  <key>CFBundleIdentifier</key><string>com.besttt.orbwatch</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>OrbWatch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it launch locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "▸ built $APP"

if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "▸ installed to /Applications/$APP"
fi
echo "✓ done — open with:  open $APP"
