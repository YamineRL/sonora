#!/usr/bin/env bash
# Regenerates AppIcon.icns from AppIcon.svg. Run this after editing the SVG,
# then commit the .icns — build-app.sh copies it straight into the bundle and
# the release runner has no SVG renderer.
#   ./icon/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")"

# Each size is rendered from the vector where a renderer exists, because
# downsampling one 1024 bitmap turns the 16 and 32 px slices to mush.
# Stock macOS has no SVG renderer, so AppIcon.png (the 1024 master render) is
# committed alongside and sips falls back to scaling that.
RSVG="$(command -v rsvg-convert || true)"
if [[ -z "$RSVG" ]]; then
  echo "note: no rsvg-convert — scaling AppIcon.png with sips instead" >&2
fi

SET="AppIcon.iconset"
rm -rf "$SET"
mkdir "$SET"
render() {  # render <px> <outfile>
  if [[ -n "$RSVG" ]]; then
    "$RSVG" -w "$1" -h "$1" AppIcon.svg -o "$2"
  else
    sips -s format png -z "$1" "$1" AppIcon.png --out "$2" >/dev/null
  fi
}
for pair in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
            128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
            512:512x512 1024:512x512@2x; do
  render "${pair%%:*}" "$SET/icon_${pair#*:}.png"
done

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "Wrote $(pwd)/AppIcon.icns"
