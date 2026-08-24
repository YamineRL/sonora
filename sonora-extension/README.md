# Sonora — Browser Extension (MV3)

The first real implementation of the Sonora media cockpit: a Chrome/Arc
extension that finds every audible tab (YouTube, podcasts, web radio),
and lets you control play/pause, seeking, and volume from one popup.

Same visual language as the interactive prototype in the repo root, but
every control is wired to the page's actual media element.

## Build

```bash
cd sonora-extension   # from the repo root
npm install
npm run build     # one-shot build into dist/
npm run watch     # rebuild on change
npm run typecheck # strict TS check
```

## Load into Chrome / Arc

1. `npm run build`
2. Open `chrome://extensions`
3. Enable **Developer mode** (top right)
4. **Load unpacked** → select the `dist/` folder in this directory

Click the Sonora icon in the toolbar to open the cockpit. The badge
shows how many tabs are currently playing.

## Structure

```
sonora-extension/
├── manifest.json               MV3 manifest: permissions, commands, entry points
├── background/
│   └── service-worker.ts       source registry, command relay, global shortcuts
├── content/
│   ├── media-controller.ts     per-tab media controller (finds <audio>/<video>)
│   └── content.css             hook for future in-page overlays (currently empty)
├── popup/
│   ├── index.html              popup shell
│   ├── main.tsx                the cockpit UI (React)
│   └── popup.css               compact cockpit styling (prototype tokens)
├── shared/
│   ├── messages.ts             envelope + message contracts (app-scoped)
│   ├── media-source.ts         source model, kind detection, monogram/color
│   └── storage.ts              chrome.storage.local settings + last source
└── build.mjs                   esbuild bundle → loadable dist/
```

## How it works

- **Content script** (`content/media-controller.ts`) runs on every web
  page. It locates the `audio`/`video` element, reads state
  (playing, position, duration, volume, mute, live), pulls metadata
  from the Media Session API with `og:` meta fallbacks, and reports to
  the background worker. Playback commands (play/pause/seek/skip/
  volume/mute) execute directly on the element. State is pushed on
  media events (throttled to ~1/s for `timeupdate`). When a page holds
  several media elements it controls the one that is playing, else the
  first with a real source.
- **Service worker** (`background/service-worker.ts`) owns the source
  registry. It asks Chrome which tabs are audible (`tab.audible`) and
  pings only those — plus the controlled tab and every tab that still
  reports a media element (remembered in `chrome.storage.session`, so a
  paused source survives the worker being suspended) — injecting the content script once for tabs opened before install.
  A source counts as audible when Chrome says the tab makes noise and
  the tab is not muted. The worker also remembers the controlled
  source, applies the personal defaults on switch, and implements the
  global commands. The source list comes back in ascending tab-id order
  — the browser's own tab order, and the order `Alt S` walks — so a row
  never jumps under the cursor when a tab starts or stops playing.
- **Popup** (`popup/main.tsx`) polls the full cockpit state every
  1.5 s, applies optimistic updates for snappy controls, and sends
  commands through the worker.

### Popup layout

Top to bottom: the topbar (brand, ⌘ K, settings, and a one-line bridge
status — headphone battery and who owns the media keys), the **Now
controlling** card with the transport, volume and progress, then the
source list, then the settings and audio-output panels.

Each source row shows what that tab is doing: an animated equalizer when
it plays, a pause mark when it is paused, a muted mark when the tab
itself is muted. The controlled source is highlighted (`is-active`), and
clicking any row switches to it. When the controlled source is paused,
the card keeps its title and adds a `Paused` tag; "Nothing playing"
appears only when no source is controlled.

### One signal at a time

Matching the cockpit model, selecting a source pauses the previous
source and starts the new one — the browser becomes a single focused
signal you switch between, not a pile of playing tabs.

## Keyboard shortcuts

| Shortcut | Where | Action |
| --- | --- | --- |
| `Space` | popup | play / pause |
| `←` / `→` | popup | seek ∓15 s |
| `⌘ K` / `Ctrl K` | popup | command palette (switch source) |
| `Esc` | popup | close palette / settings |
| `Alt M` | anywhere (tab focused) | toggle active source |
| `Alt S` | anywhere (tab focused) | switch to next audible tab |

Global shortcuts can be re-mapped in `chrome://extensions/shortcuts`.

## Settings

Stored in `chrome.storage.local`:

- **Resume last source** — restore the controlled source when the popup
  opens. Off: the worker starts with no controlled source and the popup
  does not adopt the remembered tab; it just shows whatever is playing
  until you pick a source.
- **Keep tabs awake** — clears `autoDiscardable` on every source tab
  (`chrome.tabs.update`), so Chrome will not discard a playing tab under
  memory pressure. Re-applied whenever the popup asks for state and when
  the toggle changes; turning it off restores the default.
- **Preferred volume / mute** — applied to a source when it becomes the
  controlled one (after `play`), and saved whenever you move the popup's
  volume slider or mute button.

## Audio output + headset battery

- The Audio output card lists browser audio-output devices and routes the
  active source to one of them (`sink` command → `setSinkId` on the tab's
  media element).
- The popup fetches `http://127.0.0.1:8745/battery` immediately when opened,
  then re-polls every 10 minutes (battery changes slowly). While the
  companion menu-bar app (HeadsetCompanion) is running, the connected headset's battery appears on the
  topbar status line; otherwise it reads "bridge offline". That app lives in
  [`../sonora-xm4-bridge/`](../sonora-xm4-bridge/README.md).

## Media keys (via bridge)

The service worker long-polls the bridge for media-key events
(`GET /events?since=<seq>&wait=25` on `127.0.0.1:8745`) so headset taps
work while the popup is closed. A `chrome.alarms` alarm re-starts the
poll every minute — MV3 suspends the worker at will — and doubles as the
retry while the bridge is offline. The last consumed sequence lives in
`chrome.storage.local`, so a restart never replays old presses; the very
first run adopts the bridge's current sequence.

| Event | Cockpit action |
| --- | --- |
| `play-pause` | toggle the active source |
| `next` / `previous` | switch to the next / previous source (wraps) |
| `seek-forward` / `seek-backward` | skip the active source ±10 s (held next/previous on the headset) |
| `stop` | pause the active source |

No extra macOS permission is needed: the bridge receives the commands as
the system's "now playing" app (MediaRemote) while the extension is
polling it. When it reports `mediaKeys: true`, the topbar status line reads
"keys: Sonora".

## Known limitations (this milestone)

- **iframe players**: audio inside cross-origin iframes (some
  embeds, Spotify) is not directly controllable — the page's own
  `audio`/`video` elements are.
- **Autoplay policy**: `play()` from the popup has no user gesture on
  the target page, so strict pages may refuse until you interact with
  the tab.
- **Headphone state**: the audio output card shows the browser output
  device (sinkId + enumerateDevices). Chrome only exposes device
  labels for in-use/authorized outputs, so "System default" is common.
  Headset battery arrives via the local bridge (below) — no browser API
  exposes BLE battery.
- **Sink routing**: the `sink` command runs `setSinkId` in the tab;
  Chrome may refuse it without a user gesture in the tab itself, and the
  device ids the popup enumerates are scoped to the popup's origin, so
  they may not resolve inside the page. The state that comes back always
  carries the element's real `sinkId`, so the selector never lies.
- **Live streams** show `LIVE` instead of a seek bar (duration unknown).
- No in-page overlay yet (`content.css` is a stub for it).

## Next steps

- In-page "controlled by Sonora" badge via `content.css` + a small
  content-script overlay (off by default).
- Per-source volume curves and a "queue" model for switching sources.
- Icons for the extension (manifest currently loads without them).
- Packaged build (`.crx`) for distribution.
