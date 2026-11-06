#!/bin/zsh
# Builds Tidy.app (menu bar only, no Dock icon). Copy it to /Applications to keep it.
set -e
cd "${0:A:h}"
swift build -c release
rm -rf Tidy.app && mkdir -p Tidy.app/Contents/MacOS
cp .build/release/Tidy Tidy.app/Contents/MacOS/Tidy
cat > Tidy.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Tidy</string>
<key>CFBundleIdentifier</key><string>local.tidy.menubar</string>
<key>CFBundleName</key><string>Tidy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - Tidy.app
