/**
 * Sonora persistent settings (chrome.storage.local).
 * Kept deliberately small: the cockpit remembers one controlled source
 * and a couple of personal defaults.
 */

import { APP } from "./messages";

export interface SonoraSettings {
  /** restore the last controlled source when the popup opens */
  resumeLastSource: boolean;
  /** stop Chrome from discarding source tabs (tabs.autoDiscardable) */
  keepTabsAwake: boolean;
  /** preferred cockpit volume, 0..100 */
  volume: number;
  muted: boolean;
}

export const DEFAULT_SETTINGS: SonoraSettings = {
  resumeLastSource: true,
  keepTabsAwake: false,
  volume: 68,
  muted: false,
};

const KEYS = {
  settings: `${APP}.settings`,
  activeTabId: `${APP}.activeTabId`,
  bridgeSeq: `${APP}.bridgeSeq`,
  mediaTabs: `${APP}.mediaTabs`,
} as const;

async function readLocal<T>(key: string, fallback: T): Promise<T> {
  try {
    const data = await chrome.storage.local.get(key);
    return (data[key] as T) ?? fallback;
  } catch {
    return fallback;
  }
}

export function loadSettings(): Promise<SonoraSettings> {
  return readLocal<SonoraSettings>(KEYS.settings, DEFAULT_SETTINGS).then((s) => ({
    ...DEFAULT_SETTINGS,
    ...s,
  }));
}

export function saveSettings(settings: SonoraSettings): Promise<void> {
  return chrome.storage.local
    .set({ [KEYS.settings]: settings })
    .catch(() => undefined);
}

export function loadActiveTabId(): Promise<number | null> {
  return readLocal<number | null>(KEYS.activeTabId, null);
}

export function saveActiveTabId(tabId: number | null): Promise<void> {
  return chrome.storage.local
    .set({ [KEYS.activeTabId]: tabId })
    .catch(() => undefined);
}

/**
 * Last media-key event sequence consumed from the local bridge. Persisted
 * so a suspended service worker does not replay old key presses when it
 * wakes; null means "never polled the bridge".
 */
export function loadBridgeSeq(): Promise<number | null> {
  return readLocal<number | null>(KEYS.bridgeSeq, null);
}

export function saveBridgeSeq(seq: number): Promise<void> {
  return chrome.storage.local
    .set({ [KEYS.bridgeSeq]: seq })
    .catch(() => undefined);
}

/**
 * Tab ids that reported a media element, kept in chrome.storage.session
 * (cleared when the browser quits, survives service-worker restarts).
 */
export async function loadMediaTabs(): Promise<number[]> {
  try {
    const data = await chrome.storage.session.get(KEYS.mediaTabs);
    const ids = data[KEYS.mediaTabs];
    return Array.isArray(ids) ? ids.filter((n) => typeof n === "number") : [];
  } catch {
    return [];
  }
}

export function saveMediaTabs(ids: number[]): Promise<void> {
  return chrome.storage.session
    .set({ [KEYS.mediaTabs]: ids })
    .catch(() => undefined);
}
