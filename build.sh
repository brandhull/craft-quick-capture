#!/bin/zsh
# Build CraftQuickCapture.app and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/CraftQuickCapture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CraftQuickCapture "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CraftQuickCapture</string>
    <key>CFBundleIdentifier</key>
    <string>com.craftquickcapture.app</string>
    <key>CFBundleName</key>
    <string>Craft Quick Capture</string>
    <key>CFBundleDisplayName</key>
    <string>Craft Quick Capture</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'tell application "Craft Quick Capture" to quit' 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/Craft Quick Capture.app"
    cp -R "$APP" "/Applications/Craft Quick Capture.app"
    echo "Installed to /Applications/Craft Quick Capture.app"
    open "/Applications/Craft Quick Capture.app"
else
    echo "Built $APP (use ./build.sh --install to install and launch)"
fi
