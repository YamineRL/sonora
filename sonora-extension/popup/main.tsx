/**
 * Sonora popup — the media cockpit UI.
 *
 * Same visual language as the mockup prototype, but every control is
 * wired to the real extension: sources come from live content-script
 * state, and playback commands go through the background worker to
 * the tab's actual media element.
 */
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { createRoot } from "react-dom/client";
import {
  AudioLines,
  BatteryMedium,
  ChevronRight,
  Command,
  Headphones,
  Keyboard,
  Mic2,
  Pause,
  Play,
  Radio,
  Search,
  Settings2,
  SkipBack,
  SkipForward,
  SlidersHorizontal,
  Volume2,
  VolumeX,
  Youtube,
  X,
  Zap,
} from "lucide-react";

import { MessageType, sendToBackground, type PlaybackCommand } from "../shared/messages";
import { sourceRowState, type MediaSource, type SourceRowState } from "../shared/media-source";
import { type SonoraSettings } from "../shared/storage";

import {
  fetchBridgeStatus,
  formatAge,
  readingAgeMs,
  STALE_AFTER_MS,
  type BridgeStatus,
} from "./bridge";
import { enumerateOutputDevices, type OutputDevice } from "./audio-devices";

import "./popup.css";

interface CockpitState {
  sources: MediaSource[];
  activeTabId: number | null;
  settings: SonoraSettings;
}

const POLL_MS = 1500;
const SEEK_STEP = 15;
/** Audio-output device list (local API; cheap). */
const DEVICE_POLL_MS = 3000;
/**
 * XM4 battery bridge (loopback HTTP). Headphone batteries move slowly, so
 * refresh every 10 minutes — with an immediate first fetch when the popup
 * opens, so the value shown is always current at open time.
 */
const BRIDGE_POLL_MS = 10 * 60_000;

const formatTime = (seconds: number): string => {
  const safe = Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
  const mins = Math.floor(safe / 60);
  const secs = Math.floor(safe % 60);
  return `${mins}:${secs.toString().padStart(2, "0")}`;
};

function SourceIcon({ source, size = 15 }: { source: MediaSource; size?: number }) {
  if (source.kind === "youtube") return <Youtube size={size} strokeWidth={2.2} />;
  if (source.kind === "podcast") return <Mic2 size={size} strokeWidth={2.2} />;
  if (source.kind === "radio") return <Radio size={size} strokeWidth={2.2} />;
  return <AudioLines size={size} strokeWidth={2.2} />;
}

function Equalizer() {
  return (
    <span className="sp-eq" aria-label="Playing">
      <i />
      <i />
      <i />
    </span>
  );
}

/** Right-hand glyph of a source row: what the source is doing right now. */
function SourceRowMark({ state }: { state: SourceRowState }) {
  if (state === "playing") return <Equalizer />;
  return (
    <span className={`sp-source-state is-${state}`} aria-label={state === "muted" ? "Tab muted" : "Paused"}>
      {state === "muted" ? <VolumeX size={13} /> : <Pause size={12} fill="currentColor" />}
    </span>
  );
}

export function SonoraCockpit() {
  const [state, setState] = useState<CockpitState | null>(null);
  const [commandOpen, setCommandOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [seekLocal, setSeekLocal] = useState<number | null>(null);
  const [volumeLocal, setVolumeLocal] = useState<number | null>(null);
  const [devices, setDevices] = useState<OutputDevice[]>([]);
  const [bridge, setBridge] = useState<BridgeStatus | null>(null);
  const [bridgeOnline, setBridgeOnline] = useState(false);
  const commandInputRef = useRef<HTMLInputElement>(null);
  const settingsPanelRef = useRef<HTMLElement>(null);
  /** the user picked a source in this popup session (see activeSource) */
  const userPicked = useRef(false);
  const seekTimer = useRef<number | null>(null);
  const volumeTimer = useRef<number | null>(null);

  const refresh = useCallback(async () => {
    const data = await sendToBackground<CockpitState>(MessageType.GetState);
    if (data) setState(data);
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), POLL_MS);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const sources = useMemo(() => state?.sources ?? [], [state]);
  const audible = useMemo(() => sources.filter((s) => s.audible), [sources]);

  const activeSource = useMemo(() => {
    if (!state) return null;
    // "Resume last source" off: ignore the remembered tab until the user
    // picks one here, so opening the cockpit does not adopt a stale source.
    const remembered =
      state.settings.resumeLastSource || userPicked.current
        ? sources.find((s) => s.tabId === state.activeTabId)
        : undefined;
    return remembered ?? sources.find((s) => s.playing) ?? sources[0] ?? null;
  }, [state, sources]);

  const settings: SonoraSettings | null = state?.settings ?? null;

  /* ------------------------------------------------------------- */
  /* Commands                                                        */
  /* ------------------------------------------------------------- */

  const sendCommand = useCallback((tabId: number, command: PlaybackCommand) => {
    void sendToBackground(MessageType.SendCommand, { tabId, command });
  }, []);

  const patchSource = useCallback(
    (tabId: number, patch: Partial<MediaSource>) => {
      setState((cur) =>
        cur
          ? {
              ...cur,
              sources: cur.sources.map((s) => (s.tabId === tabId ? { ...s, ...patch } : s)),
            }
          : cur,
      );
    },
    [],
  );

  const togglePlay = useCallback(() => {
    if (!activeSource) return;
    sendCommand(activeSource.tabId, { type: "toggle" });
    patchSource(activeSource.tabId, { playing: !activeSource.playing });
    window.setTimeout(() => void refresh(), 500);
  }, [activeSource, patchSource, refresh, sendCommand]);

  const selectSource = useCallback(
    (tabId: number) => {
      userPicked.current = true;
      setState((cur) =>
        cur
          ? {
              ...cur,
              activeTabId: tabId,
              // One signal at a time: the background pauses every other
              // running source, not just the one that was controlled, so
              // the optimistic list must clear them all — otherwise a tab
              // that started playing on its own keeps its equalizer until
              // the refresh lands.
              sources: cur.sources.map((s) => ({ ...s, playing: s.tabId === tabId })),
            }
          : cur,
      );
      void sendToBackground<MediaSource>(MessageType.SetActive, { tabId });
      window.setTimeout(() => void refresh(), 700);
    },
    [refresh],
  );

  const seekBy = useCallback(
    (by: number) => {
      if (!activeSource || activeSource.live) return;
      const next = Math.min(activeSource.duration, Math.max(0, activeSource.position + by));
      sendCommand(activeSource.tabId, { type: "seek", to: next });
      patchSource(activeSource.tabId, { position: next });
      window.setTimeout(() => void refresh(), 400);
    },
    [activeSource, patchSource, refresh, sendCommand],
  );

  const onSeek = useCallback(
    (value: number) => {
      if (!activeSource) return;
      setSeekLocal(value);
      patchSource(activeSource.tabId, { position: value });
      if (seekTimer.current) window.clearTimeout(seekTimer.current);
      seekTimer.current = window.setTimeout(() => {
        setSeekLocal(null);
        sendCommand(activeSource.tabId, { type: "seek", to: value });
        window.setTimeout(() => void refresh(), 400);
      }, 300);
    },
    [activeSource, patchSource, refresh, sendCommand],
  );

  const effectiveVolume = (isMuted: boolean, volume: number): number => (isMuted ? 0 : volume);

  const onVolume = useCallback(
    (value: number) => {
      if (!activeSource || !settings) return;
      setVolumeLocal(value);
      patchSource(activeSource.tabId, { volume: value / 100, muted: false });
      if (volumeTimer.current) window.clearTimeout(volumeTimer.current);
      volumeTimer.current = window.setTimeout(() => {
        setVolumeLocal(null);
        sendCommand(activeSource.tabId, { type: "volume", value: value / 100 });
        if (settings.volume !== value || settings.muted) {
          void sendToBackground<SonoraSettings>(MessageType.SaveSettings, {
            ...settings,
            volume: value,
            muted: false,
          });
        }
        window.setTimeout(() => void refresh(), 400);
      }, 250);
    },
    [activeSource, patchSource, refresh, sendCommand, settings],
  );

  const toggleMute = useCallback(() => {
    if (!activeSource || !settings) return;
    const muted = !activeSource.muted;
    sendCommand(activeSource.tabId, { type: "mute", muted });
    patchSource(activeSource.tabId, { muted });
    void sendToBackground<SonoraSettings>(MessageType.SaveSettings, {
      ...settings,
      muted,
    });
  }, [activeSource, patchSource, sendCommand, settings]);

  const updateSettings = useCallback(
    (patch: Partial<SonoraSettings>) => {
      if (!settings) return;
      const next = { ...settings, ...patch };
      setState((cur) => (cur ? { ...cur, settings: next } : cur));
      // The worker owns "keep tabs awake" (chrome.tabs.autoDiscardable):
      // it re-applies the setting to every source on save.
      void sendToBackground<SonoraSettings>(MessageType.SaveSettings, next);
    },
    [settings],
  );

  // Audio-output devices for the sink selector (local API, light poll).
  useEffect(() => {
    let active = true;
    const load = () => {
      void enumerateOutputDevices().then((list) => {
        if (active) setDevices(list);
      });
    };
    load();
    const timer = window.setInterval(load, DEVICE_POLL_MS);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, []);

  // XM4 battery bridge on loopback: fetch immediately on open, then every
  // 10 minutes (the battery barely moves; a slow refresh keeps it current
  // without chattering at the bridge).
  useEffect(() => {
    let active = true;
    const load = () => {
      void fetchBridgeStatus().then((status) => {
        if (!active) return;
        setBridge(status);
        setBridgeOnline(status !== null);
      });
    };
    load();
    const timer = window.setInterval(load, BRIDGE_POLL_MS);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, []);

  /* ------------------------------------------------------------- */
  /* Keyboard                                                        */
  /* ------------------------------------------------------------- */

  useEffect(() => {
    if (!commandOpen) return;
    commandInputRef.current?.focus();
  }, [commandOpen]);

  // The popup is a 600px scroll container and the settings panel sits at the
  // bottom, so opening it from the top bar must bring it into view.
  useEffect(() => {
    if (!settingsOpen) return;
    settingsPanelRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }, [settingsOpen]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const inField = event.target instanceof HTMLInputElement;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setCommandOpen((open) => !open);
        return;
      }
      if (event.key === "Escape") {
        setCommandOpen(false);
        setSettingsOpen(false);
        return;
      }
      if (inField) return;
      if (event.key === " ") {
        event.preventDefault();
        togglePlay();
      } else if (event.key === "ArrowLeft") {
        event.preventDefault();
        seekBy(-SEEK_STEP);
      } else if (event.key === "ArrowRight") {
        event.preventDefault();
        seekBy(SEEK_STEP);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [togglePlay, seekBy]);

  /* ------------------------------------------------------------- */
  /* Render                                                          */
  /* ------------------------------------------------------------- */

  const position = seekLocal ?? activeSource?.position ?? 0;
  const duration = activeSource?.duration ?? 0;
  const progress = activeSource && duration > 0 ? Math.round((position / duration) * 100) : 0;

  const activeState = activeSource ? sourceRowState(activeSource) : null;
  /** headphone battery, only when the bridge answers and a device is paired */
  const batteryPct =
    bridgeOnline && bridge && bridge.connected && bridge.battery !== null ? bridge.battery : null;
  /** how old that reading is; the bridge re-serves its last level when macOS stops reporting one */
  const batteryAgeMs = batteryPct !== null ? readingAgeMs(bridge?.lastUpdate ?? null) : null;
  const batteryStale = batteryAgeMs !== null && batteryAgeMs > STALE_AFTER_MS;

  const isMuted = activeSource?.muted ?? false;
  const volume =
    volumeLocal ?? (activeSource ? Math.round(activeSource.volume * 100) : settings?.volume ?? 0);

  const filteredSources = sources.filter((source) =>
    // The artist joins the haystack now that it is on the row: a channel
    // name you can read is a channel name you will try to search for.
    `${source.siteName} ${source.title} ${source.artist ?? ""}`
      .toLowerCase()
      .includes(search.toLowerCase()),
  );
  const waveHeights = [22, 42, 30, 63, 36, 76, 51, 29, 88, 48, 36, 68, 28, 58, 39, 74, 46, 23, 61, 34, 84, 42, 27, 65, 45, 74, 32];

  return (
    <main className={`sonora-cockpit ${activeSource?.playing ? "is-playing" : ""}`}>
      <div className="sp-surface">
        <header className="sp-topbar">
          <div className="sp-topbar-main">
            <div className="sp-brand">
              <div className="sp-brand-mark">
                <AudioLines size={16} />
              </div>
              <span className="sp-brand-name">sonora</span>
              <span className="sp-brand-note">browser media cockpit</span>
            </div>
            <div className="sp-top-actions">
              <button className="sp-key-button" type="button" onClick={() => setCommandOpen(true)}>
                <Command size={12} /> <span>⌘ K</span>
              </button>
              <button
                className="sp-icon-button"
                type="button"
                aria-label="Open settings"
                onClick={() => setSettingsOpen((open) => !open)}
              >
                <Settings2 size={15} />
              </button>
            </div>
          </div>
          <p
            className={`sp-bridge-line ${bridgeOnline ? "" : "is-offline"}`}
            title={
              bridgeOnline
                ? bridge?.deviceName ?? "HeadsetCompanion"
                : "Run HeadsetCompanion (menu bar) to show battery and headset taps"
            }
          >
            {bridgeOnline ? (
              <>
                {batteryPct !== null ? (
                  <span
                    className={`sp-battery ${batteryStale ? "is-stale" : ""}`}
                    title={
                      batteryStale
                        ? `Last level macOS reported, ${formatAge(batteryAgeMs ?? 0)} ago — the headset is not reporting battery right now`
                        : undefined
                    }
                  >
                    <BatteryMedium size={12} />
                    <span>{batteryPct}%</span>
                    {batteryStale && <span>· {formatAge(batteryAgeMs ?? 0)} ago</span>}
                  </span>
                ) : (
                  <>
                    <Headphones size={12} />
                    <span>no headphones</span>
                  </>
                )}
                <span>· keys: {bridge?.mediaKeys ? "Sonora" : "off"}</span>
              </>
            ) : (
              <span>bridge offline</span>
            )}
          </p>
        </header>

        <section className="sp-now-card">
          <div className="sp-now-topline">
            <p className="sp-eyebrow">
              <span className={`sp-live-dot ${activeSource?.playing ? "" : "is-idle"}`} /> Now
              controlling
            </p>
            <span className="sp-now-topline-tags">
              {activeState && activeState !== "playing" && (
                <span className="sp-now-state">{activeState === "muted" ? "Muted" : "Paused"}</span>
              )}
              {activeSource && (
                <span className="sp-source-chip">
                  <SourceIcon source={activeSource} size={12} /> {activeSource.siteName}
                </span>
              )}
            </span>
          </div>
          <div className="sp-now-content">
            <div>
              <h2 className="sp-now-title">{activeSource?.title ?? "Nothing playing"}</h2>
              {activeSource ? (
                activeSource.description && (
                  <p className="sp-now-description">{activeSource.description}</p>
                )
              ) : (
                <p className="sp-now-description">Switch to a source to start a signal.</p>
              )}
            </div>
            <div className="sp-wave" aria-hidden="true">
              {waveHeights.map((height, index) => (
                <span key={index} style={{ "--wave-height": `${height}%` } as CSSProperties} />
              ))}
            </div>
          </div>
          <div className="sp-player">
            <input
              className="sp-progress"
              type="range"
              min="0"
              max={Math.max(1, Math.floor(duration))}
              value={Math.min(position, Math.max(1, Math.floor(duration)))}
              onChange={(event) => onSeek(Number(event.target.value))}
              disabled={!activeSource || activeSource.live || duration === 0}
              style={{ "--progress": `${progress}%` } as CSSProperties}
              aria-label="Seek through current media"
            />
            <div className="sp-time">
              <span>{formatTime(position)}</span>
              <span>{activeSource?.live ? "LIVE" : formatTime(duration)}</span>
            </div>
            <div className="sp-player-controls">
              <div className="sp-control-group">
                <button
                  className="sp-small-icon"
                  type="button"
                  aria-label="Skip back 15 seconds"
                  onClick={() => seekBy(-SEEK_STEP)}
                  disabled={!activeSource || activeSource.live}
                >
                  <SkipBack size={15} />
                </button>
                <button
                  className="sp-play"
                  type="button"
                  aria-label={activeSource?.playing ? "Pause" : "Play"}
                  onClick={togglePlay}
                  disabled={!activeSource}
                >
                  {activeSource?.playing ? <Pause size={16} fill="currentColor" /> : <Play size={16} fill="currentColor" />}
                </button>
                <button
                  className="sp-small-icon"
                  type="button"
                  aria-label="Skip forward 15 seconds"
                  onClick={() => seekBy(SEEK_STEP)}
                  disabled={!activeSource || activeSource.live}
                >
                  <SkipForward size={15} />
                </button>
              </div>
              <div className="sp-volume-wrap">
                <button
                  className="sp-small-icon"
                  type="button"
                  aria-label={isMuted ? "Unmute" : "Mute"}
                  onClick={toggleMute}
                  disabled={!activeSource}
                >
                  {isMuted || volume === 0 ? <VolumeX size={15} /> : <Volume2 size={15} />}
                </button>
                <input
                  className="sp-volume"
                  type="range"
                  min="0"
                  max="100"
                  value={effectiveVolume(isMuted, volume)}
                  onChange={(event) => onVolume(Number(event.target.value))}
                  disabled={!activeSource}
                  style={{ "--volume": `${effectiveVolume(isMuted, volume)}%` } as CSSProperties}
                  aria-label="Volume"
                />
              </div>
            </div>
            <div className="sp-shortcuts-row">
              <span><kbd>Space</kbd> play / pause</span>
              <span><kbd>←</kbd> <kbd>→</kbd> seek</span>
              <span><kbd>⌘ K</kbd> switch source</span>
            </div>
          </div>
        </section>

        <div className="sp-source-list">
          <p className="sp-list-label">
            Detected sources · {sources.length} audible or recently playing
          </p>
          {sources.length === 0 && (
            <div className="sp-empty">
              <span>No audible tabs detected.</span>
              <small>
                Sonora lists tabs playing audio right now, plus paused players it has
                seen since the browser started.
              </small>
            </div>
          )}
          {sources.map((source) => (
            <button
              className={`sp-source-button ${source.tabId === activeSource?.tabId ? "is-active" : ""}`}
              key={source.tabId}
              type="button"
              onClick={() => selectSource(source.tabId)}
              aria-pressed={source.tabId === activeSource?.tabId}
            >
              <span className={`sp-source-logo ${source.kind}`}>
                <SourceIcon source={source} size={14} />
              </span>
              {/*
                The logo to the left already says which site this is, so the
                strong line spends itself on what actually tells two sources
                apart — the video or episode title. The site name stays as the
                subtitle for sources that publish no artist, so a row never
                loses its origin entirely. Both lines truncate in CSS rather
                than by slicing: a hard cut mid-word with no ellipsis reads as
                a broken title rather than a shortened one.
              */}
              <span className="sp-source-info">
                <span className="sp-source-name">{source.title}</span>
                <span className="sp-source-meta">{source.artist ?? source.siteName}</span>
              </span>
              <SourceRowMark state={sourceRowState(source)} />
            </button>
          ))}
        </div>

        <div className="sp-bottom-grid">
          <section className="sp-panel" ref={settingsPanelRef}>
            <div className="sp-panel-header">
              <h3 className="sp-panel-title">Signal settings</h3>
              <SlidersHorizontal size={14} />
            </div>
            {settingsOpen ? (
              <div className="sp-settings">
                <span className="sp-panel-kicker">Personal defaults</span>
                <div className="sp-setting-row">
                  <span>Resume last source</span>
                  <button
                    type="button"
                    className={`sp-switch ${(settings?.resumeLastSource ?? true) ? "" : "is-off"}`}
                    aria-label="Toggle resume last source"
                    onClick={() => updateSettings({ resumeLastSource: !(settings?.resumeLastSource ?? true) })}
                  />
                </div>
                <div className="sp-setting-row">
                  <span>Keep tabs awake</span>
                  <button
                    type="button"
                    className={`sp-switch ${(settings?.keepTabsAwake ?? false) ? "" : "is-off"}`}
                    aria-label="Toggle keep tabs awake"
                    onClick={() => updateSettings({ keepTabsAwake: !(settings?.keepTabsAwake ?? false) })}
                  />
                </div>
              </div>
            ) : (
              <div className="sp-signal-list">
                <div className="sp-signal">
                  <span className="sp-signal-icon"><Zap size={12} /></span>
                  <span className="sp-signal-copy"><strong>Shortcut ready</strong>Alt + M toggles the active source</span>
                </div>
                <div className="sp-signal">
                  <span className="sp-signal-icon"><Keyboard size={12} /></span>
                  <span className="sp-signal-copy"><strong>Keyboard control</strong>Space toggles playback in the cockpit</span>
                </div>
                <button className="sp-command-item" type="button" onClick={() => setSettingsOpen(true)}>
                  <Settings2 size={12} /> Personalize cockpit <ChevronRight size={12} />
                </button>
              </div>
            )}
          </section>

          <section className="sp-panel sp-headphone-card" aria-label="Audio output">
            <div className="sp-panel-header">
              <h3 className="sp-panel-title">Audio output</h3>
              <Headphones size={13} />
            </div>
            {(() => {
              const sinkDevice = devices.find((d) => d.deviceId === activeSource?.sinkId);
              const unlabelled = devices.length > 0 && devices.every((d) => !d.labelled);
              const defaultName =
                bridge?.connected && bridge.deviceName ? bridge.deviceName : "System default";
              return (
                <div className="sp-device-stack">
                  <div className="sp-headphone-row">
                    <span className="sp-headphone-name">
                      {sinkDevice?.label ?? defaultName}
                      <small>{sinkDevice ? "Browser output device" : "System default output"}</small>
                    </span>
                    <span className={`sp-headphone-status ${activeSource?.playing ? "is-live" : ""}`}>
                      {activeSource?.playing ? "Signal live" : "Standing by"}
                    </span>
                  </div>
                  <select
                    className="sp-device-select"
                    value={activeSource?.sinkId ?? ""}
                    disabled={!activeSource || devices.length === 0}
                    onChange={(event) => {
                      if (activeSource && event.target.value) {
                        sendCommand(activeSource.tabId, { type: "sink", deviceId: event.target.value });
                      }
                    }}
                    aria-label="Route audio to an output device"
                  >
                    <option value="">Route to…</option>
                    {devices.map((d) => (
                      <option key={d.deviceId} value={d.deviceId}>
                        {d.label}
                      </option>
                    ))}
                  </select>
                  {unlabelled && (
                    <button
                      className="sp-command-item"
                      type="button"
                      onClick={() =>
                        chrome.tabs.create({ url: chrome.runtime.getURL("popup/permission.html") })
                      }
                    >
                      <Headphones size={12} /> Reveal device names <ChevronRight size={12} />
                    </button>
                  )}
                </div>
              );
            })()}
          </section>
        </div>
      </div>

      {commandOpen && (
        <>
          <button
            className="sp-command-backdrop"
            type="button"
            aria-label="Close command palette"
            onClick={() => setCommandOpen(false)}
          />
          <div className="sp-command" role="dialog" aria-label="Command palette">
            <div className="sp-command-search">
              <Search size={15} />
              <input
                ref={commandInputRef}
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && filteredSources.length > 0) {
                    selectSource(filteredSources[0].tabId);
                    setCommandOpen(false);
                    setSearch("");
                  }
                }}
                placeholder="Switch to a source…"
              />
              <button className="sp-small-icon" type="button" aria-label="Close command palette" onClick={() => setCommandOpen(false)}>
                <X size={14} />
              </button>
            </div>
            <div className="sp-command-body">
              <div className="sp-command-label">Sources · {audible.length} audible</div>
              {filteredSources.map((source) => (
                <button
                  className="sp-command-item"
                  type="button"
                  key={source.tabId}
                  onClick={() => {
                    selectSource(source.tabId);
                    setCommandOpen(false);
                    setSearch("");
                  }}
                >
                  <SourceIcon source={source} size={14} />
                  <span className="sp-command-text">
                    {source.title}{" "}
                    <span className="sp-command-detail">· {source.artist ?? source.siteName}</span>
                  </span>
                  {source.tabId === activeSource?.tabId && <span className="sp-command-active">Active</span>}
                </button>
              ))}
              {filteredSources.length === 0 && <div className="sp-command-label">No audible source matches</div>}
            </div>
          </div>
        </>
      )}
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(<SonoraCockpit />);
