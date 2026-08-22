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
# Shipped inside the bundle so an installed copy can register/unregister its
# own LaunchAgent (the README's install step).
mkdir -p "$APP/Contents/Resources"
cp install-launch-agent.sh "$APP/Contents/Resources/install-launch-agent.sh"
chmod +x "$APP/Contents/Resources/install-launch-agent.sh"

echo ""
echo "Built: $(pwd)/$APP"
echo "Run:   open \"$APP\"   (menu-bar icon appears)"
