#!/usr/bin/env bash
# Installs (or removes) a per-user LaunchAgent so "HeadsetCompanion.app"
# starts at login and is relaunched if it crashes.
#
#   ./install-launch-agent.sh              install / refresh + start now
#   ./install-launch-agent.sh --uninstall  stop + remove
#
# Why the executable path instead of `open`: launchd then owns the process
# directly, so KeepAlive can restart it on a crash. The binary still lives
# inside the .app, so Bundle.main (and the TCC Bluetooth grant) are intact.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="io.sonora.headsetcompanion"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Works both from the source checkout (sibling of the built bundle) and from
# inside an installed bundle at Contents/Resources/.
if [[ "$(pwd)" == */HeadsetCompanion.app/Contents/Resources ]]; then
  APP="$(cd ../.. && pwd)"
else
  APP="$(pwd)/HeadsetCompanion.app"
fi
BIN="$APP/Contents/MacOS/HeadsetCompanion"
DOMAIN="gui/$(id -u)"

# Pre-rename artifacts (the app used to be "Sonora XM4 Bridge"). Removed
# whenever this script runs, so the old agent can't hold port 8745.
OLD_LABEL="io.sonora.xm4bridge"
OLD_PLIST="$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
OLD_APP="$(pwd)/Sonora XM4 Bridge.app"

remove_old() {
  launchctl bootout "$DOMAIN/$OLD_LABEL" 2>/dev/null || true
  pkill -x SonoraXM4Bridge 2>/dev/null || true
  if [[ -e "$OLD_PLIST" ]]; then rm -f "$OLD_PLIST"; echo "Removed $OLD_PLIST"; fi
  if [[ -d "$OLD_APP" ]]; then rm -rf "$OLD_APP"; echo "Removed $OLD_APP"; fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $PLIST"
  remove_old
  exit 0
fi

remove_old

if [[ ! -x "$BIN" ]]; then
  echo "Bundle not found — run ./build-app.sh first." >&2
  exit 1
fi

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/headset-companion.launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/headset-companion.launchd.log</string>
</dict>
</plist>
PLIST

# Replace any previous registration and any manually started instance
# (the port is exclusive), then let launchd start the new one.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x HeadsetCompanion 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed $PLIST"
echo "Status: launchctl print $DOMAIN/$LABEL | grep -E 'state|pid'"
