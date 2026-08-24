# HeadsetCompanion

A tiny macOS menu-bar app that reads the battery level of the Bluetooth
headset you are listening on — any headset, not one particular model — and
serves it as JSON over loopback HTTP, so the Sonora Media Cockpit Chrome
extension can display it.

## Why this exists

- Chrome on macOS has **no Web Bluetooth**, so the extension cannot talk to
  BLE devices directly.
- **No browser API exposes a Bluetooth headset's battery level** at all.
- So this bridge does the things a non-browser process can do: it reads the
  level from the system's Bluetooth stack and/or over BLE, and serves it as
  JSON on `127.0.0.1`.

The Chrome extension (sibling package `sonora-extension/`) fetches
`GET http://127.0.0.1:8745/battery` when the popup opens and re-polls every
10 minutes, rendering the battery on the headphones card — or showing "bridge
offline" when this isn't running.

## Which headset the bridge reports on

The bridge picks one connected device and reports *that* one at `/battery`.
In priority order:

1. **`$SONORA_BT_NAME`** — a case-insensitive substring of the device name.
   Set it and nothing else is considered; that is the manual override.
2. **The current default audio output**, when it is a Bluetooth device: the
   headset you are actually listening on. Its CoreAudio name is matched to
   the Bluetooth device name (trimmed, case-insensitive). Switch output in
   the menu (or anywhere else) and the bridge follows within the same second.
3. **Any connected audio device** — one that reports a battery first. "Audio"
   means the Bluetooth device class says so, or the device publishes an
   A2DP/HFP service, which is what keeps keyboards and mice out.
4. Failing all of that, the BLE scan's last resort: the first peripheral that
   exposes the standard Battery Service.

There is no built-in model name to match on: nothing in the bridge is
specific to one headset.

## How the battery is read (two sources)

Headsets are tricky: while one is linked to your Mac **for audio** it
uses a classic Bluetooth (BR/EDR) link, which is **invisible to CoreBluetooth's
LE central manager** (it isn't advertising, and `retrieveConnectedPeripherals`
only sees LE links). The system stack still tracks its battery, though. So the
monitor runs two sources and publishes the better one:

| source | how | when it works |
|--------|-----|---------------|
| **system** (primary for in-use headsets) | every 10 minutes, merges **two** system readers: `IOBluetoothDevice.pairedDevices()` (the level macOS shows in its Bluetooth menu) and `/usr/sbin/system_profiler SPBluetoothDataType -xml` (`device_batteryLevelMain`) | whenever the headset is linked to the Mac — classic audio link included |
| **gatt** | CoreBluetooth, standard **Battery Service** `0x180F`, characteristic `0x2A19` (scan + `retrieveConnectedPeripherals`, read/notify, 30 s re-read) | when the headset is powered on, in range, and not already linked to another device |

**Why the "system" source has two readers.** A headset tells macOS its battery
level over HFP battery indications, and macOS re-exposes that in two places
that do *not* stay in sync. `system_profiler` only prints
`device_batteryLevelMain` while it has a fresh indication — when the headset
stops sending them (which happens: same headset, same link, the key is simply
gone the next day), that source goes dry and the bridge would report
`connected` with no level. The paired `IOBluetoothDevice` object keeps the
level the Bluetooth stack knows, which is what the macOS Bluetooth menu keeps
showing, so it is read first: for each connected paired device the bridge
takes `batteryPercentSingle` when it is a real level (1–100), else the lower
of `batteryPercentLeft`/`batteryPercentRight` when both report, else nothing —
and `system_profiler` fills in every device left without a level. Those
`batteryPercent…` properties are **not in the public IOBluetooth headers**
(observed behaviour, macOS 13–26; devices with no known level answer `0`), so
they are read defensively through KVC behind a `responds(to:)` check and
`system_profiler` stays as the documented fallback. Both readers feed the same
`system` source — the JSON contract is unchanged.

Precedence: a live **GATT** reading wins while it's connected (it's fresher);
otherwise the **system** reading is published — unless the selection has
moved on to another headset, in which case the system reading takes over
again, so switching output devices switches what is reported.

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- Xcode Command Line Tools: `xcode-select --install`
- Bluetooth on, headset powered on (and reachable — see *How the battery is read*)
- No extra permission for media keys — the bridge receives them through
  MediaRemote (see *Media keys*)

## Run

```bash
cd sonora-xm4-bridge
./build-app.sh
open "HeadsetCompanion.app"
```

`build-app.sh` does `swift build -c release` and assembles the
`HeadsetCompanion.app` bundle around it. **The bundle is required, not
optional:** CoreBluetooth aborts a bare binary (including `swift run`) unless
it runs from a real `.app` whose `Info.plist` carries
`NSBluetoothAlwaysUsageDescription`, and macOS TCC attributes the Bluetooth
request to the "responsible process" (your terminal), so a shell-launched
binary can never get the grant. `open`-ing the bundle is the only working run
path. (`swift run` still works for a quick health/port check — the monitor
degrades gracefully and the HTTP server runs.)

On first launch macOS shows a **Bluetooth permission prompt** for
*HeadsetCompanion* — accept it. Media keys need no permission at all (see
*Media keys*). A headphones icon appears in the menu bar; the battery percentage shows next to
it once a source is reporting.

## The menu (a replacement for Apple's Sound menu)

Clicking the icon opens a window-style popover built to stand in for the
system *Sound* menu, so that one can be removed from the menu bar:

- **Sound** — a volume slider for the **current default output device**
  (CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, falling
  back to the per-channel `VolumeScalar` on devices without a main channel).
  The speaker glyph on the left toggles mute. The slider follows changes made
  elsewhere: CoreAudio property listeners plus a 1 s poll while the menu is
  open.
- **Output** — every CoreAudio device with an output stream, each row with an
  icon picked from its transport type (built-in → `laptopcomputer`,
  Bluetooth → `headphones`, aggregate/virtual → `waveform`, everything else →
  `speaker.wave.2`). The current default is highlighted; clicking a row makes
  it the default output. Every Bluetooth row the system reports a level for
  carries it as a small trailing label (e.g. "60%"), so all your headsets show
  their battery — the one the bridge itself reports at `/battery` is the one
  picked by the rules in *Which headset the bridge reports on*.
- **Sound Settings…** opens the Sound pane of System Settings, and **Quit**
  ends the bridge. A one-line footer says who owns the media keys
  (`Media keys: Sonora / browser / passive`, see *Media keys*).

To stop: click the icon → Quit (or `killall HeadsetCompanion`).

## Start at login

The supported way is the **Start at login** switch in the app's Settings…
panel: it registers the bundle with `SMAppService.mainApp` (macOS 13+), so
the item is visible — and revocable — under *System Settings → General →
Login Items*. Turning it on also removes any
`~/Library/LaunchAgents/io.sonora.headsetcompanion.plist` left by the script
below, because two mechanisms starting the app at login would race for the
exclusive bridge port. If the app can't be registered (a copy run straight
from the DMG, or one still waiting for approval), the reason is shown under
the switch.

### Advanced: the scripted LaunchAgent

Still shipped for unattended installs, and the only option if you want
`KeepAlive` (SMAppService does not restart a crashed app):

```bash
./build-app.sh               # the bundle must exist first
./install-launch-agent.sh    # installs ~/Library/LaunchAgents/io.sonora.headsetcompanion.plist and starts it
./install-launch-agent.sh --uninstall
```

Use one or the other, not both. launchd runs the bundle's executable directly with `RunAtLoad` and
`KeepAlive` on non-zero exit, so the bridge starts at login and is relaunched
after a crash (a clean Quit from the menu bar stays quit). launchd's own
stdout/stderr go to `~/Library/Logs/headset-companion.launchd.log`. After a
rebuild, re-run the installer (it replaces the manually started instance,
which would otherwise hold the port).

## Endpoints & JSON contract

- `GET /battery` → `200` + the JSON below
- `GET /health` → same body
- `GET /events?since=<int>&wait=<seconds>&sources=<int>` → `200` + the media-key event JSON
  (see *Media keys*)
- `GET /debug` → `200` `text/plain` — the last ~80 log lines (diagnostics; loopback-only)
- `OPTIONS` (any path) → `204` (CORS preflight)
- anything else → `404` `{"error":"not found"}`

All JSON responses carry `Content-Type: application/json`,
`Access-Control-Allow-Origin: *`, `Content-Length` (when there is a body) and
`Connection: close`.

```json
{
  "app": "headset-companion",
  "version": "0.1.0",
  "port": 8745,
  "connected": true,
  "mediaKeys": true,
  "deviceName": "0XM4🫡",
  "battery": 100,
  "lastUpdate": "2026-08-21T15:55:46Z",
  "uptime": 7
}
```

| field        | meaning                                                       |
|--------------|---------------------------------------------------------------|
| `connected`  | the matched device is linked (via either source)               |
| `mediaKeys`  | Sonora currently **owns** the media keys (it is the now-playing app) — see *Media keys* |
| `deviceName` | device name as seen by the reporting source (trimmed; `null` when unknown) |
| `battery`    | integer 0–100 (`null` before a reading arrived)                |
| `lastUpdate` | ISO 8601 UTC of the last reading (`null` before first read)    |
| `uptime`     | whole seconds since the app started                           |

All keys are always present; unknown values are JSON `null`. This block is
the fixed contract shared with `sonora-extension/` — do not rename fields.

## Media keys

Tapping the headset's touch panel or button sends an AVRCP command to the Mac, which
applies it to whatever app is currently *now playing* — so a tap can only
play/pause the tab Chrome happens to be showing, and the extension never sees
it. The bridge receives those commands and offers them to Sonora at
`GET /events`, so a tap can mean "play/pause the source Sonora controls" or
"switch to the next audible tab" while you're AFK.

**Why an event tap cannot work.** Headset taps never enter the macOS input
event stream. `bluetoothd` decodes the AVRCP command and hands it to
**MediaRemote** (`rcd`), which delivers it directly to the current
now-playing app. A `CGEventTap` — session or HID, head-inserted, with the
Accessibility permission granted — sees nothing, because there is no CGEvent
to see. (Verified on this Mac: a session tap stayed silent for every tap
while an `MPRemoteCommandCenter` target received them all instantly.) The
keyboard's F7/F8/F9 media keys take the same MediaRemote route.

**How they're received.** The bridge does what a media player does: it
registers `MPRemoteCommandCenter` handlers and records what arrives.

| MediaRemote command | Sonora `type` |
|---------------------|---------------|
| `togglePlayPause`, `play`, `pause` | `play-pause` |
| `nextTrack`        | `next`        |
| `previousTrack`    | `previous`    |
| `stop`             | `stop`        |
| `seekForward` / `seekBackward` | `seek-forward` / `seek-backward` |

Play and pause both fold into `play-pause`: the headset sends whichever one
matches its idea of our state, and to Sonora a tap is one toggle either way.
`seekForward` / `seekBackward` are AVRCP fast-forward / rewind: the *held*
next/previous gesture (swipe-and-hold on the XM4 touch panel). They arrive as
`MPSeekCommandEvent`s in begin/end pairs and only the begin is recorded, so
one gesture is one event; the extension turns it into a ±10 s skip. Every
other command (skip, rating, like, shuffle, …) is explicitly disabled, so
macOS never offers those controls for the bridge.

**Owning the keys = being the now-playing app.** MediaRemote routes commands
to exactly one app: the most recent one to assert now-playing. To take the
keys the bridge publishes `MPNowPlayingInfoCenter` info (title "Sonora",
playback rate 1.0, media type audio) with `playbackState = .playing`; to give
them back it sets `.stopped` and clears the info, and the browser takes over
again. Because a browser tab re-claims the role whenever it starts playing,
the claim is **re-asserted every 2 s** while the bridge is claiming.

**Claim policy — keys are not hijacked by default.**

| `SONORA_MEDIA_KEYS` | behavior |
|---------------------|----------|
| unset / `auto` (default) | claim **only** while a Sonora consumer is listening — i.e. an `/events` request arrived within the last 30 s — **and** that consumer reported at least one media source. Release as soon as either stops being true, handing the keys back to the browser. |
| `passive`           | never claim: the browser (or whatever else) keeps the keys. Commands only arrive if macOS happens to route them here anyway, so this is effectively off. |
| `own`               | always claim: Sonora owns the media keys for as long as the bridge runs. |

`mediaKeys` in `/battery`, `/health` and `/events` is exactly "the claim is
held right now". The menu-bar window shows it in its footer as **Media keys:
Sonora / browser / passive**.

Every decision is logged (`[media-keys] claimed now-playing …`,
`[media-keys] received nextTrack from MediaRemote → next (policy=auto)`),
visible at `GET /debug`.

**No Accessibility permission.** MediaRemote hands commands to the
now-playing app by design — nothing is intercepted, nothing is tapped, so
there is no permission to grant and nothing to re-toggle after a rebuild.

**The `/events` contract.** `since` is the caller's cursor (default `0`),
`wait` the long-poll budget in seconds (default `0`, max `25`), and `sources`
how many media tabs the caller currently has. The response
carries the events with `seq > since`, oldest first, plus the current max
`seq` to use as the next cursor. With `wait > 0` and nothing new, the bridge
holds the connection until an event arrives or the wait elapses (returning an
empty `events` array); each connection is served on its own thread, so a
parked long poll never blocks `/battery` or another `/events` caller.

`sources` is what lets the bridge stop claiming when there is nothing to
control. Holding the now-playing role is not free: it is re-asserted every
15 s, and every re-assert is a system-wide MediaRemote broadcast that wakes
`duetexpertd`, ControlCenter and the audio daemons — measured at ~4 wakeups a
minute, around the clock, even with no media tab open. The bridge cannot ask
macOS whether it still holds the role (`MRMediaRemoteGetNowPlayingApplicationPID`
answers `0` for an unentitled process on macOS 26, and the change
notifications never arrive), so the heartbeat cannot be replaced — only
skipped when it buys nothing. Report `sources=0` and the claim is dropped;
report one or more and it comes straight back.

Omitting the parameter means "I did not say", not "none": a consumer that
never sends it keeps the old always-claim behaviour, so an older extension
still works against a newer bridge.

```bash
curl -s 'http://127.0.0.1:8745/events?since=0&wait=25&sources=2'
```

```json
{
  "app": "headset-companion",
  "seq": 2,
  "mediaKeys": true,
  "events": [
    {"seq": 1, "type": "play-pause", "at": "2026-08-21T15:55:46Z"},
    {"seq": 2, "type": "next", "at": "2026-08-21T15:55:51Z"}
  ]
}
```

The buffer keeps the last 256 events in memory only — nothing is persisted.

## Environment variables

| variable             | effect |
|----------------------|--------|
| `SONORA_BRIDGE_PORT` | HTTP port (default `8745`). If you change it, point the extension at the same port. |
| `SONORA_MEDIA_KEYS`  | When the bridge claims the media keys: `auto` (default, only while a consumer polls `/events`), `passive` (never claim), `own` (always claim). See *Media keys*. |
| `SONORA_BT_NAME`     | **Override** for which headset is reported: a case-insensitive substring matched against the device name (both the GATT name and the system name). Unset (the default), the bridge follows the current Bluetooth audio output — see *Which headset the bridge reports on*. Set it when you want one specific device pinned no matter what is playing. |

## How the extension uses it

The sibling package's popup fetches `/battery` immediately when opened, then
re-polls every 10 minutes (short per-request timeout). On success it renders
the battery value; on connection failure (bridge not running, or listening on
another port) the card shows "bridge offline". Separately it long-polls
`/events?since=<cursor>&wait=<seconds>` to learn about media-key taps and act
on them.

## Logs

- `~/Library/Logs/headset-companion.log` — append-only, also exposed live at
  `GET /debug` (last ~80 lines). Useful for: is the central manager powered
  on, what `retrieveConnectedPeripherals` found, what the system poll sees,
  scan discoveries, connects/disconnects.

## Privacy

- Binds to `127.0.0.1` **only** (never `0.0.0.0`) — nothing leaves the
  machine. `/debug` is loopback-only too.
- The `.app` declares `NSBluetoothAlwaysUsageDescription` (required for
  CoreBluetooth) and nothing else — media keys need no permission, so that
  is the only prompt macOS shows.
- The bridge never taps input events: it only receives the MediaRemote
  commands macOS hands the now-playing app, and records play-pause / next /
  previous / stop / seek-forward / seek-backward. It cannot see typed text,
  and the event buffer is in memory only (last 256, never written to disk).
- `system_profiler` is a read-only system call; no data is written anywhere
  except the local log file. No network calls, no telemetry, no third-party
  dependencies.

## Limitations

- **Battery only.** Sony's proprietary GATT service (ANC mode, etc.) is a
  possible next step but more fragile and undocumented; this bridge sticks to
  the standard Battery Service + public system APIs — no vendor lock-in.
- The headset must be reachable by the Mac: linked to the Mac (any link
  type), or powered on, in range, and not exclusively linked to another
  device. If it's connected to your phone and not to the Mac, the Mac can't
  see it.
- Not every headset reports a battery level to macOS at all; the bridge can
  only serve what the system (or the standard GATT Battery Service) exposes.
- Reconnection is **best-effort**: on disconnect it rescans after ~3 s and
  also attempts a direct reconnect to the last device; the system poll
  independently re-covers linked devices.
- No code signing yet, so macOS may re-prompt for Bluetooth after a rebuild.
  Login start is covered by the **Start at login** switch (see *Start at
  login*).
- With multiple Bluetooth headphones around, the bridge follows the current
  audio output; set `SONORA_BT_NAME` to pin one instead.
- Media-key capture is not device-specific: while the bridge is the
  now-playing app it receives *any* headset's and the keyboard's media keys,
  not just the reported headset's. Volume keys are never involved (macOS handles those
  itself).
- Owning the keys means the browser doesn't get them. That's the point, but
  it also means a play/pause tap won't reach a YouTube tab directly while
  the claim is held — Sonora is expected to act on the `/events` it polled.

> **After every rebuild:** the bundle is unsigned, so macOS ties the Bluetooth
> grant to the exact binary. Re-accept the prompt (or `tccutil reset Bluetooth
> io.sonora.headsetcompanion`) if the battery stops appearing. Media keys are
> unaffected — they need no grant.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `port 8745 … already in use` at startup | Quit the other bridge instance, or run with `SONORA_BRIDGE_PORT=8746` (and point the extension at the same port). |
| No battery at all, `/debug` shows nothing useful | Is Bluetooth on? Is the headset powered on and **not in the case**? Check `GET http://127.0.0.1:8745/debug` in a browser or `curl -s localhost:8745/debug`. |
| `connected: false` although the headset is on | Is it the current audio output, and does macOS list a battery for it in its own Bluetooth menu? If several devices are connected, pin yours with `SONORA_BT_NAME=<substring>`, rebuild, re-`open`. |
| `battery: null` while `connected: true` | A reading hasn't arrived from the reporting source yet — the 30 s GATT re-read / 10 s system poll usually resolves it; wait a few seconds. |
| Extension shows "bridge offline" | Is the bridge running? Check with `curl http://127.0.0.1:8745/health` in a terminal. |
| First launch: Bluetooth prompt ignored / app shows no BLE | Re-run `open "HeadsetCompanion.app"` after accepting the prompt. (A bare `swift run` can never be granted — that's by design of macOS TCC.) |
| `mediaKeys: false` / menu footer says "browser" | Under the default `auto` policy the bridge only claims while something polls `/events` **and** reports a media source. Poll it once (`curl -s 'localhost:8745/events?since=0&wait=0&sources=1'`) and it claims within 2 s, or set `SONORA_MEDIA_KEYS=own`. Note `sources=1`: without it the poll marks a consumer present but says nothing about sources, and with `sources=0` the bridge deliberately will not claim. |
| A tap play/pauses the browser instead of Sonora | The browser re-claimed now-playing (a tab started playing) and the bridge hadn't re-asserted yet — it does so every 2 s. If it persists, check `/debug` for a `released now-playing` line: the consumer window (30 s) probably lapsed. |
| Media keys should stay with the browser | Set `SONORA_MEDIA_KEYS=passive` and re-`open` the app — the bridge then never claims. |
| `/events` never returns anything | Is `mediaKeys` true in `/health`? Then check `curl -s localhost:8745/debug` for `[media-keys] received …` lines. |
