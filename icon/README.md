# App icon

`AppIcon.svg` is the master. `AppIcon.icns` is what ships — `build-app.sh`
copies it into `HeadsetCompanion.app/Contents/Resources/`, and `Info.plist`
points at it with `CFBundleIconFile`.

    ./icon/make-icns.sh     # AppIcon.svg -> AppIcon.icns, then commit both

The `.icns` is committed on purpose: the release runner builds the DMG with
`make-dmg.sh` on a stock `macos-14` image, which has no SVG renderer.

## The design

A near-black squircle with the mark in Sonora lime — the deliberate inverse of
the Chrome extension's lime tile with dark equaliser bars, so the two are easy
to tell apart at a glance in Finder. The mark is headphones over five dots,
which is the app's own menu-bar item (`docs/img/menubar-styles.png`): the dots
are the battery gauge.

Colours are the product palette from `sonora-extension/popup/popup.css` —
lime `#d5f36b` on a shell that runs `#1f1c2d` to `#12111b`.

Sizes drive the geometry, not the other way round. Most people meet this icon
at 16 px in Login Items and System Settings, so every stroke is at least 4% of
the canvas and the five dots are tucked far enough inside the earcups that a
dark gutter survives at 16 px — without it the mark collapses into a letter A.
Check anything you add the same way:

    ./icon/make-icns.sh
    iconutil -c iconset icon/AppIcon.icns -o /tmp/check.iconset
    open /tmp/check.iconset/icon_16x16.png

## Two traps, both found the hard way

**The artwork is full-bleed, and that is deliberate.** The old advice — draw
the squircle at 824×824 inside a 1024 canvas and leave a ~10% margin — now
backfires. macOS 26 reshapes legacy `.icns` icons itself, and when it finds a
margin it decides the artwork is a free-standing glyph: it shrinks it further
and mounts it on a light grey plaque, which looks nothing like the icon you
drew and is especially ugly for a dark one. Artwork that reaches the edges is
masked to the system squircle instead and looks native. You can see both
behaviours on any Mac running 26 — Amphetamine and Cryptomator get the plaque,
Anytype does not.

**The shell is a plain rounded rect, not a superellipse.** A flattened
superellipse only *touches* the canvas edge at four points, and 26 reads that
as a margin too and plaques it — even at full bleed, and even though the two
shapes are within a couple of pixels of each other. A `<rect rx="230">` has
genuinely flush edges and comes out clean. The system supplies its own squircle
mask on 26, so the small difference in corner curvature never shows.

To check a change end to end, ask macOS what it would draw rather than trusting
the PNGs. Copy the built bundle somewhere scratch, give the copy a unique
`CFBundleIdentifier` (Launch Services caches by bundle id, so reusing it hands
you a stale answer), then:

```swift
// swift probe.swift
import AppKit
let img = NSWorkspace.shared.icon(forFile: "/tmp/Probe.app")
img.size = NSSize(width: 128, height: 128)
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "/tmp/probe.png"))
```

A grey border around the icon means you are being plaqued.

## Notes for whoever touches this next

- `make-icns.sh` renders each slice from the vector when `rsvg-convert` is on
  the box, and otherwise scales the committed `AppIcon.png` with `sips`. The
  fallback is noticeably softer at 16 and 32 px, so re-render with a real SVG
  renderer before committing a design change.
- `make-dmg.sh` needs nothing: it copies the whole `.app`, so the icon rides
  along. The DMG's own *volume* icon is still the generic disk — giving it one
  would mean a `.VolumeIcon.icns` plus `SetFile -a C`, which nobody has asked
  for.
