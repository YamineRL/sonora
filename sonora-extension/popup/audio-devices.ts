/**
 * Sonora popup — audio output device enumeration.
 *
 * Chrome only exposes real labels for audiooutput devices once the
 * origin has held a microphone permission, so the list starts out
 * coarse ("Output 1"). `popup/permission.html` asks for that grant once;
 * `labelled` tells the popup whether to offer it.
 */

export interface OutputDevice {
  deviceId: string;
  label: string;
  /** false when the browser withheld the real name */
  labelled: boolean;
}

export async function enumerateOutputDevices(): Promise<OutputDevice[]> {
  const md =
    typeof navigator !== "undefined" ? navigator.mediaDevices : undefined;
  if (!md || typeof md.enumerateDevices !== "function") return [];
  try {
    const all = await md.enumerateDevices();
    return all
      .filter((d) => d.kind === "audiooutput")
      .map((d, i) => ({
        deviceId: d.deviceId,
        label: d.label || `Output ${i + 1}`,
        labelled: d.label !== "",
      }));
  } catch {
    return [];
  }
}
