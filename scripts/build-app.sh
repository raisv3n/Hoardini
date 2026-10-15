#!/bin/bash
# Builds Hoardini.app (SwiftPM release build + hand-assembled bundle) and installs it to /Applications (system-wide).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-icons.sh
# UNIVERSAL=1 builds for both Apple Silicon and Intel.
if [ "${UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  REL=.build/apple/Products/Release
else
  swift build -c release
  REL=.build/release
fi
APP="/Applications/Hoardini.app"
STAGE="$(mktemp -d)/Hoardini.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$REL/HoardiniApp" "$STAGE/Contents/MacOS/Hoardini"
cp .build/icons/AppIcon.icns .build/icons/menubar.png .build/icons/icon-256.png "$STAGE/Contents/Resources/"

cat > "$STAGE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.hoardini.app</string>
  <key>CFBundleName</key><string>Hoardini</string>
  <key>CFBundleDisplayName</key><string>Hoardini</string>
  <key>CFBundleExecutable</key><string>Hoardini</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.6</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSFileQuarantineEnabled</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$STAGE" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
# Replace the installed copy only after the new bundle is complete.
mv "$APP" "$APP.old" 2>/dev/null || true
mv "$STAGE" "$APP"
rm -rf "$APP.old"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Installed $APP"
