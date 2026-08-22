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
swift test >/dev/null
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Info.plist
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILD + 1))" Info.plist
git add Info.plist
git diff --cached --quiet || git commit -m "Release $VERSION"
git tag "v$VERSION"
git push && git push origin "v$VERSION"
echo "Tagged v$VERSION — watch: gh run watch"
