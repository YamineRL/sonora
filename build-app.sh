#!/usr/bin/env bash
# Builds "HeadsetCompanion.app" (the menu-bar bundle) and prints how to run it.
#
# Why a bundle is required: CoreBluetooth refuses to start in a bare
# `swift run` binary — macOS aborts the process unless it runs from a real
# .app whose Info.plist carries NSBluetoothAlwaysUsageDescription. This
# script assembles that bundle around the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="HeadsetCompanion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/HeadsetCompanion "$APP/Contents/MacOS/HeadsetCompanion"
chmod +x "$APP/Contents/MacOS/HeadsetCompanion"
# Shipped inside the bundle so an installed copy can still use the scripted
# LaunchAgent (the advanced alternative to the Start at login switch).
mkdir -p "$APP/Contents/Resources"
cp install-launch-agent.sh "$APP/Contents/Resources/install-launch-agent.sh"
chmod +x "$APP/Contents/Resources/install-launch-agent.sh"
# Finder, the DMG, Login Items and System Settings all read this. It is
# committed rather than built here; see icon/README.md to regenerate it.
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# TCC only attributes System Audio Recording consent to a *signed bundle* whose
# Info.plist is sealed. The linker signature SwiftPM leaves behind is not a
# bundle signature ("Info.plist=not bound"), and with that macOS refuses to
# prompt and silently zeroes every process tap — the app goes mute instead of
# quieter. Ad-hoc is enough locally; the cdhash changes on every rebuild, so
# macOS re-asks after a rebuild.
codesign --force --sign - --identifier io.sonora.headsetcompanion "$APP"

echo ""
echo "Built: $(pwd)/$APP"
echo "Run:   open \"$APP\"   (menu-bar icon appears)"
