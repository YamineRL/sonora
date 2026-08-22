/**
 * Sonora content script — the media controller for a single tab.
 *
 * Finds the page's audio/video element, reports its state to the
 * background worker, and executes playback commands coming from the
 * cockpit popup. Runs in the isolated world; re-injection (for tabs
 * opened before install) is a no-op thanks to the loaded flag.
 */

import { APP, MessageType, envelope, respond, type Envelope, type PlaybackCommand } from "../shared/messages";
import { detectKind, siteDisplay, type MediaState } from "../shared/media-source";

const g = globalThis as Record<string, unknown>;

/**
 * Pick the element the cockpit controls. Pages routinely carry several
 * media elements (ad slots, hidden preloaders, autoplay previews), so
 * prefer the one that is actually playing, then one that has a real
 * source, and only then fall back to the first in the document.
 */
function findMedia(): HTMLMediaElement | null {
  const all = Array.from(document.querySelectorAll<HTMLMediaElement>("audio, video"));
  if (all.length === 0) return null;
  return (
    all.find((m) => !m.paused && m.readyState > 0) ??
    all.find((m) => !!(m.currentSrc || m.src)) ??
    all[0]
  );
}

function metaContent(name: string): string | null {
  const el = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`);
  return el ? el.getAttribute("content") : null;
}

function mediaSessionInfo(): { title?: string; artist?: string; artwork?: string } {
  try {
    const m = navigator.mediaSession?.metadata;
    if (!m) return {};
    const art = m.artwork?.[0] as { src?: string; url?: string } | undefined;
    return {
      title: m.title || undefined,
      artist: m.artist || undefined,
      artwork: art ? art.src || art.url || undefined : undefined,
    };
  } catch {
    return {};
  }
}

function faviconHref(): string | null {
  const link = document.querySelector<HTMLLinkElement>('link[rel~="icon"], link[rel="shortcut icon"]');
  if (!link) return null;
  try {
    return new URL(link.href, location.href).href;
  } catch {
    return link.href || null;
  }
}

function buildState(): MediaState {
  const media = findMedia();
  const ms = mediaSessionInfo();
  const host = location.hostname;

  const playing = media ? !media.paused && media.playbackRate > 0 : false;
  const live = media ? !Number.isFinite(media.duration) || media.duration <= 0 : false;
  const duration = media ? (live ? 0 : media.duration) : 0;

  const description =
    metaContent("og:description") ?? metaContent("description") ?? "";

  return {
    url: location.href,
    host,
    siteName: siteDisplay(host),
    favicon: faviconHref(),
    title: ms.title || document.title || host,
    description: description.slice(0, 200),
    artist: ms.artist ?? null,
    artwork: ms.artwork ?? metaContent("og:image"),
    kind: detectKind(host, live),
    hasMedia: !!media,
    playing,
    muted: media ? media.muted : true,
    duration,
    position: media ? media.currentTime : 0,
    volume: media ? media.volume : 0,
    live,
    audible: !!media && !media.muted,
    sinkId: media ? ((media as unknown as { sinkId?: string }).sinkId ?? null) : null,
  };
}

/* ------------------------------------------------------------------ */
/* Playback commands                                                   */
/* ------------------------------------------------------------------ */

async function applyCommand(command: PlaybackCommand): Promise<void> {
  const media = findMedia();
  switch (command.type) {
    case "play":
      if (media) await media.play().catch(() => undefined);
      break;
    case "pause":
      media?.pause();
      break;
    case "toggle":
      if (!media) break;
      if (media.paused) await media.play().catch(() => undefined);
      else media.pause();
      break;
    case "seek": {
      if (!media || !Number.isFinite(media.duration) || media.duration <= 0) break;
      media.currentTime = Math.min(media.duration, Math.max(0, command.to));
      break;
    }
    case "skip": {
      if (!media || !Number.isFinite(media.duration) || media.duration <= 0) break;
      media.currentTime = Math.min(media.duration, Math.max(0, media.currentTime + command.by));
      break;
    }
    case "volume":
      if (media) {
        media.volume = Math.min(1, Math.max(0, command.value));
        if (media.volume > 0) media.muted = false;
      }
      break;
    case "mute":
      if (media) media.muted = command.muted;
      break;
    case "sink": {
      // Best effort: Chrome can refuse setSinkId without a user gesture in
      // this tab, and the popup's device ids are scoped to the popup's
      // origin so they may not resolve here. Either way the caller gets
      // the element's real sinkId back in the state that follows.
      const withSink = media as unknown as {
        setSinkId?: (deviceId: string) => Promise<void>;
      } | null;
      if (withSink && typeof withSink.setSinkId === "function") {
        await withSink.setSinkId(command.deviceId).catch(() => undefined);
      }
      break;
    }
  }
}

/* ------------------------------------------------------------------ */
/* State push (throttled) + event wiring                               */
/* ------------------------------------------------------------------ */

function pushState(): void {
  try {
    void chrome.runtime.sendMessage(envelope(MessageType.State, buildState()));
  } catch {
    // Extension context invalidated (e.g. reload) — nothing to do.
  }
}

let lastPushAt = 0;
let trailingPush: number | null = null;

function schedulePush(immediate = false): void {
  const now = Date.now();
  const delay = immediate ? 0 : Math.max(0, 1000 - (now - lastPushAt));
  if (delay <= 0) {
    lastPushAt = now;
    pushState();
    return;
  }
  if (trailingPush === null) {
    trailingPush = window.setTimeout(() => {
      trailingPush = null;
      lastPushAt = Date.now();
      pushState();
    }, delay);
  }
}

if (!g.__sonoraLoaded) {
  g.__sonoraLoaded = true;

  chrome.runtime.onMessage.addListener(
    (message: Envelope | undefined, _sender, sendResponse) => {
      if (!message || message.app !== APP) return false;
      if (message.type === MessageType.Ping) {
        sendResponse(respond(buildState()));
        return true;
      }
      if (message.type === MessageType.Command) {
        void applyCommand(message.payload as PlaybackCommand).then(() =>
          sendResponse(respond(buildState())),
        );
        return true;
      }
      return false;
    },
  );

  const mediaEvents: Array<keyof HTMLElementEventMap> = [
    "play",
    "pause",
    "seeked",
    "volumechange",
    "ratechange",
    "ended",
    "durationchange",
  ];
  const attached = new WeakSet<HTMLMediaElement>();
  const attach = (media: HTMLMediaElement) => {
    if (attached.has(media)) return;
    attached.add(media);
    for (const ev of mediaEvents) media.addEventListener(ev, () => schedulePush(true));
    media.addEventListener("timeupdate", () => schedulePush(false));
  };

  // The media element can appear after load (players mount lazily).
  const attachAll = () => {
    for (const el of Array.from(document.querySelectorAll("audio, video"))) {
      attach(el as HTMLMediaElement);
    }
  };
  attachAll();
  // Coalesce DOM churn: busy pages mutate constantly, and a querySelectorAll
  // per mutation batch in every tab adds up. One re-scan per second is plenty
  // for a lazily mounted player.
  let rescan: number | null = null;
  new MutationObserver(() => {
    if (rescan !== null) return;
    rescan = window.setTimeout(() => {
      rescan = null;
      attachAll();
    }, 1000);
  }).observe(document.documentElement, { childList: true, subtree: true });

  // First report shortly after injection.
  window.setTimeout(() => pushState(), 250);
}
