/**
 * Readable foregrounds for GitHub label chips.
 *
 * Label colors are DATA, not design tokens - they come from the repo (gh
 * sends six hex digits with no '#'), so the chip has to wear them. What
 * cannot be guessed is the text color on top: "#0e8a16" needs white,
 * "#fef2c0" needs near-black, and a fixed choice is unreadable on half the
 * labels in any real repo. So compute it, with the actual WCAG 2.1 relative
 * luminance / contrast-ratio math, against the two foregrounds this app
 * already owns - and read those off the live tokens so the ten themes stay
 * in charge of them.
 */

interface Rgb {
  r: number;
  g: number;
  b: number;
}

/** #rgb / #rrggbb / rrggbb -> channels, or null if it isn't a hex color. */
export function parseHexColor(value: string | null | undefined): Rgb | null {
  if (!value) return null;
  const hex = value.trim().replace(/^#/, "");
  if (/^[0-9a-f]{3}$/i.test(hex)) {
    return {
      r: parseInt(hex[0] + hex[0], 16),
      g: parseInt(hex[1] + hex[1], 16),
      b: parseInt(hex[2] + hex[2], 16),
    };
  }
  if (/^[0-9a-f]{6}$/i.test(hex)) {
    return {
      r: parseInt(hex.slice(0, 2), 16),
      g: parseInt(hex.slice(2, 4), 16),
      b: parseInt(hex.slice(4, 6), 16),
    };
  }
  return null;
}

/** WCAG 2.1 relative luminance (sRGB, gamma-expanded). */
function relativeLuminance({ r, g, b }: Rgb): number {
  const channel = (raw: number) => {
    const c = raw / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

/** WCAG 2.1 contrast ratio, 1 (identical) to 21 (black on white). */
export function contrastRatio(a: Rgb, b: Rgb): number {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  const lighter = Math.max(la, lb);
  const darker = Math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

const DARK_TOKEN = "--text-on-accent";
const LIGHT_TOKEN = "--text-primary";

/**
 * The two ink tokens' authored values, mirrored here as a fallback for when
 * they cannot be read - a theme that redefines one as color-mix(), or any
 * render outside a browser (tests). Same pattern as motion.ts mirroring the
 * --duration-* tokens: the CSS file stays the source of truth, and this is
 * only what the math falls back to. Keep in sync with styles/tokens.css.
 */
const INK_FALLBACK: Record<string, Rgb> = {
  [DARK_TOKEN]: { r: 6, g: 16, b: 25 },
  [LIGHT_TOKEN]: { r: 242, g: 245, b: 249 },
};

/**
 * getComputedStyle returns a custom property's SPECIFIED value, so a token
 * authored as a plain hex parses and one a theme redefined as color-mix()
 * does not. Cached per token name: this runs once per label chip per render,
 * and the values only change when a theme swaps - which reloads the panels.
 */
const tokenCache = new Map<string, Rgb>();

function tokenRgb(name: string): Rgb {
  const cached = tokenCache.get(name);
  if (cached) return cached;
  let parsed: Rgb | null = null;
  if (typeof window !== "undefined" && typeof getComputedStyle === "function") {
    parsed = parseHexColor(getComputedStyle(document.documentElement).getPropertyValue(name));
  }
  const resolved = parsed ?? INK_FALLBACK[name];
  tokenCache.set(name, resolved);
  return resolved;
}

export interface LabelChipColors {
  /** The label's own color, ready for CSS (with the '#' gh omits). */
  background: string;
  /** A token reference - never a literal - so themes keep control of the ink. */
  foreground: string;
  /** Contrast ratio actually achieved; null when there was no color to work with. */
  ratio: number | null;
}

/**
 * Picks whichever of the app's two inks contrasts BETTER against this label.
 * Not every label color can reach 4.5:1 against either of them - a mid-tone
 * "#d73a4a" tops out around 4.3 - so this maximizes rather than promising a
 * threshold it cannot always keep. The chip's own bold weight and pill size
 * carry the rest.
 */
export function labelChipColors(color: string | undefined): LabelChipColors {
  const bg = parseHexColor(color);
  if (!bg || !color) {
    // No usable color from gh - fall back to the neutral chip entirely.
    return { background: "var(--surface-raised)", foreground: "var(--text-secondary)", ratio: null };
  }
  const background = `#${color.trim().replace(/^#/, "")}`;
  const darkRatio = contrastRatio(bg, tokenRgb(DARK_TOKEN));
  const lightRatio = contrastRatio(bg, tokenRgb(LIGHT_TOKEN));
  return darkRatio >= lightRatio
    ? { background, foreground: `var(${DARK_TOKEN})`, ratio: darkRatio }
    : { background, foreground: `var(${LIGHT_TOKEN})`, ratio: lightRatio };
}
