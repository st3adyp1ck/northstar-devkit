import { useCallback, useEffect, useRef, useState } from "react";
import { motion, type Transition } from "framer-motion";
import clsx from "clsx";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getVersion } from "@tauri-apps/api/app";
import { openUrl } from "@tauri-apps/plugin-opener";
import { RailIcon, normalizeIconTheme, type IconTheme, type RailIconName } from "../flyouts/railIcons";
import { useSettingsStore } from "../../stores/useSettingsStore";
import { useUpdaterStore } from "../../stores/useUpdaterStore";
import { THEMES, getThemePreset, type ThemePreset } from "../../lib/themes";
import { clampUiScale, previewUiScale, useAnimationsEnabled } from "../../hooks/useApplyAppearance";
import { playSound } from "../../lib/sounds";
import type { DevKitPreferences } from "../../lib/types";
import { Button } from "../primitives/Button";
import { GlassPanel } from "../primitives/GlassPanel";
import brand from "../../assets/brand.png";
import "./SettingsDialog.css";

const REPO_URL = "https://github.com/st3adyp1ck/northstar-devkit";

type SectionId = "appearance" | "terminal" | "sound" | "behavior" | "about";

const SECTIONS: { id: SectionId; label: string }[] = [
  { id: "appearance", label: "Appearance" },
  { id: "terminal", label: "Terminal" },
  { id: "sound", label: "Sound" },
  { id: "behavior", label: "Behavior" },
  { id: "about", label: "About" },
];

/**
 * Safe font stacks for the select. `value` is what gets persisted to
 * settings.preferences.fontFamily (null = the tokens.css default);
 * useApplyAppearance writes it to --font-sans verbatim when it already
 * carries fallbacks (has commas), which all of these do.
 */
const FONT_PRESETS: { key: string; label: string; value: string | null }[] = [
  { key: "default", label: "Segoe UI Variable (default)", value: null },
  { key: "inter", label: "Inter (if installed)", value: 'Inter, "Segoe UI Variable", "Segoe UI", system-ui, sans-serif' },
  { key: "system-ui", label: "System UI", value: "system-ui, sans-serif" },
  { key: "cascadia", label: "Cascadia Code", value: '"Cascadia Code", "Cascadia Mono", Consolas, monospace' },
];

// ---------------------------------------------------------------------------
// Icon rail - style previews and size bounds
// ---------------------------------------------------------------------------

const ICON_STYLES: { id: IconTheme; label: string }[] = [
  { id: "outline", label: "Outline" },
  { id: "solid", label: "Solid" },
  { id: "duotone", label: "Duotone" },
];

/** The rail's own tabs, in rail order - the picker previews the real thing, not a mock-up. */
const PREVIEW_ICONS: RailIconName[] = ["git", "terminal", "files", "notes"];

/** Slider bounds for the rail. `fallback` matches Get-DevKitSettings in tools/lib/DevKit-Common.ps1. */
const RAIL_WIDTH_BOUNDS = { min: 32, max: 72, step: 2, fallback: 44 };
const RAIL_ICON_BOUNDS = { min: 12, max: 28, step: 1, fallback: 18 };

/** settings.json is hand-editable, so nothing reaches a slider (or a preview) unclamped. */
function clampRail(value: number, bounds: { min: number; max: number; fallback: number }): number {
  if (!Number.isFinite(value)) return bounds.fallback;
  return Math.min(bounds.max, Math.max(bounds.min, Math.round(value)));
}

type UpdateFn = (patch: Partial<DevKitPreferences>) => Promise<void>;
type QueueFn = (patch: Partial<DevKitPreferences>) => void;

interface SectionProps {
  prefs: DevKitPreferences;
  update: UpdateFn;
}

/**
 * Debounced settings writer for continuous controls (sliders, the color
 * picker) - every drag tick would otherwise be its own settings.set RPC
 * round-trip through the sidecar. Coalesces patches and saves 250ms after
 * the last change; flushes any straggler when the dialog unmounts so a
 * drag-then-immediately-close never loses the final value.
 */
function useDebouncedPreferenceUpdate(): QueueFn {
  const update = useSettingsStore((s) => s.update);
  const pending = useRef<Partial<DevKitPreferences>>({});
  const timer = useRef<number | null>(null);

  const flush = useCallback(() => {
    if (timer.current !== null) {
      window.clearTimeout(timer.current);
      timer.current = null;
    }
    const patch = pending.current;
    pending.current = {};
    if (Object.keys(patch).length > 0) void update(patch);
  }, [update]);

  const queue = useCallback<QueueFn>(
    (patch) => {
      pending.current = { ...pending.current, ...patch };
      if (timer.current !== null) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(flush, 250);
    },
    [flush],
  );

  // Unmount cleanup IS a flush - pending work saves instead of vanishing.
  useEffect(() => flush, [flush]);

  return queue;
}

/**
 * The app's full Settings panel - rendered from TitleBar so both windows
 * have it, as a modal over whichever window opened it. Same overlay +
 * GlassPanel + spring-in family as ConfirmDialog/ToolRunDialog, just wider
 * and sectioned with a left nav. Every control persists through
 * useSettingsStore.update() and applies live via useApplyAppearance.
 */
export function SettingsDialog({ onClose }: { onClose: () => void }) {
  const settings = useSettingsStore((s) => s.settings);
  const settingsError = useSettingsStore((s) => s.error);
  const update = useSettingsStore((s) => s.update);
  const queue = useDebouncedPreferenceUpdate();
  // Not framer's useReducedMotion(): that reads the OS media query only, and
  // this dialog animates opacity+scale, which MotionConfig's reducedMotion
  // never snaps. Without this the "Animations" toggle below wouldn't apply
  // to the very dialog it lives in.
  const animationsEnabled = useAnimationsEnabled();
  const [section, setSection] = useState<SectionId>("appearance");

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const overlayTransition: Transition = animationsEnabled ? { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] } : { duration: 0 };
  const panelTransition: Transition = animationsEnabled
    ? { type: "spring", stiffness: 420, damping: 32, mass: 0.9 }
    : { duration: 0 };

  const prefs = settings?.preferences ?? null;

  return (
    // devkit-no-drag: TitleBar renders this outside its drag-region div, but
    // the class keeps the full-window overlay un-draggable regardless of
    // where a future caller mounts it.
    <motion.div
      className="settings-dialog__overlay devkit-no-drag"
      onClick={onClose}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={overlayTransition}
    >
      <motion.div
        className="settings-dialog__positioner"
        initial={animationsEnabled ? { opacity: 0, scale: 0.94, y: 16 } : false}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={animationsEnabled ? { opacity: 0, scale: 0.96, y: 8 } : { opacity: 0 }}
        transition={panelTransition}
      >
        <GlassPanel strong padded={false} noAnimate className="settings-dialog">
          <div className="settings-dialog__inner" onClick={(e) => e.stopPropagation()}>
            <div className="settings-dialog__header">
              <span className="settings-dialog__title">Settings</span>
              <button type="button" className="settings-dialog__close" aria-label="Close settings" onClick={onClose}>
                &#10005;
              </button>
            </div>

            {settingsError && <div className="settings-inline-error settings-dialog__store-error">{settingsError}</div>}

            <div className="settings-dialog__body">
              <nav className="settings-dialog__nav" aria-label="Settings sections">
                {SECTIONS.map((s) => (
                  <button
                    key={s.id}
                    type="button"
                    className={clsx("settings-dialog__nav-item", section === s.id && "settings-dialog__nav-item--active")}
                    onClick={() => setSection(s.id)}
                  >
                    {s.label}
                  </button>
                ))}
              </nav>

              <div className="settings-dialog__content">
                {!prefs ? (
                  <div className="settings-dialog__loading">Loading settings&hellip;</div>
                ) : (
                  <>
                    {section === "appearance" && <AppearanceSection prefs={prefs} update={update} queue={queue} />}
                    {section === "terminal" && <TerminalSection prefs={prefs} update={update} />}
                    {section === "sound" && <SoundSection prefs={prefs} update={update} queue={queue} />}
                    {section === "behavior" && <BehaviorSection prefs={prefs} update={update} />}
                    {section === "about" && <AboutSection />}
                  </>
                )}
              </div>
            </div>
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}

// ---------------------------------------------------------------------------
// Theme swatch card - shared by the Appearance (app theme) and Terminal
// (terminal theme) pickers. Inline literal colors here are theme PREVIEW
// data from lib/themes.ts, not hardcoded UI colors.
// ---------------------------------------------------------------------------

function ThemeCard({
  theme,
  active,
  compact,
  onSelect,
}: {
  theme: ThemePreset;
  active: boolean;
  compact?: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      className={clsx("settings-theme-card", compact && "settings-theme-card--compact", active && "settings-theme-card--active")}
      style={{ background: theme.preview.surface }}
      onClick={onSelect}
      aria-pressed={active}
    >
      <span className="settings-theme-card__chips" aria-hidden="true">
        <span className="settings-theme-card__chip" style={{ background: theme.preview.accent }} />
        <span className="settings-theme-card__chip" style={{ background: theme.preview.danger }} />
        <span className="settings-theme-card__chip settings-theme-card__chip--wide" style={{ background: theme.preview.raised }} />
      </span>
      <span className="settings-theme-card__name" style={{ color: theme.preview.text }}>
        {theme.label}
      </span>
    </button>
  );
}

function ToggleRow({
  label,
  hint,
  checked,
  onChange,
}: {
  label: string;
  hint?: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className="settings-row">
      <span className="settings-row__text">
        <span className="settings-row__label">{label}</span>
        {hint && <span className="settings-row__hint">{hint}</span>}
      </span>
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

const HEX_COLOR = /^#[0-9a-f]{6}$/i;

function AppearanceSection({ prefs, update, queue }: SectionProps & { queue: QueueFn }) {
  const activeTheme = getThemePreset(prefs.appTheme);
  const saveError = useSettingsStore((s) => s.error);
  const [customFont, setCustomFont] = useState(false);
  const [customFontDraft, setCustomFontDraft] = useState("");
  const [scaleDraft, setScaleDraft] = useState<number | null>(null);
  const [railWidthDraft, setRailWidthDraft] = useState<number | null>(null);
  const [railIconDraft, setRailIconDraft] = useState<number | null>(null);

  // The draft exists only to bridge the debounce. Once the store reports the
  // value we drafted, the save has landed - hand control back to the store so
  // a later change from the OTHER window (arriving via devkit://settings-changed)
  // isn't masked by a stale local draft.
  useEffect(() => {
    const persisted = clampUiScale(prefs.uiScale);
    setScaleDraft((draft) => (draft !== null && draft === persisted ? null : draft));
  }, [prefs.uiScale]);

  // A save failed: the store still holds the last PERSISTED scale, so drop
  // the draft and put the live preview back where it belongs. Without this
  // the slider would keep showing - and the root would keep rendering at - a
  // scale that was never written.
  useEffect(() => {
    if (!saveError) return;
    setScaleDraft(null);
    setRailWidthDraft(null);
    setRailIconDraft(null);
    previewUiScale(prefs.uiScale);
  }, [saveError, prefs.uiScale]);

  // The rail sliders' half of the same draft bridge - retire each draft once
  // the store reports the value it was drafting, so a change made in the
  // OTHER window stops being masked by a stale local one.
  useEffect(() => {
    const persisted = clampRail(prefs.railWidth, RAIL_WIDTH_BOUNDS);
    setRailWidthDraft((draft) => (draft !== null && draft === persisted ? null : draft));
  }, [prefs.railWidth]);

  useEffect(() => {
    const persisted = clampRail(prefs.railIconSize, RAIL_ICON_BOUNDS);
    setRailIconDraft((draft) => (draft !== null && draft === persisted ? null : draft));
  }, [prefs.railIconSize]);

  const presetKey =
    prefs.fontFamily === null ? "default" : (FONT_PRESETS.find((p) => p.value === prefs.fontFamily)?.key ?? "custom");
  const fontSelectValue = customFont ? "custom" : presetKey;

  function onFontSelect(key: string) {
    if (key === "custom") {
      setCustomFont(true);
      setCustomFontDraft(prefs.fontFamily ?? "");
      return;
    }
    setCustomFont(false);
    const preset = FONT_PRESETS.find((p) => p.key === key);
    void update({ fontFamily: preset?.value ?? null });
  }

  function commitCustomFont() {
    // Nothing typed yet (draft untouched) - don't clobber the saved value.
    if (!customFont) return;
    const value = customFontDraft.trim();
    void update({ fontFamily: value === "" ? null : value });
  }

  // <input type=color> requires a #rrggbb value; guard against a
  // hand-edited settings.json holding something else.
  const accentValue = prefs.accentColor && HEX_COLOR.test(prefs.accentColor) ? prefs.accentColor : activeTheme.preview.accent;

  const scalePercent = Math.round(clampUiScale(scaleDraft ?? prefs.uiScale) * 100);

  function onScaleChange(percent: number) {
    const scale = clampUiScale(percent / 100);
    setScaleDraft(scale);
    // Instant preview, byte-for-byte the write useApplyAppearance makes once
    // the debounced save lands - `zoom` AND `--ui-scale` together. Writing
    // zoom alone left the root sized 100vh*scale for the length of the
    // debounce, showing the transparent window through as a see-through
    // strip at the bottom on every slider tick.
    previewUiScale(scale);
    queue({ uiScale: scale });
  }

  function resetScale() {
    setScaleDraft(1);
    previewUiScale(1);
    queue({ uiScale: 1 });
  }

  // Normalised, not read raw: a hand-edited settings.json holding a style
  // this build doesn't know would otherwise leave every card unlit.
  const iconTheme = normalizeIconTheme(prefs.iconTheme);
  const railWidth = railWidthDraft ?? clampRail(prefs.railWidth, RAIL_WIDTH_BOUNDS);
  const railIconSize = railIconDraft ?? clampRail(prefs.railIconSize, RAIL_ICON_BOUNDS);

  // Deliberately NOT previewed by writing the document root. uiScale has to
  // be (its `zoom` and --ui-scale are a pair, and a scale that only exists
  // after the debounce leaves a see-through strip at the window bottom), but
  // rail geometry belongs to the widget's rail component, which picks the new
  // value up from the settings store when the save lands ~250ms later. The
  // strip beside the sliders is what makes the drag read as live - and it
  // works in the Control Center window too, which has no rail at all.
  function onRailWidth(px: number) {
    const next = clampRail(px, RAIL_WIDTH_BOUNDS);
    setRailWidthDraft(next);
    queue({ railWidth: next });
  }

  function onRailIconSize(px: number) {
    const next = clampRail(px, RAIL_ICON_BOUNDS);
    setRailIconDraft(next);
    queue({ railIconSize: next });
  }

  function resetRail() {
    setRailWidthDraft(RAIL_WIDTH_BOUNDS.fallback);
    setRailIconDraft(RAIL_ICON_BOUNDS.fallback);
    queue({ railWidth: RAIL_WIDTH_BOUNDS.fallback, railIconSize: RAIL_ICON_BOUNDS.fallback });
  }

  // A glyph wider than the strip minus its breathing room renders clipped in
  // the real rail, so say so rather than letting the combination look broken.
  const railCrowded = railIconSize > railWidth - 10;

  return (
    <div className="settings-section">
      <h3 className="settings-section__title">Theme</h3>
      <div className="settings-theme-grid">
        {THEMES.map((theme) => (
          <ThemeCard
            key={theme.id}
            theme={theme}
            active={prefs.appTheme === theme.id}
            onSelect={() => void update({ appTheme: theme.id })}
          />
        ))}
      </div>

      <h3 className="settings-section__title">Accent color</h3>
      <div className="settings-field">
        <input
          type="color"
          className="settings-color-input"
          aria-label="Accent color override"
          value={accentValue}
          onChange={(e) => queue({ accentColor: e.target.value })}
        />
        <span className="settings-field__value">{prefs.accentColor ?? "Theme default"}</span>
        <Button size="sm" variant="ghost" disabled={prefs.accentColor === null} onClick={() => void update({ accentColor: null })}>
          Reset to theme
        </Button>
      </div>

      <h3 className="settings-section__title">Font</h3>
      <div className="settings-field settings-field--stack">
        <select className="settings-select" aria-label="Font family" value={fontSelectValue} onChange={(e) => onFontSelect(e.target.value)}>
          {FONT_PRESETS.map((p) => (
            <option key={p.key} value={p.key}>
              {p.label}
            </option>
          ))}
          <option value="custom">Custom&hellip;</option>
        </select>
        {fontSelectValue === "custom" && (
          <input
            type="text"
            className="settings-text-input"
            placeholder="Font family name, e.g. JetBrains Mono"
            aria-label="Custom font family"
            value={customFont ? customFontDraft : (prefs.fontFamily ?? "")}
            onChange={(e) => {
              setCustomFont(true);
              setCustomFontDraft(e.target.value);
            }}
            onBlur={commitCustomFont}
            onKeyDown={(e) => {
              if (e.key === "Enter") commitCustomFont();
            }}
          />
        )}
      </div>

      <h3 className="settings-section__title">UI scale</h3>
      <div className="settings-field">
        <input
          type="range"
          className="settings-slider"
          min={80}
          max={140}
          step={5}
          value={scalePercent}
          aria-label="UI scale"
          onChange={(e) => onScaleChange(Number(e.target.value))}
        />
        <span className="settings-field__value">{scalePercent}%</span>
        <Button size="sm" variant="ghost" disabled={scalePercent === 100} onClick={resetScale}>
          Reset
        </Button>
      </div>

      <h3 className="settings-section__title">Icon style</h3>
      <p className="settings-section__hint">Glyph style for the widget's tray rail.</p>
      <div className="settings-icon-styles" role="group" aria-label="Icon style">
        {ICON_STYLES.map((style) => {
          const active = iconTheme === style.id;
          return (
            <button
              key={style.id}
              type="button"
              className={clsx("settings-icon-style", active && "settings-icon-style--active")}
              aria-pressed={active}
              onClick={() => void update({ iconTheme: style.id })}
            >
              <span className="settings-icon-style__glyphs">
                {PREVIEW_ICONS.map((name) => (
                  <RailIcon key={name} name={name} theme={style.id} size={18} />
                ))}
              </span>
              <span className="settings-icon-style__name">{style.label}</span>
            </button>
          );
        })}
      </div>

      <h3 className="settings-section__title">Icon rail</h3>
      <div className="settings-rail-tune">
        <div className="settings-rail-tune__controls">
          <div className="settings-field">
            <span className="settings-field__label">Strip width</span>
            <input
              type="range"
              className="settings-slider"
              min={RAIL_WIDTH_BOUNDS.min}
              max={RAIL_WIDTH_BOUNDS.max}
              step={RAIL_WIDTH_BOUNDS.step}
              value={railWidth}
              aria-label="Icon rail width"
              onChange={(e) => onRailWidth(Number(e.target.value))}
            />
            <span className="settings-field__value">{railWidth} px</span>
          </div>
          <div className="settings-field">
            <span className="settings-field__label">Icon size</span>
            <input
              type="range"
              className="settings-slider"
              min={RAIL_ICON_BOUNDS.min}
              max={RAIL_ICON_BOUNDS.max}
              step={RAIL_ICON_BOUNDS.step}
              value={railIconSize}
              aria-label="Rail icon size"
              onChange={(e) => onRailIconSize(Number(e.target.value))}
            />
            <span className="settings-field__value">{railIconSize} px</span>
          </div>
          <div className="settings-field">
            <Button
              size="sm"
              variant="ghost"
              disabled={railWidth === RAIL_WIDTH_BOUNDS.fallback && railIconSize === RAIL_ICON_BOUNDS.fallback}
              onClick={resetRail}
            >
              Reset rail
            </Button>
            {railCrowded && <span className="settings-row__hint">Tight fit - the glyph nearly fills the strip.</span>}
          </div>
        </div>

        <div className="settings-rail-preview">
          <div className="settings-rail-preview__strip" style={{ width: railWidth }} aria-hidden="true">
            {PREVIEW_ICONS.map((name, i) => (
              <span
                key={name}
                className={clsx("settings-rail-preview__tab", i === 0 && "settings-rail-preview__tab--active")}
              >
                <RailIcon name={name} theme={iconTheme} size={railIconSize} />
              </span>
            ))}
          </div>
          <span className="settings-rail-preview__caption">Preview</span>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Terminal
// ---------------------------------------------------------------------------

function TerminalSection({ prefs, update }: SectionProps) {
  return (
    <div className="settings-section">
      <h3 className="settings-section__title">Terminal theme</h3>
      <p className="settings-section__hint">Color scheme for the embedded terminal - independent of the app theme.</p>
      <div className="settings-theme-grid settings-theme-grid--compact">
        {THEMES.map((theme) => (
          <ThemeCard
            key={theme.id}
            theme={theme}
            compact
            active={prefs.terminalTheme === theme.id}
            onSelect={() => void update({ terminalTheme: theme.id })}
          />
        ))}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sound
// ---------------------------------------------------------------------------

function SoundSection({ prefs, update, queue }: SectionProps & { queue: QueueFn }) {
  const saveError = useSettingsStore((s) => s.error);
  const [volumeDraft, setVolumeDraft] = useState<number | null>(null);
  const volume = volumeDraft ?? prefs.uiSoundVolume;
  const volumePercent = Math.round(Math.min(1, Math.max(0, volume)) * 100);

  // Same two rules as the UI-scale draft: retire the draft once the store
  // agrees with it (save landed, and cross-window changes can get through
  // again), and drop it outright when a save fails so the slider can never
  // display a volume that was never persisted.
  useEffect(() => {
    setVolumeDraft((draft) => (draft !== null && draft === prefs.uiSoundVolume ? null : draft));
  }, [prefs.uiSoundVolume]);

  useEffect(() => {
    if (saveError) setVolumeDraft(null);
  }, [saveError]);

  return (
    <div className="settings-section">
      <h3 className="settings-section__title">Sound</h3>
      <ToggleRow
        label="UI sounds"
        hint="Small cues for actions completing, errors, and notifications."
        checked={prefs.uiSounds}
        onChange={(checked) => void update({ uiSounds: checked })}
      />
      <div className="settings-field">
        <input
          type="range"
          className="settings-slider"
          min={0}
          max={100}
          step={5}
          value={volumePercent}
          disabled={!prefs.uiSounds}
          aria-label="UI sound volume"
          onChange={(e) => {
            const next = Number(e.target.value) / 100;
            setVolumeDraft(next);
            queue({ uiSoundVolume: next });
          }}
        />
        <span className="settings-field__value">{volumePercent}%</span>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Global shortcut
// ---------------------------------------------------------------------------

/**
 * App-wide event carrying a global-hotkey registration that Rust refused.
 *
 * hooks/useApplyAppearance.ts is what actually drives registration (it
 * re-invokes register_global_hotkey whenever the preference changes), but it
 * fires and forgets - a taken accelerator only ever reached console.warn, so
 * the feature could silently not work. Emitting this app-wide instead puts
 * the message in the error slot below, from whichever window has Settings
 * open. Nothing emits it yet (the exact hook change is in this batch's
 * report); a listener with no emitter is inert, so this is safe to ship
 * first.
 */
const HOTKEY_ERROR_EVENT = "devkit://hotkey-error";

interface HotkeyErrorPayload {
  accelerator: string;
  error: string;
}

/**
 * Keys the accelerator parser accepts by name. The crate behind
 * tauri-plugin-global-shortcut (global-hotkey) uppercases each token and
 * matches it against a fixed table, which is why arrows are "Up"/"Down"
 * rather than "ArrowUp", and why anything outside this map plus letters,
 * digits, F-keys and the numpad has to be refused at capture time instead of
 * persisted and left to fail at registration.
 */
const NAMED_KEYS: Record<string, string> = {
  Space: "Space",
  Enter: "Enter",
  Tab: "Tab",
  Backspace: "Backspace",
  Delete: "Delete",
  Insert: "Insert",
  Home: "Home",
  End: "End",
  PageUp: "PageUp",
  PageDown: "PageDown",
  ArrowUp: "Up",
  ArrowDown: "Down",
  ArrowLeft: "Left",
  ArrowRight: "Right",
  Minus: "Minus",
  Equal: "Equal",
  BracketLeft: "BracketLeft",
  BracketRight: "BracketRight",
  Backslash: "Backslash",
  Semicolon: "Semicolon",
  Quote: "Quote",
  Backquote: "Backquote",
  Comma: "Comma",
  Period: "Period",
  Slash: "Slash",
};

/** KeyboardEvent.code to accelerator token, or null for a modifier-only press / a key the parser cannot name. */
function keyToken(code: string): string | null {
  const letter = /^Key([A-Z])$/.exec(code);
  if (letter) return letter[1]; // bare "D" - the shipped default is "CommandOrControl+Alt+D"
  const digit = /^Digit([0-9])$/.exec(code);
  if (digit) return digit[1];
  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(code)) return code;
  if (/^Numpad[0-9]$/.test(code)) return code;
  return NAMED_KEYS[code] ?? null;
}

function accelFromEvent(e: KeyboardEvent): string | null {
  const key = keyToken(e.code);
  if (!key) return null;
  const mods: string[] = [];
  // CommandOrControl, not Control: identical on Windows, and the stored
  // string stays portable if this ever ships anywhere else.
  if (e.ctrlKey) mods.push("CommandOrControl");
  if (e.altKey) mods.push("Alt");
  if (e.shiftKey) mods.push("Shift");
  if (e.metaKey) mods.push("Super");
  // A global shortcut with no modifier would swallow that key in every
  // application on the machine - never offer it.
  if (mods.length === 0) return null;
  return [...mods, key].join("+");
}

const MODIFIER_LABELS: Record<string, string> = {
  commandorcontrol: "Ctrl",
  commandorctrl: "Ctrl",
  cmdorctrl: "Ctrl",
  cmdorcontrol: "Ctrl",
  control: "Ctrl",
  ctrl: "Ctrl",
  alt: "Alt",
  option: "Alt",
  shift: "Shift",
  super: "Win",
  command: "Win",
  cmd: "Win",
};

/** Stored accelerator to keycap labels. Unknown tokens pass through so a hand-edited settings.json still shows the truth. */
function acceleratorKeys(accelerator: string): string[] {
  return accelerator
    .split("+")
    .map((token) => token.trim())
    .filter(Boolean)
    .map((token) => MODIFIER_LABELS[token.toLowerCase()] ?? token);
}

function HotkeyField({ prefs, update }: SectionProps) {
  const [capturing, setCapturing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const commit = useCallback(
    async (accelerator: string) => {
      setCapturing(false);
      setError(null);
      setBusy(true);
      try {
        // Register BEFORE persisting. commands.rs::register_global_hotkey puts
        // the previous binding back when the OS refuses the new one, so
        // bailing out here leaves settings.json and the live binding agreeing
        // on the accelerator the user still actually has.
        await invoke("register_global_hotkey", { accelerator });
      } catch (err) {
        setError(String(err));
        playSound("error");
        setBusy(false);
        return;
      }
      // If the save itself fails the binding is already live; that failure
      // surfaces in the dialog-level store error banner.
      await update({ globalHotkey: accelerator });
      playSound("success");
      setBusy(false);
    },
    [update],
  );

  useEffect(() => {
    if (!capturing) return;
    const onKey = (e: KeyboardEvent) => {
      // Capture phase, and every keystroke swallowed: SettingsDialog closes on
      // a window-level Escape and Tab would walk focus out of the field, so
      // neither can be allowed to see a key meant for the accelerator.
      e.preventDefault();
      e.stopPropagation();
      if (e.repeat) return;
      const bare = !e.ctrlKey && !e.altKey && !e.shiftKey && !e.metaKey;
      if (e.code === "Escape" && bare) {
        setCapturing(false);
        return;
      }
      const accelerator = accelFromEvent(e);
      if (accelerator) void commit(accelerator);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [capturing, commit]);

  useEffect(() => {
    const pending = listen<HotkeyErrorPayload>(HOTKEY_ERROR_EVENT, (evt) => {
      if (evt.payload?.error) setError(evt.payload.error);
    });
    return () => {
      // No Tauri IPC (browser dev server) just means no listener to detach.
      void pending.then((unlisten) => unlisten()).catch(() => {});
    };
  }, []);

  const keys = acceleratorKeys(prefs.globalHotkey ?? "");

  return (
    <>
      <h3 className="settings-section__title">Global shortcut</h3>
      <p className="settings-section__hint">Summons or dismisses the widget from anywhere in Windows.</p>
      <div className="settings-field">
        <button
          type="button"
          className={clsx("settings-hotkey", capturing && "settings-hotkey--capturing")}
          aria-label="Global shortcut"
          disabled={busy}
          // Capture swallows every keystroke in this webview while it is
          // armed, so losing focus has to disarm it - otherwise clicking a
          // theme card mid-capture would leave the dialog keyboard-deaf.
          onBlur={() => setCapturing(false)}
          onClick={() => {
            setError(null);
            setCapturing((active) => !active);
            playSound("click");
          }}
        >
          {capturing ? (
            <span className="settings-hotkey__prompt">Press a shortcut&hellip;</span>
          ) : keys.length > 0 ? (
            <span className="settings-hotkey__keys">
              {keys.map((key, i) => (
                <kbd key={`${key}-${i}`} className="settings-hotkey__key">
                  {key}
                </kbd>
              ))}
            </span>
          ) : (
            <span className="settings-hotkey__prompt">No shortcut</span>
          )}
        </button>
        <Button size="sm" variant="ghost" disabled={busy || keys.length === 0} onClick={() => void commit("")}>
          Clear
        </Button>
      </div>
      <span className="settings-row__hint">
        {capturing
          ? "Hold Ctrl, Alt, Shift, or Win and press a key. Esc cancels."
          : "Click the field, then press the combination you want."}
      </span>
      {error && <div className="settings-inline-error">{error}</div>}
    </>
  );
}

// ---------------------------------------------------------------------------
// Behavior
// ---------------------------------------------------------------------------

function BehaviorSection({ prefs, update }: SectionProps) {
  const [dockError, setDockError] = useState<string | null>(null);

  // Reads/drives the same store WidgetApp's auto-check writes to - this was
  // QuickActionsPanel's manual check block; Settings is its new home.
  const updateStatus = useUpdaterStore((s) => s.status);
  const availableUpdate = useUpdaterStore((s) => s.update);
  const checkNow = useUpdaterStore((s) => s.checkNow);

  async function setDock(mode: "Left" | "Right" | "Floating") {
    setDockError(null);
    // Persist regardless of whether the immediate move works - the setting
    // also applies at next startup via useApplyAppearance.
    void update({ widgetDockMode: mode });
    try {
      await invoke("set_widget_dock", { side: mode });
    } catch (err) {
      setDockError(`Saved, but could not move the widget now: ${String(err)}`);
    }
  }

  function updateStatusLabel(): string | null {
    switch (updateStatus) {
      case "checking":
        return "Checking…";
      case "up-to-date":
        return "Up to date";
      case "available":
        return availableUpdate ? `v${availableUpdate.version} available` : "Update available";
      case "downloading":
        return "Downloading…";
      case "installing":
        return "Installing…";
      case "error":
        return "Check failed";
      default:
        return null;
    }
  }
  const updateBusy = updateStatus === "checking" || updateStatus === "downloading" || updateStatus === "installing";
  const updateLabel = updateStatusLabel();

  return (
    <div className="settings-section">
      <h3 className="settings-section__title">Behavior</h3>
      <ToggleRow
        label="Animations"
        hint="Panel entrances, transitions, and gauge motion."
        checked={prefs.enableAnimations}
        onChange={(checked) => void update({ enableAnimations: checked })}
      />
      <ToggleRow
        label="Confirm destructive actions"
        hint="Ask before killing processes or clearing state."
        checked={prefs.confirmDestructive}
        onChange={(checked) => void update({ confirmDestructive: checked })}
      />
      <ToggleRow
        label="Check for updates automatically"
        hint="Once a day, at startup."
        checked={prefs.updateCheckEnabled}
        onChange={(checked) => void update({ updateCheckEnabled: checked })}
      />

      <HotkeyField prefs={prefs} update={update} />

      <h3 className="settings-section__title">Widget dock</h3>
      <div className="settings-field">
        <div className="settings-segmented" role="group" aria-label="Widget dock side">
          {(["Left", "Right", "Floating"] as const).map((mode) => (
            <button
              key={mode}
              type="button"
              className={clsx("settings-segmented__item", prefs.widgetDockMode === mode && "settings-segmented__item--active")}
              onClick={() => void setDock(mode)}
            >
              {mode}
            </button>
          ))}
        </div>
        <span className="settings-row__hint">
          Left/Right pin the widget as a fixed full-height sidebar (immovable, fixed width). Floating is a normal
          draggable, resizable window.
        </span>
      </div>
      {dockError && <div className="settings-inline-error">{dockError}</div>}

      <h3 className="settings-section__title">Updates</h3>
      <div className="settings-field">
        <Button
          size="sm"
          variant="subtle"
          disabled={updateBusy}
          loading={updateStatus === "checking"}
          onClick={() => void checkNow()}
        >
          Check for Updates
        </Button>
        {updateLabel && (
          <span
            className={clsx(
              "settings-update-status",
              updateStatus === "error" && "settings-update-status--error",
              updateStatus === "available" && "settings-update-status--available",
            )}
          >
            {updateLabel}
          </span>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

function AboutSection() {
  const [version, setVersion] = useState<string | null>(null);
  const [linkError, setLinkError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    getVersion()
      .then((v) => {
        if (!cancelled) setVersion(v);
      })
      // Capability missing or plugin error: show nothing rather than break.
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  async function openRepo() {
    setLinkError(null);
    try {
      await openUrl(REPO_URL);
    } catch (err) {
      setLinkError(`Could not open the browser: ${String(err)}`);
    }
  }

  return (
    <div className="settings-section">
      <div className="settings-about">
        <img src={brand} alt="Northstar DevKit compass rose" className="settings-about__brand" />
        <div className="settings-about__meta">
          <span className="settings-about__name">Northstar DevKit</span>
          {version && <span className="settings-about__version">v{version}</span>}
        </div>
      </div>
      <button type="button" className="settings-link-row" onClick={() => void openRepo()}>
        <span className="settings-link-row__label">GitHub repository</span>
        <span className="settings-link-row__url">github.com/st3adyp1ck/northstar-devkit</span>
      </button>
      {linkError && <div className="settings-inline-error">{linkError}</div>}
    </div>
  );
}
