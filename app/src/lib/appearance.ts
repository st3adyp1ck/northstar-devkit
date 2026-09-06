import { deriveAccentRamp, getThemePreset } from "./themes";
import type { DevKitPreferences } from "./types";

/**
 * The appearance side of settings.preferences as a set of root custom
 * properties, plus the localStorage cache that lets the NEXT launch paint
 * them before settings have loaded.
 *
 * Why a cache exists at all: settings live in settings.json and reach the
 * webview only through `settings.get`, which the PowerShell sidecar cannot
 * answer until it has imported DevKit.Core.psm1 - a few seconds on a cold
 * start. Rust shows the widget as soon as setup completes (lib.rs), long
 * before that first RPC returns, so every launch painted tokens.css's
 * Northstar defaults and then snapped to the chosen theme once settings
 * arrived. Both windows read the same localStorage origin (they are the
 * same index.html behind a query param), so a snapshot written by either
 * window's useApplyAppearance is what main.tsx applies at boot - before
 * React mounts, so the first frame already matches the preference.
 *
 * The cache is a HINT, never the authority: settings.json still wins the
 * moment it loads (useApplyAppearance re-applies and overwrites the
 * snapshot), so a hand-edited settings.json costs one launch of the old
 * look and nothing more. Everything here is pure and DOM-free (targets are
 * injected) so it runs at module top level in main.tsx and under vitest's
 * node environment alike.
 */

/**
 * The preferences that decide how a window looks on its first frame: the
 * root custom properties (theme, accent, font, scale), the animations
 * toggle, and the widget shell's layout - which edge it is docked to and
 * how its icon rail is sized, styled and ordered. Without the shell half
 * the widget painted its floating column and then re-laid itself out into
 * the docked rail the instant settings landed, which was the same snap as
 * the theme, one component over.
 *
 * The shell fields are nullable: null means "unknown" (a snapshot written
 * before they existed, or a field that failed validation), and WidgetApp
 * then renders exactly as it did before the hint existed.
 */
export interface AppearancePrefs
  extends Pick<DevKitPreferences, "appTheme" | "accentColor" | "fontFamily" | "uiScale" | "enableAnimations"> {
  widgetDockMode: DevKitPreferences["widgetDockMode"] | null;
  railWidth: number | null;
  railIconSize: number | null;
  iconTheme: DevKitPreferences["iconTheme"] | null;
  flyoutTabOrder: string[] | null;
}

const DOCK_MODES: ReadonlyArray<DevKitPreferences["widgetDockMode"]> = ["Left", "Right", "Floating"];
const ICON_THEMES: ReadonlyArray<DevKitPreferences["iconTheme"]> = ["outline", "solid", "duotone"];

function oneOf<T extends string>(value: unknown, allowed: ReadonlyArray<T>): T | null {
  return typeof value === "string" && (allowed as ReadonlyArray<string>).includes(value) ? (value as T) : null;
}

/**
 * localStorage key for the snapshot. Versioned so a future shape change can
 * simply move to `.v2` and let the old entry rot rather than migrate it -
 * a missing cache costs one launch of the flash, never a broken one.
 */
export const APPEARANCE_CACHE_KEY = "devkit.appearance.v1";

/** Clamp uiScale to the supported zoom range; non-finite/legacy values fall back to 1. */
export function clampUiScale(scale: number): number {
  if (!Number.isFinite(scale)) return 1;
  return Math.min(1.4, Math.max(0.8, scale));
}

/** The root properties that carry a UI scale. Written and cleared as a unit - never one without the other. */
export const SCALE_PROPS = ["zoom", "--ui-scale"] as const;

/**
 * The custom properties a given UI scale needs - ALWAYS as a pair.
 *
 * CSS `zoom` scales rendered content but vh units still resolve against the
 * UNZOOMED viewport, so an element sized 100vh renders at only 100vh * scale
 * and leaves a transparent gap at the window bottom when scale < 1 (both
 * windows are transparent:true, so the gap is literally see-through -
 * 208px of it at 80%). The window roots compensate with
 * `height: calc(100vh / var(--ui-scale, 1))`, which only works if
 * --ui-scale is written at the same instant as `zoom`. Anything that
 * previews a scale must go through here rather than writing `zoom` alone.
 *
 * Empty at scale 1: the stylesheet default (--ui-scale fallback 1, no zoom)
 * is already correct, and writing nothing keeps the removal path simple.
 */
export function uiScaleProperties(scale: number): Record<string, string> {
  const clamped = clampUiScale(scale);
  if (clamped === 1) return {};
  return Object.fromEntries(SCALE_PROPS.map((prop) => [prop, String(clamped)]));
}

/**
 * The full set of root custom-property overrides for a preference set:
 * the theme preset (lib/themes.ts), the optional accentColor ramp layered
 * on top, the fontFamily --font-sans override, and uiScale's zoom pair.
 * Empty for the defaults - tokens.css IS the northstar theme.
 *
 * The ONE derivation shared by the live hook and the boot path, so what
 * the cache paints on the first frame is byte-for-byte what settings will
 * paint a few seconds later.
 */
export function appearanceProperties(prefs: AppearancePrefs): Record<string, string> {
  const desired: Record<string, string> = { ...getThemePreset(prefs.appTheme).overrides };

  if (prefs.accentColor) {
    const ramp = deriveAccentRamp(prefs.accentColor);
    if (ramp) Object.assign(desired, ramp);
  }

  const family = prefs.fontFamily?.trim();
  if (family) {
    // A preset stack already carries its own fallbacks (has commas); a
    // bare custom family name gets the default stack appended behind it.
    desired["--font-sans"] = family.includes(",")
      ? family
      : `${family}, "Segoe UI Variable", "Segoe UI", system-ui, sans-serif`;
  }

  // zoom + --ui-scale, always together - see uiScaleProperties.
  Object.assign(desired, uiScaleProperties(prefs.uiScale));

  return desired;
}

/**
 * The appearance slice of a full preferences object, ready to cache. The
 * shell fields go through the same validation as a read-back so a value
 * the live path would normalise (railIcons' normalizeIconTheme, WidgetApp's
 * clampRail) never round-trips as something the type says it cannot be.
 */
export function pickAppearance(prefs: DevKitPreferences): AppearancePrefs {
  return {
    appTheme: prefs.appTheme,
    accentColor: prefs.accentColor,
    fontFamily: prefs.fontFamily,
    uiScale: prefs.uiScale,
    enableAnimations: prefs.enableAnimations,
    widgetDockMode: oneOf(prefs.widgetDockMode, DOCK_MODES),
    railWidth: typeof prefs.railWidth === "number" ? prefs.railWidth : null,
    railIconSize: typeof prefs.railIconSize === "number" ? prefs.railIconSize : null,
    iconTheme: oneOf(prefs.iconTheme, ICON_THEMES),
    flyoutTabOrder: Array.isArray(prefs.flyoutTabOrder) ? prefs.flyoutTabOrder.filter((id) => typeof id === "string") : null,
  };
}

// ---------------------------------------------------------------------------
// Applying to a root element
// ---------------------------------------------------------------------------

/** The slice of CSSStyleDeclaration the applier needs - injectable so tests need no DOM. */
export interface RootStyle {
  setProperty(name: string, value: string): void;
  removeProperty(name: string): void;
}

/** The slice of HTMLElement the boot path needs. */
export interface AppearanceRoot {
  style: RootStyle;
  dataset: { animations?: string };
}

export interface AppearanceApplier {
  /**
   * Writes `desired` as inline style on the root and removes whatever this
   * applier wrote last time that `desired` no longer carries, so switching
   * back to northstar (empty set) genuinely returns to the stylesheet
   * defaults instead of leaving another theme's values behind. Removal and
   * set happen in one synchronous block - no intermediate paint.
   *
   * SCALE_PROPS are in the sweep unconditionally, not just when this
   * applier set them: the Settings slider writes the same pair directly
   * for its live preview (previewUiScale), so at uiScale 1 - where
   * `desired` carries neither - an orphaned preview has to be cleared by
   * an applier that never set it.
   */
  apply(style: RootStyle, desired: Record<string, string>): void;
  /** The property names written by the most recent apply(). */
  applied(): ReadonlySet<string>;
}

/**
 * One applier per window, shared by the boot path and useApplyAppearance:
 * the whole point is that the hook's first real apply knows what boot
 * painted and sweeps it if settings disagree. Tests build their own.
 */
export function createAppearanceApplier(): AppearanceApplier {
  let applied = new Set<string>();
  return {
    apply(style, desired) {
      for (const prop of new Set([...applied, ...SCALE_PROPS])) {
        if (!(prop in desired)) style.removeProperty(prop);
      }
      for (const [prop, value] of Object.entries(desired)) {
        style.setProperty(prop, value);
      }
      applied = new Set(Object.keys(desired));
    },
    applied: () => applied,
  };
}

/** The applier for this window's document root. */
export const rootAppearance: AppearanceApplier = createAppearanceApplier();

/**
 * Keeps `<html data-animations="off">` (attribute absent otherwise) in sync
 * with preferences.enableAnimations. tokens.css's `:root[data-animations="off"]`
 * block zeroes the --duration-* tokens; see useSyncAnimationsAttribute.
 */
export function applyAnimationsAttribute(root: Pick<AppearanceRoot, "dataset">, enabled: boolean): void {
  if (enabled) delete root.dataset.animations;
  else root.dataset.animations = "off";
}

// ---------------------------------------------------------------------------
// The localStorage snapshot
// ---------------------------------------------------------------------------

/** Even reaching for `window.localStorage` throws when site data is blocked. */
export function appearanceStorage(): Storage | null {
  try {
    if (typeof window === "undefined") return null;
    return window.localStorage ?? null;
  } catch {
    return null;
  }
}

/**
 * Rebuilds a snapshot from whatever JSON.parse handed back, field by field.
 * The whole entry is rejected only when it is not an object; every field
 * falls back to its stylesheet default on its own, because the consumers
 * already tolerate the odd value (an unknown theme id is northstar, a bad
 * accent hex is no ramp, a non-finite scale is 1) - the same leniency the
 * live path shows a hand-edited settings.json.
 */
function sanitize(value: unknown): AppearancePrefs | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  return {
    appTheme: typeof raw.appTheme === "string" ? raw.appTheme : "northstar",
    accentColor: typeof raw.accentColor === "string" ? raw.accentColor : null,
    fontFamily: typeof raw.fontFamily === "string" ? raw.fontFamily : null,
    uiScale: typeof raw.uiScale === "number" ? raw.uiScale : 1,
    enableAnimations: raw.enableAnimations !== false,
    widgetDockMode: oneOf(raw.widgetDockMode, DOCK_MODES),
    railWidth: typeof raw.railWidth === "number" ? raw.railWidth : null,
    railIconSize: typeof raw.railIconSize === "number" ? raw.railIconSize : null,
    iconTheme: oneOf(raw.iconTheme, ICON_THEMES),
    flyoutTabOrder: Array.isArray(raw.flyoutTabOrder)
      ? raw.flyoutTabOrder.filter((id): id is string => typeof id === "string")
      : null,
  };
}

let bootHint: AppearancePrefs | null | undefined;

/**
 * The snapshot as it stood when this window booted - read once, lazily, on
 * first use and held for the life of the webview. The fallback for every
 * gate that must decide BEFORE settings.get has answered: the animations
 * preference behind framer's entrances (useAnimationsPreference) and the
 * widget shell's dock side and rail geometry (WidgetApp). Null when there
 * was no snapshot, in which case those gates behave as they did before the
 * hint existed. First use is always ahead of the first settings apply
 * (module evaluation and the first render both precede the sidecar's
 * answer), so this never observes a snapshot newer than boot's.
 */
export function bootAppearanceHint(): AppearancePrefs | null {
  if (bootHint === undefined) bootHint = readCachedAppearance(appearanceStorage());
  return bootHint;
}

/** The snapshot the previous session left, or null when there is none or it is unreadable. */
export function readCachedAppearance(storage: Storage | null): AppearancePrefs | null {
  if (!storage) return null;
  try {
    const text = storage.getItem(APPEARANCE_CACHE_KEY);
    if (!text) return null;
    return sanitize(JSON.parse(text));
  } catch {
    // Unparseable or a storage that throws on read: behave as uncached.
    return null;
  }
}

/** Persists the snapshot. Best-effort: a full or blocked storage only costs next launch's first frame. */
export function writeCachedAppearance(storage: Storage | null, prefs: AppearancePrefs): void {
  if (!storage) return;
  try {
    storage.setItem(APPEARANCE_CACHE_KEY, JSON.stringify(prefs));
  } catch {
    // Quota exceeded / site data blocked - nothing to do.
  }
}

/**
 * The boot step: paints the cached snapshot onto the root BEFORE React
 * mounts. Called from main.tsx at module top level. Returns what was
 * applied (null when nothing was cached) for tests and diagnostics.
 *
 * Goes through the shared applier so useApplyAppearance's first real
 * apply - which sweeps everything the applier wrote that settings do not
 * want - corrects a stale snapshot instead of leaving it layered under
 * the real theme.
 */
export function applyCachedAppearance(
  root: AppearanceRoot,
  storage: Storage | null,
  applier: AppearanceApplier = rootAppearance,
): AppearancePrefs | null {
  const cached = readCachedAppearance(storage);
  if (!cached) return null;
  applier.apply(root.style, appearanceProperties(cached));
  applyAnimationsAttribute(root, cached.enableAnimations);
  return cached;
}
