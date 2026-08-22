/**
 * Sonora — first-install welcome tab.
 *
 * Opened once by the service worker on a genuine install. It hands out the
 * companion app and then watches the loopback bridge itself, so the user never
 * has to reload to find out whether the app took: the first poll already shows
 * the connected state when the bridge was running before this tab opened.
 */

import { fetchBridgeStatus, type BridgeStatus } from "./bridge";

const POLL_MS = 2000;

const status = document.getElementById("status") as HTMLParagraphElement;

let timer: number | null = null;

function render(bridge: BridgeStatus | null): void {
  if (!bridge) {
    status.classList.remove("connected");
    status.textContent = "Waiting for HeadsetCompanion…";
    return;
  }
  status.classList.add("connected");
  status.textContent = "✓ HeadsetCompanion connected — your headset battery is live";
  const detail: string[] = [];
  if (bridge.deviceName) detail.push(bridge.deviceName);
  if (bridge.battery !== null) detail.push(`${bridge.battery}%`);
  if (detail.length) {
    const line = document.createElement("span");
    line.className = "device";
    line.textContent = detail.join(" — ");
    status.appendChild(line);
  }
}

async function poll(): Promise<void> {
  render(await fetchBridgeStatus());
}

function start(): void {
  if (timer !== null) return;
  void poll();
  timer = window.setInterval(() => void poll(), POLL_MS);
}

function stop(): void {
  if (timer === null) return;
  window.clearInterval(timer);
  timer = null;
}

// A welcome tab is easy to leave open in the background for hours; only poll
// while it is actually on screen.
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stop();
  else start();
});

if (!document.hidden) start();
