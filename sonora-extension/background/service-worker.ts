/**
 * Sonora background service worker.
 *
 * Owns the cockpit's source registry: it discovers audible tabs by
 * pinging the content scripts, remembers the controlled source, relays
 * playback commands, and implements the global keyboard commands.
 */

import {
  APP,
  MessageType,
  envelope,
  respond,
  type Envelope,
  type PlaybackCommand,
} from "../shared/messages";
import {
  sourcesToPause,
  toSource,
  type MediaSource,
  type MediaState,
} from "../shared/media-source";
import {
  DEFAULT_SETTINGS,
  loadActiveTabId,
  loadMediaTabs,
  saveMediaTabs,
  loadBridgeSeq,
  loadSettings,
  saveActiveTabId,
  saveBridgeSeq,
  saveSettings,
  type SonoraSettings,
} from "../shared/storage";

const PING_TIMEOUT_MS = 400;
/**
 * Cap on a playback command. `chrome.tabs.sendMessage` reports a missing
 * receiver, but a tab that is still loading can leave the callback parked,
 * and `setActive` now waits for its pauses before it starts the new
 * source — an unanswered pause must not hold the switch open.
 */
const COMMAND_TIMEOUT_MS = 1000;
/**
 * Tabs that reported a media element, kept for as long as they keep
 * reporting one. Chrome clears `tab.audible` the instant playback pauses,
 * so a paused source would otherwise vanish from the cockpit. Persisted in
 * chrome.storage.session because MV3 kills the idle worker within seconds
 * and an in-memory set would forget every paused source on each wake.
 */
const mediaTabs = new Set<number>();

let settings: SonoraSettings = DEFAULT_SETTINGS;
let activeTabId: number | null = null;
let loaded = false;

/** Fresh media states, updated by content-script pushes + ping rounds. */
const knownStates = new Map<number, MediaState>();
/** Tabs we already tried injecting the content script into (this worker's lifetime). */
const injected = new Set<number>();

async function ensureLoaded(): Promise<void> {
  if (loaded) return;
  loaded = true;
  settings = await loadSettings();
  // "Resume last source" off means the cockpit starts with no controlled
  // source rather than silently re-adopting the one from last session.
  activeTabId = settings.resumeLastSource ? await loadActiveTabId() : null;
  for (const id of await loadMediaTabs()) mediaTabs.add(id);
}

function rememberState(tabId: number, state: MediaState): void {
  knownStates.set(tabId, state);
  const had = mediaTabs.has(tabId);
  if (state.hasMedia) mediaTabs.add(tabId);
  else mediaTabs.delete(tabId);
  if (had !== state.hasMedia) {
    void saveMediaTabs([...mediaTabs]);
    reportSourceCount();
  }
}

function forgetTab(tabId: number): void {
  knownStates.delete(tabId);
  if (mediaTabs.delete(tabId)) {
    void saveMediaTabs([...mediaTabs]);
    reportSourceCount();
  }
}

/* ------------------------------------------------------------------ */
/* Tab discovery                                                       */
/* ------------------------------------------------------------------ */

function isWebUrl(url?: string): boolean {
  return !!url && /^https?:/i.test(url);
}

function pingTab(tabId: number): Promise<MediaState | null> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (value: MediaState | null) => {
      if (!done) {
        done = true;
        resolve(value);
      }
    };
    try {
      chrome.tabs.sendMessage(tabId, envelope(MessageType.Ping), (response: unknown) => {
        if (chrome.runtime.lastError) {
          finish(null);
          return;
        }
        const r = response as { app?: string; ok?: boolean; data?: MediaState } | undefined;
        finish(r && r.app === APP && r.ok ? (r.data ?? null) : null);
      });
    } catch {
      finish(null);
    }
    // Note: bare setTimeout — MV3 service workers have no `window` global.
    setTimeout(() => finish(null), PING_TIMEOUT_MS);
  });
}

async function ensureContentScript(tabId: number): Promise<boolean> {
  if (injected.has(tabId)) return false;
  injected.add(tabId);
  try {
    await chrome.scripting.executeScript({
      target: { tabId },
      files: ["content/media-controller.js"],
    });
    return true;
  } catch {
    return false;
  }
}

async function tabsSend<T>(
  tabId: number,
  type: string,
  payload?: unknown,
): Promise<T | null> {
  return new Promise((resolve) => {
    let done = false;
    const finish = (value: T | null) => {
      if (!done) {
        done = true;
        resolve(value);
      }
    };
    try {
      chrome.tabs.sendMessage(tabId, envelope(type, payload), (response: unknown) => {
        if (chrome.runtime.lastError) {
          finish(null);
          return;
        }
        const r = response as { app?: string; ok?: boolean; data?: T } | undefined;
        finish(r && r.app === APP && r.ok ? (r.data ?? null) : null);
      });
    } catch {
      finish(null);
    }
    setTimeout(() => finish(null), COMMAND_TIMEOUT_MS);
  });
}

/**
 * Build the current source list.
 *
 * Chrome already knows which tabs make noise (`tab.audible`), so we ping
 * only those, plus the controlled tab and anything that reported media in
 * the last minute. Pinging every open tab each poll was the expensive
 * (and noisy) way to learn the same thing.
 */
async function collectSources(): Promise<MediaSource[]> {
  await ensureLoaded();
  const tabs = (await chrome.tabs.query({})).filter((t) => {
    if (t.id === undefined || !isWebUrl(t.url)) return false;
    return t.audible || t.id === activeTabId || mediaTabs.has(t.id);
  });

  const sources = (
    await Promise.all(
      tabs.map(async (tab) => {
        const id = tab.id as number;
        let state = await pingTab(id);
        if (!state && (await ensureContentScript(id))) {
          state = await pingTab(id);
        }
        if (!state) {
          forgetTab(id);
          return null;
        }
        rememberState(id, state);
        const tabMuted = !!tab.mutedInfo?.muted;
        // The browser's own audible flag beats the content script's guess
        // ("a media element exists and isn't muted"), which stays true for
        // silent or ended players.
        return { ...toSource(id, state, tabMuted), audible: !!tab.audible && !tabMuted };
      }),
    )
  ).filter((s): s is MediaSource => s !== null);

  // Ascending tab id: the list keeps the browser's own tab order, so a row
  // never jumps under the cursor when a source starts or stops. It is also
  // the order `stepSource` walks, so next/previous matches what you see.
  sources.sort((a, b) => a.tabId - b.tabId);

  updateBadge(sources);
  return sources;
}

function updateBadge(sources: MediaSource[]): void {
  const playing = sources.filter((s) => s.playing).length;
  void chrome.action.setBadgeText({ text: playing > 0 ? String(playing) : "" });
  void chrome.action.setBadgeBackgroundColor({ color: "#12111b" });
}

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

async function sendCommand(
  tabId: number,
  command: PlaybackCommand,
): Promise<MediaState | null> {
  await ensureLoaded();
  let state = await tabsSend<MediaState>(tabId, MessageType.Command, command);
  if (!state && (await ensureContentScript(tabId))) {
    state = await tabsSend<MediaState>(tabId, MessageType.Command, command);
  }
  if (state) {
    rememberState(tabId, state);
    if (command.type === "play" || command.type === "pause") {
      void collectSources();
    }
  }
  return state;
}

/**
 * Mark a tab as the controlled source. Matches the cockpit's model:
 * one signal at a time — every other running source is paused, the new
 * one starts playing.
 *
 * `known` is a source list the caller already collected this round (the
 * step/media-key path has one), so the switch does not pay for a second
 * ping round just to learn what is playing.
 */
async function setActive(
  tabId: number | null,
  known?: MediaSource[],
): Promise<MediaSource | null> {
  await ensureLoaded();
  const previous = activeTabId;
  activeTabId = tabId;
  await saveActiveTabId(tabId);

  // Awaited, not fired and forgotten: "one signal at a time" only holds if
  // the old signals are really down before the new one starts. Pausing just
  // the remembered `previous` was the bug — a tab playing without ever
  // having been the cockpit's active source kept going under the new pick.
  const running = known ?? (await collectSources());
  await Promise.all(
    sourcesToPause(running, tabId, previous).map((id) =>
      sendCommand(id, { type: "pause" }),
    ),
  );

  if (tabId) {
    // Play, then apply the personal defaults so a new signal starts at the
    // cockpit's preferred level. Sequential on purpose: a volume command
    // clears mute, so the two would race if fired together.
    void (async () => {
      await sendCommand(tabId, { type: "play" });
      await sendCommand(tabId, { type: "volume", value: settings.volume / 100 });
      await sendCommand(tabId, { type: "mute", muted: settings.muted });
    })();
  }

  const sources = await collectSources();
  return sources.find((s) => s.tabId === tabId) ?? null;
}

/**
 * Sources a global command (shortcut or media key) may act on. Not
 * `audible`: that flag drops the moment a tab pauses, and pressing
 * play/pause or "next" on a paused cockpit has to keep working.
 */
function commandTargets(sources: MediaSource[]): MediaSource[] {
  return sources.filter((s) => s.hasMedia);
}

/** The source a global toggle / stop acts on. */
function commandTarget(sources: MediaSource[]): MediaSource {
  return (
    sources.find((s) => s.tabId === activeTabId) ??
    sources.find((s) => s.playing) ??
    sources[0]
  );
}

/**
 * Move the controlled source `step` places along the list, wrapping.
 * Steps in tab-id order, not the display order: that one puts the playing
 * source first, so stepping along it after a switch just bounces between
 * the two most recent sources and never reaches the third.
 */
async function stepSource(sources: MediaSource[], step: number): Promise<void> {
  if (sources.length < 2) return;
  const ordered = [...sources].sort((a, b) => a.tabId - b.tabId);
  await setActive(
    ordered[(stepAnchor(ordered) + step + ordered.length) % ordered.length].tabId,
    sources,
  );
}

/**
 * Where a step counts from. The controlled source normally, but when the
 * cockpit has none (nothing selected yet, or its tab is gone) the tab you
 * can actually hear is the one you mean to step away from — counting from
 * the top of the list instead sent "next" backwards past it.
 */
function stepAnchor(ordered: MediaSource[]): number {
  const active = ordered.findIndex((s) => s.tabId === activeTabId);
  if (active >= 0) return active;
  const playing = ordered.findIndex((s) => s.playing);
  return playing >= 0 ? playing : 0;
}

/**
 * "Keep tabs awake": Chrome discards background tabs under memory
 * pressure, which kills playback. An in-page wake lock cannot help (it
 * needs a visible tab); clearing autoDiscardable on the source tabs can.
 */
async function applyKeepAwake(sources: MediaSource[]): Promise<void> {
  const autoDiscardable = !settings.keepTabsAwake;
  await Promise.all(
    sources.map(async (s) => {
      try {
        await chrome.tabs.update(s.tabId, { autoDiscardable });
      } catch {
        // Tab closed or not updatable — best effort.
      }
    }),
  );
}

/* ------------------------------------------------------------------ */
/* Message routing                                                     */
/* ------------------------------------------------------------------ */

interface GetStateData {
  sources: MediaSource[];
  activeTabId: number | null;
  settings: SonoraSettings;
}

chrome.runtime.onMessage.addListener((message: Envelope | undefined, sender, sendResponse) => {
  if (!message || message.app !== APP) return false;

  void (async () => {
    switch (message.type) {
      case MessageType.State: {
        const tabId = sender.tab?.id;
        if (tabId !== undefined) {
          rememberState(tabId, message.payload as MediaState);
        }
        sendResponse(respond({ ok: true }));
        return;
      }

      case MessageType.GetState: {
        await ensureLoaded();
        const sources = await collectSources();
        void applyKeepAwake(sources);
        const data: GetStateData = { sources, activeTabId, settings };
        sendResponse(respond(data));
        return;
      }

      case MessageType.SetActive: {
        const tabId = (message.payload as { tabId: number | null })?.tabId ?? null;
        const source = await setActive(tabId);
        sendResponse(respond(source));
        return;
      }

      case MessageType.SendCommand: {
        const { tabId, command } = message.payload as {
          tabId: number;
          command: PlaybackCommand;
        };
        const state = await sendCommand(tabId, command);
        sendResponse(respond(state));
        return;
      }

      case MessageType.SaveSettings: {
        settings = { ...DEFAULT_SETTINGS, ...(message.payload as SonoraSettings) };
        await saveSettings(settings);
        void collectSources().then((sources) => applyKeepAwake(sources));
        sendResponse(respond(settings));
        return;
      }

      default:
        sendResponse(respond(undefined, `unknown message type ${message.type}`));
    }
  })();

  return true; // respond asynchronously
});

/* ------------------------------------------------------------------ */
/* Global keyboard commands (chrome://extensions/shortcuts)            */
/* ------------------------------------------------------------------ */

chrome.commands.onCommand.addListener(async (command: string) => {
  await ensureLoaded();
  const sources = commandTargets(await collectSources());
  if (sources.length === 0) return;

  if (command === "toggle-playback") {
    await sendCommand(commandTarget(sources).tabId, { type: "toggle" });
  } else if (command === "switch-source") {
    await stepSource(sources, 1);
  }
});


/* ------------------------------------------------------------------ */
/* Media keys via the local bridge                                     */
/* ------------------------------------------------------------------ */

/**
 * The macOS bridge (HeadsetCompanion) captures headset taps / media keys
 * and serves them on loopback:
 *
 *   GET /events?since=<seq>&wait=<seconds>
 *     -> { app, seq, mediaKeys, events: [{ seq, type, at }] }
 *
 * With wait>0 it long-polls: it answers early when an event newer than
 * `since` arrives, otherwise after `wait` seconds with an empty list.
 * Connection refused simply means the bridge is not running.
 *
 * This lives in the worker, not the popup, so the keys work while the
 * cockpit popup is closed. `<all_urls>` already covers the loopback fetch.
 */
const MEDIA_KEY_ALARM = "sonora.mediaKeys";
/**
 * The `app` field the bridge stamps on every response. `sonora-xm4-bridge` is
 * the pre-rename name, still accepted so an older bridge keeps working.
 * Duplicated from `popup/bridge.ts` on purpose: that module is popup-only
 * (it uses `window`), and the worker is its own bundle.
 */
const BRIDGE_APP_NAMES = ["headset-companion", "sonora-xm4-bridge"];
const isBridgeApp = (app: unknown): boolean =>
  typeof app === "string" && BRIDGE_APP_NAMES.includes(app);
const BRIDGE_EVENTS_URL = "http://127.0.0.1:8745/events";
const BRIDGE_WAIT_S = 25;
/**
 * Seconds a held next/previous on the headset moves the playhead. Its own
 * constant, not the popup's 15 s skip: a blind gesture you cannot see the
 * result of wants a smaller, more forgiving step.
 */
const HEADSET_SEEK_STEP = 10;

interface BridgeEvent {
  seq: number;
  type: string;
  at: string;
}

interface BridgeEventsResponse {
  app?: string;
  seq?: number;
  mediaKeys?: boolean;
  events?: BridgeEvent[];
}

let mediaKeyPolling = false;
/**
 * The bridge only claims the media keys while the browser has something to
 * control (see `shouldClaim` in MediaKeyMonitor.swift): holding the
 * now-playing role costs a system-wide MediaRemote broadcast every 15 s,
 * which is pure waste with no media tab open.
 *
 * The count rides the normal `/events` poll, but that poll parks for
 * `BRIDGE_WAIT_S`, so a 0 -> 1 transition has to be pushed out of band or the
 * headset stays dead for up to 25 s after you open a video.
 */
let lastReportedSources = -1;
/** Mirrors the poll loop's cursor so an out-of-band report asks for nothing. */
let bridgeSince = 0;

function reportSourceCount(): void {
  const count = mediaTabs.size;
  if (count === lastReportedSources) return;
  lastReportedSources = count;
  // Fire and forget: the answer is the parked long poll's job, and a bridge
  // that is not running simply refuses the connection.
  void fetch(`${BRIDGE_EVENTS_URL}?since=${bridgeSince}&wait=0&sources=${count}`).catch(
    () => undefined,
  );
}

async function fetchBridgeEvents(
  since: number,
  waitSeconds: number,
): Promise<BridgeEventsResponse | null> {
  try {
    const res = await fetch(
      `${BRIDGE_EVENTS_URL}?since=${since}&wait=${waitSeconds}&sources=${mediaTabs.size}`,
    );
    if (!res.ok) return null;
    const data = (await res.json()) as BridgeEventsResponse;
    return data && isBridgeApp(data.app) ? data : null;
  } catch {
    return null; // connection refused: bridge offline
  }
}

async function handleMediaKey(type: string): Promise<void> {
  const sources = commandTargets(await collectSources());
  if (sources.length === 0) return;
  switch (type) {
    case "play-pause":
      await sendCommand(commandTarget(sources).tabId, { type: "toggle" });
      break;
    // Literal, not a toggle: the bridge only ever sends these when macOS
    // steers the now-playing app (a Bluetooth route teardown above all), so
    // "pause" must never be able to start playback.
    case "play":
      await sendCommand(commandTarget(sources).tabId, { type: "play" });
      break;
    case "pause":
      await sendCommand(commandTarget(sources).tabId, { type: "pause" });
      break;
    case "stop":
      await sendCommand(commandTarget(sources).tabId, { type: "pause" });
      break;
    case "next":
      await stepSource(sources, 1);
      break;
    case "previous":
      await stepSource(sources, -1);
      break;
    // A held next/previous: seek the active source instead of switching it.
    case "seek-forward":
      await sendCommand(commandTarget(sources).tabId, {
        type: "skip",
        by: HEADSET_SEEK_STEP,
      });
      break;
    case "seek-backward":
      await sendCommand(commandTarget(sources).tabId, {
        type: "skip",
        by: -HEADSET_SEEK_STEP,
      });
      break;
  }
}

async function mediaKeyLoop(): Promise<void> {
  if (mediaKeyPolling) return; // one loop per worker lifetime
  mediaKeyPolling = true;
  try {
    let since = await loadBridgeSeq();
    if (since === null) {
      // First ever run: adopt the bridge's current seq so we do not replay
      // key presses from before the cockpit was listening.
      const head = await fetchBridgeEvents(0, 0);
      if (!head) return; // offline — the alarm retries within a minute
      since = head.seq ?? 0;
      bridgeSince = since;
      await saveBridgeSeq(since);
    }
    for (;;) {
      let data = await fetchBridgeEvents(since, BRIDGE_WAIT_S);
      // A bridge restart drops the poll for a second or two; retry briefly
      // before handing over to the 1-minute alarm so keys come back fast.
      for (let attempt = 0; !data && attempt < 5; attempt++) {
        await new Promise((r) => setTimeout(r, 2000));
        data = await fetchBridgeEvents(since, 0);
      }
      if (!data) return; // still offline — the alarm re-kicks us
      if (typeof data.seq === "number" && data.seq < since) {
        // The bridge restarted and its counter began again at 0. Adopt its
        // head rather than waiting for it to climb past our stale seq
        // (old presses from before the restart are gone anyway).
        since = data.seq;
        await saveBridgeSeq(since);
        continue;
      }
      for (const event of data.events ?? []) {
        if (event.seq <= since) continue;
        since = event.seq;
        await handleMediaKey(event.type);
      }
      if (typeof data.seq === "number" && data.seq > since) since = data.seq;
      bridgeSince = since;
      await saveBridgeSeq(since);
    }
  } finally {
    mediaKeyPolling = false;
  }
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

chrome.tabs.onRemoved.addListener((tabId) => {
  forgetTab(tabId);
  injected.delete(tabId);
  if (activeTabId === tabId) {
    activeTabId = null;
    void saveActiveTabId(null);
  }
});

chrome.runtime.onInstalled.addListener(async (details) => {
  await ensureLoaded();
  await applyKeepAwake(await collectSources());
  void mediaKeyLoop();
  // Only a genuine first install — an update or a browser restart fires here too.
  if (details.reason === "install") {
    void chrome.tabs.create({ url: chrome.runtime.getURL("popup/welcome.html") });
  }
});

chrome.runtime.onStartup.addListener(() => {
  void mediaKeyLoop();
});

// The alarm is the safety net: MV3 suspends the worker at will, and this
// is what brings the media-key long poll back up afterwards (and retries
// it while the bridge is offline).
chrome.alarms.create(MEDIA_KEY_ALARM, { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === MEDIA_KEY_ALARM) void mediaKeyLoop();
});

// Worker startup (install, browser start, or wake from suspension).
void mediaKeyLoop();
