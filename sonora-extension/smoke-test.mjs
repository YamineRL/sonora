// Renders the built popup bundle in jsdom and asserts the cockpit mounts.
import { JSDOM } from "jsdom";
import * as esbuild from "esbuild";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const bundle = readFileSync(path.join(root, "dist/popup/main.js"), "utf8");

const dom = new JSDOM(
  '<!doctype html><html><body><div id="root"></div></body></html>',
  { pretendToBeVisual: true, url: "https://example.com/" },
);
const { window } = dom;
const shims = ["window", "document", "navigator", "HTMLElement", "HTMLInputElement", "CSS", "location", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "CustomEvent", "MutationObserver", "ResizeObserver"];
for (const key of shims) {
  Object.defineProperty(globalThis, key, { value: window[key] ?? window, configurable: true, writable: true });
}
window.matchMedia = window.matchMedia || (() => ({ matches: false, addListener() {}, removeListener() {} }));

// Host/kind heuristics are pure logic — bundle the module and exercise it
// directly rather than only through the rendered popup.
const shared = await esbuild.build({
  entryPoints: [path.join(root, "shared/media-source.ts")],
  bundle: true,
  write: false,
  format: "cjs",
  platform: "neutral",
  target: "es2022",
  logLevel: "silent",
});
const sharedModule = { exports: {} };
new Function("module", "exports", shared.outputFiles[0].text)(sharedModule, sharedModule.exports);
const { detectKind, siteDisplay, sourceRowState, sourcesToPause } = sharedModule.exports;

const errors = [];
window.addEventListener("error", (e) => errors.push(String(e.error ?? e.message)));

try {
  (0, eval)(bundle);
} catch (err) {
  console.error("BUNDLE THREW:", err);
  process.exit(1);
}

await new Promise((r) => setTimeout(r, 600));

const html = window.document.getElementById("root").innerHTML;
const checks = {
  "renders cockpit": html.includes("sonora-cockpit"),
  "brand shown": html.toLowerCase().includes("sonora"),
  "source list label": html.includes("Detected sources"),
  "now controlling card": html.includes("Now controlling"),
  "play button": html.includes("mc-play") || html.includes("sp-play"),
  "settings panel": html.includes("Signal settings"),
  "shortcut hints": html.includes("play / pause"),
  "empty state (no chrome APIs)": html.includes("No audible tabs"),
  "audio output card": html.includes("Audio output"),
  "bridge status row": html.toLowerCase().includes("bridge"),
  "source list is audible-scoped": html.includes("audible or recently playing"),
  // the cockpit leads with what it controls, the source list follows
  "now card renders before the source list":
    html.indexOf("sp-now-card") >= 0 &&
    html.indexOf("sp-now-card") < html.indexOf("sp-source-list"),
  "hero heading dropped": !html.includes("Everything audible"),
  "single live-dot eyebrow": !html.includes("Listening now"),
  "bridge status sits in the topbar":
    html.indexOf("sp-bridge-line") >= 0 &&
    html.indexOf("sp-bridge-line") < html.indexOf("sp-now-card"),
  "media-keys paragraph folded into the topbar line": !html.includes("sp-media-keys"),
  "active row gets a highlight class": bundle.includes("is-active"),
  "playing rows show the equalizer": sourceRowState({ playing: true, tabMuted: false }) === "playing",
  "paused rows show a paused mark": sourceRowState({ playing: false, tabMuted: false }) === "paused",
  "tab-muted rows show a muted mark": sourceRowState({ playing: false, tabMuted: true }) === "muted",
  "tab mute beats a running element": sourceRowState({ playing: true, tabMuted: true }) === "muted",
  // One signal at a time. Pausing only the remembered source left a tab
  // that started playing on its own running under the new pick — two tabs
  // audible at once after "next".
  "switching pauses the remembered source":
    JSON.stringify(sourcesToPause([{ tabId: 1, playing: false }, { tabId: 2, playing: false }], 2, 1)) === "[1]",
  "switching pauses a source the cockpit never selected":
    JSON.stringify(sourcesToPause([{ tabId: 1, playing: true }, { tabId: 2, playing: false }], 2, null)) === "[1]",
  "switching pauses every running source":
    JSON.stringify(sourcesToPause([{ tabId: 1, playing: true }, { tabId: 2, playing: true }, { tabId: 3, playing: false }], 3, null)) === "[1,2]",
  "the new source is never paused":
    JSON.stringify(sourcesToPause([{ tabId: 1, playing: true }, { tabId: 2, playing: true }], 1, 1)) === "[2]",
  "a paused list with no previous pauses nothing":
    JSON.stringify(sourcesToPause([{ tabId: 1, playing: false }], 1, null)) === "[]",
  "clearing the source pauses everything running":
    JSON.stringify(sourcesToPause([{ tabId: 1, playing: true }, { tabId: 2, playing: false }], null, 2)) === "[1,2]",
  // ...and the switch waits for those pauses instead of firing and forgetting
  // (source-only: the worker bundle is minified, so the name is gone there)
  "the switch waits for the pauses before playing":
    readFileSync(path.join(root, "background/service-worker.ts"), "utf8").includes("await Promise.all(\n    sourcesToPause("),
  // "next" with nothing selected steps away from the tab you can hear
  "a step with no controlled source counts from what is playing":
    readFileSync(path.join(root, "background/service-worker.ts"), "utf8").includes("function stepAnchor"),
  "empty state explains the window": html.includes("paused players"),
  "sink routing select": html.includes("Route to"),
  "media-key loop survives a bridge restart": readFileSync(path.join(root, "dist/background/service-worker.js"), "utf8").includes("restarted") || readFileSync(path.join(root, "background/service-worker.ts"), "utf8").includes("The bridge restarted"),
  // held next/previous on the headset -> a 10 s skip on the active source
  "headset seek events map to a 10s skip":
    readFileSync(path.join(root, "dist/background/service-worker.js"), "utf8").includes("seek-forward") &&
    readFileSync(path.join(root, "dist/background/service-worker.js"), "utf8").includes("seek-backward") &&
    readFileSync(path.join(root, "background/service-worker.ts"), "utf8").includes("HEADSET_SEEK_STEP = 10"),
  // The bridge drops the now-playing claim when the browser has no media
  // tabs, which is only safe if the count actually reaches it — on every
  // poll, and out of band the moment a tab appears.
  "poll reports the media-source count":
    readFileSync(path.join(root, "dist/background/service-worker.js"), "utf8").includes("sources=") &&
    readFileSync(path.join(root, "background/service-worker.ts"), "utf8").includes("&sources=${mediaTabs.size}"),
  "source-count changes are reported out of band":
    readFileSync(path.join(root, "dist/background/service-worker.js"), "utf8").includes("wait=0&sources="),
  "reveal-device-names button in bundle": bundle.includes("Reveal device names"),
  "icons ship in the bundle": [16, 32, 48, 128].every((n) =>
    existsSync(path.join(root, `dist/icons/icon-${n}.png`))),
  // ...and nothing else: an undeclared icon is dead weight in the upload.
  "no undeclared icons ship": readdirSync(path.join(root, "dist/icons")).every((f) =>
    [16, 32, 48, 128].some((n) => f === `icon-${n}.png`)),
  "manifest declares the toolbar icon":
    Boolean(JSON.parse(readFileSync(path.join(root, "dist/manifest.json"), "utf8")).icons?.["128"]) &&
    Boolean(JSON.parse(readFileSync(path.join(root, "dist/manifest.json"), "utf8")).action?.default_icon?.["128"]),
  "welcome page shows the brand mark":
    readFileSync(path.join(root, "dist/popup/welcome.html"), "utf8").includes("icons/icon-128.png"),
  "permission page built": existsSync(path.join(root, "dist/popup/permission.html")) && existsSync(path.join(root, "dist/popup/permission.js")),
  "welcome page built": existsSync(path.join(root, "dist/popup/welcome.html")) && existsSync(path.join(root, "dist/popup/welcome.js")),
  // the interval literal is minified away, so read the poll period from source
  "welcome page polls the bridge every 2s":
    readFileSync(path.join(root, "popup/welcome.ts"), "utf8").includes("POLL_MS = 2000") &&
    readFileSync(path.join(root, "dist/popup/welcome.js"), "utf8").includes("setInterval"),
  "welcome page pauses while hidden": readFileSync(path.join(root, "dist/popup/welcome.js"), "utf8").includes("visibilitychange"),
  "welcome page links the dmg": readFileSync(path.join(root, "dist/popup/welcome.html"), "utf8").includes("https://github.com/YamineRL/sonora/releases/latest/download/HeadsetCompanion.dmg"),
  "welcome tab opens only on a fresh install": readFileSync(path.join(root, "dist/background/service-worker.js"), "utf8").includes("popup/welcome.html") && readFileSync(path.join(root, "background/service-worker.ts"), "utf8").includes('details.reason === "install"'),
  "permission page stops the mic tracks": readFileSync(path.join(root, "dist/popup/permission.js"), "utf8").includes("stop()"),
  // "podcast." is a label prefix, not a suffix
  "podcast label prefix matches": detectKind("podcast.example.com", false) === "podcast",
  "podcast label prefix is not a substring": detectKind("notapodcast.com", false) === "other",
  // domain entries match the domain and its subdomains, nothing else
  "podcast domain matches subdomain": detectKind("cdn.anchor.fm", false) === "podcast",
  "podcast domain is not a suffix": detectKind("notanchor.fm", false) === "other",
  "youtube detected": detectKind("www.youtube.com", false) === "youtube",
  "compound host name": siteDisplay("radio.garden") === "Radio Garden",
};
let fail = 0;
for (const [name, ok] of Object.entries(checks)) {
  console.log((ok ? "PASS" : "FAIL") + "  " + name);
  if (!ok) fail++;
}
if (errors.length) {
  console.log("Runtime errors:", errors.slice(0, 3));
  fail++;
}
process.exit(fail ? 1 : 0);
