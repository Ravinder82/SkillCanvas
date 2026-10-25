#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/SkillCanvas.app"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "SkillCanvas requires Xcode Command Line Tools."
  echo "Install them with: xcode-select --install"
  read -r -p "Press Return to close..."
  exit 1
fi
mkdir -p "$HOME/Applications" "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Building SkillCanvas for this Mac..."
swiftc -O -parse-as-library -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers "$ROOT/SkillCanvas/main.swift" -o "$APP/Contents/MacOS/SkillCanvas"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SkillCanvas</string>
<key>CFBundleIdentifier</key><string>com.skillcanvas.app</string>
<key>CFBundleName</key><string>SkillCanvas</string>
<key>CFBundleDisplayName</key><string>SkillCanvas</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
if [ -f "$ROOT/AppIcon.icns" ]; then
  cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/SkillCanvas"
echo "Installed to $APP"
open "$APP"
