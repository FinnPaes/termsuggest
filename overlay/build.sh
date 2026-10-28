#!/bin/sh
# Builds overlay/TermSuggest.app (needs Xcode command line tools: swiftc).
set -e
cd "$(dirname "$0")"
app=TermSuggest.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -swift-version 5 -o "$app/Contents/MacOS/TermSuggest" main.swift
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.termsuggest.overlay</string>
  <key>CFBundleName</key><string>TermSuggest</string>
  <key>CFBundleExecutable</key><string>TermSuggest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Requirement based on the bundle id only, so macOS keeps the Accessibility
# permission after a rebuild (an ad-hoc signature otherwise changes every build).
codesign --force --sign - -r='designated => identifier "local.termsuggest.overlay"' "$app" >/dev/null 2>&1 ||
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built overlay/$app"
