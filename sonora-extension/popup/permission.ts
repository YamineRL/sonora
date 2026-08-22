/**
 * Sonora — one-time microphone grant.
 *
 * `enumerateDevices()` returns blank labels until the origin has held a
 * microphone permission once; after a single granted `getUserMedia` the
 * popup's output selector shows real device names. Runs in its own tab
 * because a permission prompt cannot be shown from an action popup.
 */

const note = document.getElementById("status") as HTMLParagraphElement;
const ask = document.getElementById("ask") as HTMLButtonElement;

ask.addEventListener("click", async () => {
  ask.disabled = true;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((t) => t.stop());
    const outputs = (await navigator.mediaDevices.enumerateDevices()).filter(
      (d) => d.kind === "audiooutput" && d.label,
    );
    note.textContent = `Done — ${outputs.length} named output device(s). Reopen the Sonora popup; you can close this tab.`;
  } catch (error) {
    ask.disabled = false;
    note.textContent = `Permission not granted (${(error as Error).name}). Sonora keeps working with unnamed outputs.`;
  }
});
