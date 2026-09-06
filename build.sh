#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=SSHAppInstaller
rm -rf build
mkdir -p build/$APP.app/Contents/MacOS build/$APP.app/Contents/Resources
# universal：swiftc 不支持 -arch(clang 参数)，用 -target 分别编译两架构再 lipo 合并
swiftc -O -parse-as-library -target arm64-apple-macos12.0 -framework SwiftUI -framework AppKit -o build/.bin_arm64 Sources/*.swift
swiftc -O -parse-as-library -target x86_64-apple-macos12.0 -framework SwiftUI -framework AppKit -o build/.bin_x86_64 Sources/*.swift
lipo -create build/.bin_arm64 build/.bin_x86_64 -o build/$APP.app/Contents/MacOS/$APP
rm -f build/.bin_arm64 build/.bin_x86_64
cp Resources/Info.plist build/$APP.app/Contents/Info.plist
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns build/$APP.app/Contents/Resources/AppIcon.icns
fi
# 关 App Sandbox 才能调 ssh/scp:用 ad-hoc 签名
codesign --force --deep --sign - build/$APP.app
echo "✅ built build/$APP.app"
file build/$APP.app/Contents/MacOS/$APP
