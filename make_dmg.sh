#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=SSHAppInstaller
VERSION=1.0
DMG="15-$APP-$VERSION-universal.dmg"
rm -rf staging
mkdir -p staging
cp -R build/$APP.app staging/
ln -s /Applications staging/Applications
hdiutil create -volname "$APP" -srcfolder staging -ov -format UDZO "$DMG"
echo "✅ created $DMG"
ls -lh "$DMG"
