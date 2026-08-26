// Synthesized UI sound engine - zero audio assets, everything is generated
// with the Web Audio API. Sounds are short (<150ms) and subtle: soft
// mechanical feedback, not arcade bleeps.
//
// Settings gating happens at module level (no React): we read uiSounds /
// uiSoundVolume from useSettingsStore via getState() and stay current via
// store.subscribe(). Defaults (enabled, 0.5) apply before settings load.
//
// The AudioContext is created lazily inside the first play call, which by
// construction happens after a user gesture (a click), so WebView2's
// autoplay policy never blocks us.

import { useSettingsStore } from "../stores/useSettingsStore";

export type UiSoundName = "click" | "thud" | "swoosh" | "success" | "error";

const DEFAULT_VOLUME = 0.5;
/** Floor for exponential ramps - exponentialRampToValueAtTime cannot reach 0. */
const SILENT = 0.0001;

let enabled = true;
let volume = DEFAULT_VOLUME;

let ctx: AudioContext | null = null;
let master: GainNode | null = null;
let noiseBuffer: AudioBuffer | null = null;

function clampVolume(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : DEFAULT_VOLUME;
}

function syncFromStore(state: ReturnType<typeof useSettingsStore.getState>): void {
  const prefs = state.settings?.preferences;
  if (!prefs) return; // settings not loaded yet - keep defaults
  enabled = prefs.uiSounds !== false;
  volume = clampVolume(prefs.uiSoundVolume);
  if (ctx && master) {
    // Glide rather than jump so a volume change mid-sound doesn't pop.
    master.gain.setTargetAtTime(volume, ctx.currentTime, 0.02);
  }
}

syncFromStore(useSettingsStore.getState());
useSettingsStore.subscribe(syncFromStore);

function ensureContext(): AudioContext | null {
  if (ctx) {
    if (ctx.state === "suspended") {
      void ctx.resume().catch(() => {});
    }
    return ctx;
  }
  const Ctor =
    window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!Ctor) return null;
  try {
    ctx = new Ctor();
  } catch {
    return null;
  }
  master = ctx.createGain();
  master.gain.value = volume;
  master.connect(ctx.destination);
  return ctx;
}

/** Cached white-noise buffer shared by every noise-based voice. */
function getNoise(c: AudioContext): AudioBuffer {
  if (!noiseBuffer) {
    const length = Math.floor(c.sampleRate * 0.2);
    noiseBuffer = c.createBuffer(1, length, c.sampleRate);
    const data = noiseBuffer.getChannelData(0);
    for (let i = 0; i < length; i++) data[i] = Math.random() * 2 - 1;
  }
  return noiseBuffer;
}

/** Exponential attack/decay envelope feeding the master gain - no clicks or pops. */
function envGain(c: AudioContext, at: number, peak: number, attack: number, duration: number): GainNode {
  const g = c.createGain();
  g.gain.setValueAtTime(SILENT, at);
  g.gain.exponentialRampToValueAtTime(Math.max(peak, SILENT * 2), at + attack);
  g.gain.exponentialRampToValueAtTime(SILENT, at + duration);
  g.connect(master as GainNode);
  return g;
}

interface ToneSpec {
  type?: OscillatorType;
  from: number;
  to?: number;
  peak: number;
  attack: number;
  duration: number;
  /** Optional lowpass to soften harmonically-rich waveforms (square etc). */
  lowpass?: number;
}

function tone(c: AudioContext, at: number, spec: ToneSpec): void {
  const osc = c.createOscillator();
  osc.type = spec.type ?? "sine";
  osc.frequency.setValueAtTime(spec.from, at);
  if (spec.to !== undefined && spec.to !== spec.from) {
    osc.frequency.exponentialRampToValueAtTime(spec.to, at + spec.duration);
  }
  const g = envGain(c, at, spec.peak, spec.attack, spec.duration);
  if (spec.lowpass !== undefined) {
    const filter = c.createBiquadFilter();
    filter.type = "lowpass";
    filter.frequency.value = spec.lowpass;
    osc.connect(filter);
    filter.connect(g);
  } else {
    osc.connect(g);
  }
  osc.start(at);
  osc.stop(at + spec.duration + 0.02);
}

interface NoiseSpec {
  peak: number;
  attack: number;
  duration: number;
  filterType: BiquadFilterType;
  freqFrom: number;
  freqTo?: number;
  q?: number;
}

function noiseBurst(c: AudioContext, at: number, spec: NoiseSpec): void {
  const src = c.createBufferSource();
  src.buffer = getNoise(c);
  const filter = c.createBiquadFilter();
  filter.type = spec.filterType;
  filter.frequency.setValueAtTime(spec.freqFrom, at);
  if (spec.freqTo !== undefined && spec.freqTo !== spec.freqFrom) {
    filter.frequency.exponentialRampToValueAtTime(spec.freqTo, at + spec.duration);
  }
  filter.Q.value = spec.q ?? 1;
  const g = envGain(c, at, spec.peak, spec.attack, spec.duration);
  src.connect(filter);
  filter.connect(g);
  src.start(at);
  src.stop(at + spec.duration + 0.02);
}

export function playSound(name: UiSoundName): void {
  if (!enabled || volume <= 0) return;
  const c = ensureContext();
  if (!c || !master) return;
  const t = c.currentTime + 0.001;
  try {
    switch (name) {
      case "click":
        // Soft mechanical tick: a few ms of bright noise + a tiny high blip.
        noiseBurst(c, t, { peak: 0.1, attack: 0.001, duration: 0.014, filterType: "highpass", freqFrom: 3800 });
        tone(c, t, { from: 2100, peak: 0.05, attack: 0.002, duration: 0.03 });
        break;
      case "thud":
        // Low weighty sine with a fast pitch drop - destructive/confirm cue.
        tone(c, t, { from: 110, to: 62, peak: 0.5, attack: 0.005, duration: 0.12 });
        break;
      case "swoosh":
        // Bandpass noise sweeping upward - panel/dialog opening.
        noiseBurst(c, t, {
          peak: 0.16,
          attack: 0.035,
          duration: 0.12,
          filterType: "bandpass",
          freqFrom: 450,
          freqTo: 2600,
          q: 1.2,
        });
        break;
      case "success":
        // Two quick ascending soft sines.
        tone(c, t, { from: 660, peak: 0.09, attack: 0.005, duration: 0.07 });
        tone(c, t + 0.07, { from: 880, peak: 0.09, attack: 0.005, duration: 0.08 });
        break;
      case "error":
        // Short low square-ish buzz, lowpassed so it stays gentle.
        tone(c, t, { type: "square", from: 150, to: 118, peak: 0.11, attack: 0.006, duration: 0.12, lowpass: 620 });
        break;
    }
  } catch {
    // Audio must never break the UI - swallow synth failures silently.
  }
}

const CLICKABLE_SELECTOR =
  'button, [role="button"], a, select, input[type="checkbox"], input[type="radio"], summary';

let installed = false;
let lastGlobalClickAt = 0;

/**
 * Installs one capture-phase document click listener so every existing
 * interactive control in the app gets click feedback with zero per-component
 * edits. Danger-variant Buttons (devkit-btn--danger) get 'thud' instead.
 * Debounced so one physical click (e.g. a label forwarding to its input)
 * never double-plays.
 */
export function initUiSounds(): void {
  if (installed) return;
  installed = true;
  document.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      if (!(target instanceof Element)) return;
      const interactive = target.closest(CLICKABLE_SELECTOR);
      if (!interactive) return;
      const now = performance.now();
      if (now - lastGlobalClickAt < 80) return;
      lastGlobalClickAt = now;
      playSound(interactive.closest(".devkit-btn--danger") ? "thud" : "click");
    },
    true,
  );
}
