#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, tags, pushes. The GitHub
# Action (.github/workflows/release.yml) then builds the DMG and attaches it
# to the release, which is what the in-app updater downloads.
#   ./release.sh 1.2.0
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh X.Y.Z}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
# The gate stays fatal, but `set -e` alone aborts silently and the release just
# looks like it stopped. Keep the log so the failure can be read off the tail.
LOG="$(mktemp -t sonora-release-test)"
if ! swift test >"$LOG" 2>&1; then
  echo "swift test failed — release aborted. Last 40 lines ($LOG):" >&2
  tail -40 "$LOG" >&2
  exit 1
fi
rm -f "$LOG"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Info.plist
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILD + 1))" Info.plist
git add Info.plist
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag "v$VERSION"
git push && git push origin "v$VERSION"
echo "Tagged v$VERSION — watch: gh run watch"
