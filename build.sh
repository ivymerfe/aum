#!/bin/bash
set -e

APP=aum.app

swift build -c debug
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp .build/debug/aum $APP/Contents/MacOS/aum
cp -R .build/debug/aum_aum.bundle $APP/Contents/Resources/
cp Resources/Info.plist $APP/Contents/Info.plist
codesign --force --deep --sign - --entitlements Resources/aum.entitlements $APP
