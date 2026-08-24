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
/** Bars in the hero's signal band — the brand's equaliser mark as a readout. */
const BAR_COUNT = 48;

const signal = document.getElementById("signal") as HTMLDivElement;
const status = document.getElementById("status") as HTMLParagraphElement;

let timer: number | null = null;

/**
 * Builds the signal band. Written here rather than in the markup so the page
 * stays readable; the bars carry no text and are hidden from assistive tech.
 * Each gets its own duration and delay so the band ripples instead of
 * pulsing as one block — `animation` is dropped wholesale under
 * `prefers-reduced-motion`, leaving a flat lime bar.
 */
function buildBars(): void {
  const host = document.getElementById("signal-bars");
  if (!host) return;
  for (let i = 0; i < BAR_COUNT; i++) {
    const bar = document.createElement("i");
    // Deterministic, not random: a fixed wave reads as a signal, and a
    // reload never reshuffles the page.
    const wave = 0.32 + 0.68 * Math.abs(Math.sin(i * 0.7));
    bar.style.height = `${Math.round(wave * 100)}%`;
    bar.style.animationDuration = `${700 + (i % 7) * 120}ms`;
    bar.style.animationDelay = `${(i % 11) * 60}ms`;
    host.appendChild(bar);
  }
}

function render(bridge: BridgeStatus | null): void {
  status.textContent = "";
  if (!bridge) {
    signal.dataset.state = "waiting";
    status.append("Waiting for HeadsetCompanion…");
    return;
  }
  signal.dataset.state = "live";
  status.append("HeadsetCompanion is running — your headset controls Sonora");

  const detail: string[] = [];
  if (bridge.deviceName) detail.push(bridge.deviceName);
  if (bridge.battery !== null) detail.push(`${bridge.battery}%`);
  if (detail.length) {
    const line = document.createElement("span");
    line.className = "signal-detail";
    line.textContent = detail.join(" · ");
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

function showVersion(): void {
  const host = document.getElementById("version");
  // Optional chaining so the page also renders outside an extension context
  // (tools/shots renders it over plain HTTP).
  const version = chrome?.runtime?.getManifest?.().version;
  if (host && version) host.textContent = `Sonora ${version}`;
}

buildBars();
showVersion();

// A welcome tab is easy to leave open in the background for hours; only poll
// while it is actually on screen.
document.addEventListener("visibilitychange", () => {
  if (document.hidden) stop();
  else start();
});

if (!document.hidden) start();
