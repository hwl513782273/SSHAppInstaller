#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=SSHAppInstaller
rm -rf build
mkdir -p build/$APP.app/Contents/MacOS build/$APP.app/Contents/Resources
swiftc -O -parse-as-library -framework SwiftUI -framework AppKit -o build/$APP.app/Contents/MacOS/$APP Sources/*.swift
cp Resources/Info.plist build/$APP.app/Contents/Info.plist
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns build/$APP.app/Contents/Resources/AppIcon.icns
fi
# 关 App Sandbox 才能调 ssh/scp:用 ad-hoc 签名
codesign --force --deep --sign - build/$APP.app
echo "✅ built build/$APP.app"
file build/$APP.app/Contents/MacOS/$APP
