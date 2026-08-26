/**
 * Per-PR lane colors that survive all ten themes.
 *
 * A hardcoded rainbow was the obvious thing and the wrong thing: half of it
 * collides with whatever the active theme calls "accent" (so one PR would
 * read as "selected" in Nord and a different one in Dracula), and none of it
 * follows a custom accent at all. So the hues are DERIVED - one rotation off
 * the live accent, then a golden-angle walk from there.
 *
 * Golden angle (137.508 deg) because it is the maximally-avoiding rotation:
 * for any n, the first n hues it produces are about as evenly spread around
 * the wheel as n hues can be, so PR #4 is as far from PR #3 with ten PRs on
 * screen as with three. A fixed step (say 60 deg) starts repeating at 6 and
 * clusters badly before that.
 *
 * WHY NOT ALSO AVOID THE COMMIT LANE PALETTE: Get-DevKitGitLaneColor's eight
 * lane colors are fixed server-side and already span the whole wheel, so
 * there is no hue left to hide in. PR lanes are told apart from commit lanes
 * by MATERIAL instead - thick translucent ribbons and dashed arcs against
 * thin opaque lines (see PrGraph.css). That distinction holds no matter what
 * hue lands where.
 *
 * Lightness/saturation are fixed rather than adapted, because every theme in
 * lib/themes.ts is dark (tokens.css: "a fixed dark-brand desktop tool"), so
 * one bright-on-dark pair is correct everywhere. If a light theme is ever
 * added, this is the file that has to learn about it.
 */
import { deriveAccentRamp, getThemePreset } from "../../../../lib/themes";
import { parseHexColor } from "./labelColors";

const GOLDEN_ANGLE = 137.508;
/** First step away from the accent's own hue, so PR #1 never reads as "this one is selected". */
const FIRST_OFFSET = 42;
const LANE_SATURATION = 74;
const LANE_LIGHTNESS = 63;

/** tokens.css's --sapphire-500, for when neither the theme nor the accent override can be read. */
const FALLBACK_ACCENT = "#4fa3ff";

/** sRGB hue in degrees, or null when the string isn't a hex color. */
export function hueOf(hex: string | null | undefined): number | null {
  const rgb = parseHexColor(hex);
  if (!rgb) return null;
  const r = rgb.r / 255;
  const g = rgb.g / 255;
  const b = rgb.b / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  if (delta === 0) return 0;
  let hue: number;
  if (max === r) hue = ((g - b) / delta) % 6;
  else if (max === g) hue = (b - r) / delta + 2;
  else hue = (r - g) / delta + 4;
  hue *= 60;
  return hue < 0 ? hue + 360 : hue;
}

/**
 * The accent hex the app is actually wearing right now, read from SETTINGS
 * rather than from getComputedStyle.
 *
 * useApplyAppearance writes the theme's custom properties in an effect, so a
 * render that reacts to a theme change would read the OUTGOING values off
 * the document - every lane color would be one theme behind. The preset
 * table and deriveAccentRamp are the same inputs that effect uses, minus the
 * timing hazard.
 */
export function activeAccentHex(appTheme: string | undefined, accentColor: string | null | undefined): string {
  if (accentColor) {
    const ramp = deriveAccentRamp(accentColor);
    if (ramp?.["--sapphire-500"]) return ramp["--sapphire-500"];
  }
  const preset = getThemePreset(appTheme ?? "");
  return preset.overrides["--sapphire-500"] ?? preset.preview.accent ?? FALLBACK_ACCENT;
}

/**
 * Lane color for the nth PR. Returned as an `hsl()` string, not a hex: it
 * goes straight into an SVG stroke and into `color-mix()` for the legend
 * chips, and skipping the round trip back through hex keeps this file free
 * of a second copy of themes.ts's private hslToHex.
 */
export function prLaneColor(index: number, accentHex: string): string {
  const base = hueOf(accentHex) ?? hueOf(FALLBACK_ACCENT) ?? 210;
  const hue = (base + FIRST_OFFSET + index * GOLDEN_ANGLE) % 360;
  return `hsl(${hue.toFixed(1)} ${LANE_SATURATION}% ${LANE_LIGHTNESS}%)`;
}
