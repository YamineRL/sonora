/**
 * Sonora popup — local headset bridge client.
 *
 * The Swift menu-bar app (HeadsetCompanion) serves the connected Bluetooth
 * headset's battery state on loopback. We poll it with a short timeout; a
 * failed fetch simply means the bridge is not running ("bridge offline").
 */

export const BRIDGE_PORT = 8745;

/**
 * The `app` field every bridge response carries. `sonora-xm4-bridge` is the
 * pre-rename name, still accepted so an older bridge keeps working.
 */
export const BRIDGE_APP_NAMES = ["headset-companion", "sonora-xm4-bridge"];

export function isBridgeApp(app: unknown): boolean {
  return typeof app === "string" && BRIDGE_APP_NAMES.includes(app);
}

export interface BridgeStatus {
  app: string;
  version: string;
  port: number;
  connected: boolean;
  deviceName: string | null;
  battery: number | null;
  lastUpdate: string | null;
  uptime: number | null;
  /** the bridge is forwarding media keys / headset taps to Sonora */
  mediaKeys: boolean;
}

const BRIDGE_URLS = [
  `http://127.0.0.1:${BRIDGE_PORT}/battery`,
  `http://localhost:${BRIDGE_PORT}/battery`,
];

function isBridgeStatus(value: unknown): value is BridgeStatus {
  return (
    !!value &&
    typeof value === "object" &&
    isBridgeApp((value as { app?: unknown }).app)
  );
}

export async function fetchBridgeStatus(timeoutMs = 900): Promise<BridgeStatus | null> {
  if (typeof fetch !== "function") return null;
  for (const url of BRIDGE_URLS) {
    const controller = new AbortController();
    const timer = window.setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(url, { signal: controller.signal });
      if (!res.ok) continue;
      const raw: unknown = await res.json();
      const d = raw as unknown as Record<string, unknown> | null;
      if (!d || !isBridgeApp(d.app)) return null;
      return {
        app: String(d.app),
        version: typeof d.version === "string" ? d.version : "0.0.0",
        port: typeof d.port === "number" ? d.port : BRIDGE_PORT,
        connected: !!d.connected,
        deviceName: typeof d.deviceName === "string" ? d.deviceName : null,
        battery: typeof d.battery === "number" ? d.battery : null,
        lastUpdate: typeof d.lastUpdate === "string" ? d.lastUpdate : null,
        uptime: typeof d.uptime === "number" ? d.uptime : null,
        // Older bridges predate media-key forwarding — absent means off.
        mediaKeys: d.mediaKeys === true,
      };
    } catch {
      continue;
    } finally {
      window.clearTimeout(timer);
    }
  }
  return null;
}

/** A reading older than this is shown as stale — the bridge keeps serving the
 *  last level it saw when macOS stops reporting one, which can be hours old. */
export const STALE_AFTER_MS = 15 * 60 * 1000;

/** Age of a bridge reading in ms, or null when the timestamp is missing/invalid. */
export function readingAgeMs(lastUpdate: string | null, now = Date.now()): number | null {
  if (!lastUpdate) return null;
  const t = Date.parse(lastUpdate);
  return Number.isNaN(t) ? null : Math.max(0, now - t);
}

/** "3m" / "6h" / "2d" style label for a reading age. */
export function formatAge(ms: number): string {
  const m = Math.floor(ms / 60000);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}
