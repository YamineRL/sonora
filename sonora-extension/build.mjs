#!/usr/bin/env node
/**
 * Sonora extension build.
 *
 * Bundles the three extension entry points (background service worker,
 * content script, React popup) with esbuild, then copies the static
 * assets (manifest, content css, popup html) so `dist/` is a fully
 * loadable unpacked extension.
 *
 *   npm run build     one-shot build
 *   npm run watch     rebuild on change
 */
import { build, context } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(root, "dist");
const watch = process.argv.includes("--watch");

const entries = [
  { entry: "background/service-worker.ts", out: "background/service-worker.js" },
  { entry: "content/media-controller.ts", out: "content/media-controller.js" },
  { entry: "popup/main.tsx", out: "popup/main.js", jsx: "automatic" },
  { entry: "popup/permission.ts", out: "popup/permission.js" },
  { entry: "popup/welcome.ts", out: "popup/welcome.js" },
];

function copyStatic() {
  rmSync(dist, { recursive: true, force: true });
  mkdirSync(dist, { recursive: true });
  cpSync(path.join(root, "manifest.json"), path.join(dist, "manifest.json"));
  // Toolbar / store / welcome-page icons: the popup's lime brand mark as PNGs.
  cpSync(path.join(root, "icons"), path.join(dist, "icons"), { recursive: true });
  mkdirSync(path.join(dist, "content"), { recursive: true });
  cpSync(path.join(root, "content", "content.css"), path.join(dist, "content", "content.css"));
  mkdirSync(path.join(dist, "popup"), { recursive: true });
  cpSync(path.join(root, "popup", "index.html"), path.join(dist, "popup", "index.html"));
  cpSync(path.join(root, "popup", "permission.html"), path.join(dist, "popup", "permission.html"));
  cpSync(path.join(root, "popup", "welcome.html"), path.join(dist, "popup", "welcome.html"));
}

const options = entries.map((e) => ({
  entryPoints: [path.join(root, e.entry)],
  outfile: path.join(dist, e.out),
  tsconfig: path.join(root, "tsconfig.json"),
  bundle: true,
  format: "iife",
  minify: true,
  target: "es2022",
  platform: "browser",
  logLevel: "info",
  ...(e.jsx ? { jsx: "automatic" } : {}),
}));

if (watch) {
  copyStatic();
  const contexts = await Promise.all(options.map((o) => context(o)));
  await Promise.all(contexts.map((c) => c.watch()));
  console.log("[sonora] watching for changes — load dist/ in chrome://extensions");
} else {
  copyStatic();
  await Promise.all(options.map((o) => build(o)));
  console.log(`[sonora] built extension to ${path.relative(process.cwd(), dist)}/`);
}
