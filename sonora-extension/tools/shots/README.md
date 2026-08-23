# Store screenshots

Renders the five Chrome Web Store screenshots at exactly 1280x800 into
`../../store-assets/`.

    npm run build          # tools/shots reads dist/, so build first
    python3 tools/shots/shoot.py

How it works: `fixture.html` loads the **real** popup bundle (`dist/popup/main.js`)
with a stub for the handful of extension APIs it touches — `chrome.runtime`,
`chrome.storage`, `chrome.tabs`, plus `fetch` for the loopback bridge and
`navigator.mediaDevices` for output routing. So the cockpit in each shot is the
actual UI, not a mock-up; only the data behind it is fixture data.

`stage.html` puts that cockpit on a 1280x800 canvas with the headline for each
shot, measures the cockpit's real height and fits it to the frame.

Two notes for whoever touches this next:

- The shots run over `http://127.0.0.1:8911`, not `file://`, so the stage can
  reach into the iframe (same-origin) to measure it. Start the server first:
  `python3 -m http.server 8911 --bind 127.0.0.1` from the package root.
- Headless Chrome writes the PNG and then never exits, because the cockpit
  polls on a `setInterval` and `--virtual-time-budget` never drains. `shoot.py`
  kills it once the file lands. Brave's headless mode hangs outright here and
  cannot be used.
