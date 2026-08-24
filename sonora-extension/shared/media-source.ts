/**
 * Sonora media source model.
 *
 * A MediaState is the raw report from a content script (everything it
 * can learn about the page's audio/video element). A MediaSource adds
 * the browser-tab identity plus the presentation fields the cockpit UI
 * renders (monogram, accent color, kind).
 */

export type SourceKind = "youtube" | "podcast" | "radio" | "other";

export interface MediaState {
  url: string;
  host: string;
  siteName: string;
  favicon: string | null;
  title: string;
  description: string;
  artist: string | null;
  artwork: string | null;
  kind: SourceKind;
  /** an audio/video element exists on the page */
  hasMedia: boolean;
  playing: boolean;
  muted: boolean;
  /** seconds; 0 means live or unknown duration */
  duration: number;
  position: number;
  /** 0..1 */
  volume: number;
  live: boolean;
  /** media exists and is not muted — controllable from the cockpit */
  audible: boolean;
  /** audio-output device the element plays through (HTMLMediaElement.sinkId) */
  sinkId: string | null;
}

export interface MediaSource extends MediaState {
  tabId: number;
  /** the browser tab itself is muted (chrome.tabs mutedInfo) */
  tabMuted: boolean;
  monogram: string;
  color: string;
}

/** What a source-list row (and the now card) says about a source. */
export type SourceRowState = "playing" | "muted" | "paused";

/**
 * A muted tab makes no sound even while its element runs, so the tab mute
 * wins over `playing` — the row says what you can hear, not what the
 * element is doing.
 */
export function sourceRowState(source: Pick<MediaSource, "playing" | "tabMuted">): SourceRowState {
  if (source.tabMuted) return "muted";
  return source.playing ? "playing" : "paused";
}

/**
 * Tab ids to pause when `next` becomes the controlled source.
 *
 * Every source still running, not just the one the cockpit remembers:
 * a tab you started from the page itself (or one left over from a
 * previous worker lifetime) was never the cockpit's active source, so
 * pausing only `previous` left it playing alongside the new pick — two
 * signals at once, which the cockpit model forbids. `previous` is still
 * included even when it reads as paused: its state may be a poll behind.
 */
export function sourcesToPause(
  sources: Pick<MediaSource, "tabId" | "playing">[],
  next: number | null,
  previous: number | null,
): number[] {
  const ids = new Set<number>();
  for (const source of sources) if (source.playing) ids.add(source.tabId);
  if (previous !== null) ids.add(previous);
  if (next !== null) ids.delete(next);
  return [...ids];
}

/* ------------------------------------------------------------------ */
/* Kind + identity heuristics                                          */
/* ------------------------------------------------------------------ */

const YOUTUBE_HOSTS = ["youtube.com", "youtu.be"];

const PODCAST_HOSTS = [
  "podcast.",
  "megaphone.fm",
  "omny.fm",
  "simplecast.com",
  "anchor.fm",
  "acast.com",
  "overcast.fm",
  "podcast.app",
  "podscripts.com",
  "art19.com",
  "podbay.fm",
  "buzzsprout.com",
  "libsyn.com",
];

const RADIO_HOSTS = [
  "nts.live",
  "soma.fm",
  "radio.garden",
  "radioparadise.com",
  "fip.fr",
  "kcrw.com",
  "nightride.fm",
  "groove.sh",
  "antenna.sh",
  "live365.com",
];

/**
 * Two entry shapes, kept apart on purpose:
 *   "podcast."     a label prefix — matches any host with a "podcast"
 *                  label ("podcast.example.com", "www.podcast.fm")
 *   "megaphone.fm" a domain — matches the host itself or a subdomain
 */
function hostMatches(host: string, candidates: string[]): boolean {
  return candidates.some((c) => {
    if (c.endsWith(".")) {
      const label = c.slice(0, -1);
      return host === label || host.startsWith(c) || host.includes("." + c);
    }
    return host === c || host.endsWith("." + c);
  });
}

export function detectKind(host: string, live: boolean): SourceKind {
  const h = host.toLowerCase();
  if (YOUTUBE_HOSTS.some((c) => h === c || h.endsWith("." + c))) return "youtube";
  if (hostMatches(h, PODCAST_HOSTS)) return "podcast";
  if (hostMatches(h, RADIO_HOSTS)) return "radio";
  // Live streams with no duration read as radio in the cockpit.
  if (live) return "radio";
  return "other";
}

const SITE_NAMES: Record<string, string> = {
  youtube: "YouTube",
  "youtu.be": "YouTube",
  nts: "NTS",
  spotify: "Spotify",
  soma: "SomaFM",
  apple: "Apple",
  soundcloud: "SoundCloud",
  bandcamp: "Bandcamp",
  archive: "Archive",
  megaphone: "Megaphone",
  omny: "Omny",
  simplecast: "Simplecast",
  anchor: "Anchor",
  acast: "Acast",
  overcast: "Overcast",
  "radio.garden": "Radio Garden",
  radioparadise: "Radio Paradise",
  fip: "FIP",
  kcrw: "KCRW",
  groove: "Groove",
  antenna: "Antenna",
};

/** "www.youtube.com" -> "YouTube" */
export function siteDisplay(host: string): string {
  const h = host.toLowerCase().replace(/^www\./, "");
  const brand = h.split(".")[0] || h;
  const known = SITE_NAMES[brand] ?? SITE_NAMES[h];
  if (known) return known;
  return brand.charAt(0).toUpperCase() + brand.slice(1);
}

/** Two-letter mark rendered in the tab tile ("YT", "NT", "SP"). */
export function monogram(host: string): string {
  const display = siteDisplay(host).replace(/[^A-Za-z0-9]/g, "");
  if (display.length < 2) return (display + "?").slice(0, 2).toUpperCase();
  return display.slice(0, 2).toUpperCase();
}

/** Accent palette matching the cockpit design tokens. */
const SOURCE_COLORS = ["#ff927d", "#9d84ff", "#71d9d0", "#d5f36b", "#f0b36a"];

export function sourceColor(host: string): string {
  let hash = 0;
  for (let i = 0; i < host.length; i++) {
    hash = (hash * 31 + host.charCodeAt(i)) >>> 0;
  }
  return SOURCE_COLORS[hash % SOURCE_COLORS.length];
}

/** Wrap a content-script state with tab identity + presentation fields. */
export function toSource(tabId: number, state: MediaState, tabMuted = false): MediaSource {
  return {
    ...state,
    tabId,
    tabMuted,
    monogram: monogram(state.host),
    color: sourceColor(state.host),
  };
}
