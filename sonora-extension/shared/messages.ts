/**
 * Sonora message contracts shared by the popup, the background service
 * worker, and the per-page content scripts.
 *
 * Every message is an envelope tagged with the app name so it can never
 * be confused with runtime messages from other extensions.
 */

export const APP = "sonora" as const;

export const MessageType = {
  /** popup/content -> background: "report your media state" (content replies with state) */
  Ping: "sonora.ping",
  /** background -> content: execute a playback command */
  Command: "sonora.command",
  /** content -> background: push a fresh state after a media event */
  State: "sonora.state",
  /** popup -> background: full cockpit state (sources + active + settings) */
  GetState: "sonora.getState",
  /** popup -> background: mark a tab as the controlled source (pauses the previous one) */
  SetActive: "sonora.setActive",
  /** popup -> background -> content: send a playback command to one tab */
  SendCommand: "sonora.sendCommand",
  /** popup -> background: persist settings */
  SaveSettings: "sonora.saveSettings",
} as const;

export type MessageType = (typeof MessageType)[keyof typeof MessageType];

/** Commands the content script can execute against the page's media element. */
export type PlaybackCommand =
  | { type: "play" }
  | { type: "pause" }
  | { type: "toggle" }
  | { type: "seek"; to: number }
  | { type: "skip"; by: number }
  | { type: "volume"; value: number }
  | { type: "mute"; muted: boolean }
  | { type: "sink"; deviceId: string };

export interface Envelope<T = unknown> {
  app: typeof APP;
  type: string;
  payload?: T;
}

export function envelope<T>(type: string, payload?: T): Envelope<T> {
  return { app: APP, type, payload };
}

export interface BackgroundResponse<T = unknown> {
  app: typeof APP;
  ok: boolean;
  data?: T;
  error?: string;
}

export function respond<T>(data?: T, error?: string): BackgroundResponse<T> {
  return { app: APP, ok: !error, data, ...(error ? { error } : {}) };
}

function isBackgroundResponse(value: unknown): value is BackgroundResponse {
  return !!value && typeof value === "object" && (value as BackgroundResponse).app === APP;
}

/** chrome.runtime.sendMessage with app scoping and graceful failure. */
export function sendToBackground<T = unknown>(type: string, payload?: unknown): Promise<T | null> {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage(envelope(type, payload), (response: unknown) => {
        if (chrome.runtime.lastError || !isBackgroundResponse(response)) {
          resolve(null);
          return;
        }
        resolve(response.ok ? (response.data as T) ?? null : null);
      });
    } catch {
      resolve(null);
    }
  });
}
