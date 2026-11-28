#!/bin/bash
set -e

APP=aum.app

swift build -c release
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/release/aum $APP/Contents/MacOS/aum
cp -R .build/release/aum_aum.bundle $APP/Contents/Resources/
cp Resources/Info.plist $APP/Contents/Info.plist
codesign --force --deep --sign "Aum Dev" --entitlements Resources/aum.entitlements $APP
