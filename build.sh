#!/bin/sh
# Builds HiDPI.app next to this script, self-checks it, and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
app=HiDPI.app
# Stop a running HiDPI first (the app and any helper), so the screen is at normal for the self-check.
pkill -x HiDPI || true
while pgrep -x HiDPI >/dev/null; do sleep 0.2; done
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -fobjc-arc -Wall -O2 -framework Cocoa -framework Carbon -framework ServiceManagement hidpi.m -o "$app/Contents/MacOS/HiDPI"
icons=$(mktemp -d)/HiDPI.iconset
"$app/Contents/MacOS/HiDPI" --icon "$icons"
iconutil -c icns "$icons" -o "$app/Contents/Resources/HiDPI.icns"
rm -rf "$(dirname "$icons")"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>HiDPI</string>
  <key>CFBundleExecutable</key><string>HiDPI</string>
  <key>CFBundleIdentifier</key><string>local.hidpi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleIconFile</key><string>HiDPI</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force -s - "$app"
"$app/Contents/MacOS/HiDPI" --probe 2048
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$app"
cp -R "$app" "$HOME/Applications/"
echo "installed $HOME/Applications/$app"
open "$HOME/Applications/$app"
