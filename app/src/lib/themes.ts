/**
 * The 10 app/terminal theme presets - the shared theme-name contract for
 * this feature batch (appTheme and terminalTheme both take these exact
 * ids; the xterm mapping lives with TerminalView's owner).
 *
 * Each preset is a set of CSS custom-property OVERRIDES applied on
 * document.documentElement (see hooks/useApplyAppearance.ts). We keep the
 * existing token NAMES from styles/tokens.css - --sapphire-* stays the
 * accent ramp, --ember-* the danger ramp, --gm-* the surface ground -
 * and only override values, so every component keeps working untouched.
 * The derived tokens (--surface-*, --accent, --danger, --text-link, the
 * glows) are all var()/color-mix chains over these ramps, so they follow
 * automatically.
 *
 * This file DEFINES palettes, so it is inherently full of literal hexes -
 * the one sanctioned exception to the no-hardcoded-hex house rule.
 */

export interface ThemePreset {
  id: string;
  label: string;
  /** Custom-property overrides for document.documentElement; empty = tokens.css defaults. */
  overrides: Record<string, string>;
  /** Literal colors for the Settings picker's swatch cards (northstar has no overrides to read them from). */
  preview: {
    accent: string;
    danger: string;
    /** Deep app background. */
    surface: string;
    /** Raised panel surface. */
    raised: string;
    text: string;
  };
}

export const THEMES: ThemePreset[] = [
  {
    // tokens.css IS the northstar theme - no overrides, ever. Resetting to
    // this theme must return the app to its stylesheet defaults.
    id: "northstar",
    label: "Northstar",
    overrides: {},
    preview: { accent: "#4fa3ff", danger: "#ff6b3d", surface: "#0d1219", raised: "#182031", text: "#f2f5f9" },
  },
  {
    id: "dracula",
    label: "Dracula",
    overrides: {
      "--gm-950": "#1e2029",
      "--gm-900": "#282a36",
      "--gm-850": "#2c2e3a",
      "--gm-800": "#313442",
      "--gm-700": "#44475a",
      "--gm-600": "#565b74",
      "--gm-500": "#6272a4",
      "--gm-400": "#7e8ab8",
      "--sapphire-900": "#4d3a80",
      "--sapphire-700": "#9a6ee8",
      "--sapphire-600": "#ab80f2",
      "--sapphire-500": "#bd93f9",
      "--sapphire-400": "#cfaefb",
      "--sapphire-300": "#e0c8fd",
      "--ember-800": "#6e2222",
      "--ember-700": "#8f2c2c",
      "--ember-600": "#d94444",
      "--ember-500": "#ff5555",
      "--ember-400": "#ff7b7b",
      "--text-primary": "#f8f8f2",
      "--text-secondary": "#b8bdd8",
      "--text-tertiary": "#6272a4",
      "--text-on-accent": "#1e1f29",
    },
    preview: { accent: "#bd93f9", danger: "#ff5555", surface: "#1e2029", raised: "#2c2e3a", text: "#f8f8f2" },
  },
  {
    id: "nord",
    label: "Nord",
    overrides: {
      "--gm-950": "#242933",
      "--gm-900": "#2e3440",
      "--gm-850": "#333a48",
      "--gm-800": "#3b4252",
      "--gm-700": "#434c5e",
      "--gm-600": "#4c566a",
      "--gm-500": "#5c6a80",
      "--gm-400": "#7a8699",
      "--sapphire-900": "#3f5c66",
      "--sapphire-700": "#6fa8ba",
      "--sapphire-600": "#7bb4c5",
      "--sapphire-500": "#88c0d0",
      "--sapphire-400": "#a3d0dd",
      "--sapphire-300": "#c0e0e8",
      "--ember-800": "#5e3138",
      "--ember-700": "#7d4046",
      "--ember-600": "#a85259",
      "--ember-500": "#bf616a",
      "--ember-400": "#d08b92",
      "--text-primary": "#eceff4",
      "--text-secondary": "#d8dee9",
      "--text-tertiary": "#7b88a1",
      "--text-on-accent": "#20242c",
    },
    preview: { accent: "#88c0d0", danger: "#bf616a", surface: "#242933", raised: "#333a48", text: "#eceff4" },
  },
  {
    id: "tokyo-night",
    label: "Tokyo Night",
    overrides: {
      "--gm-950": "#131420",
      "--gm-900": "#1a1b26",
      "--gm-850": "#1e202e",
      "--gm-800": "#24283b",
      "--gm-700": "#2f344d",
      "--gm-600": "#414868",
      "--gm-500": "#545c7e",
      "--gm-400": "#6b7499",
      "--sapphire-900": "#33488a",
      "--sapphire-700": "#5d87e8",
      "--sapphire-600": "#6c95f0",
      "--sapphire-500": "#7aa2f7",
      "--sapphire-400": "#9ab8fa",
      "--sapphire-300": "#bcd0fc",
      "--ember-800": "#6d2c39",
      "--ember-700": "#93384a",
      "--ember-600": "#d15871",
      "--ember-500": "#f7768e",
      "--ember-400": "#f993a6",
      "--text-primary": "#c0caf5",
      "--text-secondary": "#9aa5ce",
      "--text-tertiary": "#565f89",
      "--text-on-accent": "#15161e",
    },
    preview: { accent: "#7aa2f7", danger: "#f7768e", surface: "#131420", raised: "#1e202e", text: "#c0caf5" },
  },
  {
    id: "catppuccin-mocha",
    label: "Catppuccin Mocha",
    overrides: {
      "--gm-950": "#11111b",
      "--gm-900": "#181825",
      "--gm-850": "#1e1e2e",
      "--gm-800": "#242437",
      "--gm-700": "#313244",
      "--gm-600": "#45475a",
      "--gm-500": "#585b70",
      "--gm-400": "#6c7086",
      "--sapphire-900": "#3b5288",
      "--sapphire-700": "#6795ec",
      "--sapphire-600": "#78a4f3",
      "--sapphire-500": "#89b4fa",
      "--sapphire-400": "#a6c6fb",
      "--sapphire-300": "#c3d8fd",
      "--ember-800": "#6a3346",
      "--ember-700": "#8f445d",
      "--ember-600": "#cf6787",
      "--ember-500": "#f38ba8",
      "--ember-400": "#f6a8bd",
      "--text-primary": "#cdd6f4",
      "--text-secondary": "#bac2de",
      "--text-tertiary": "#7f849c",
      "--text-on-accent": "#11111b",
    },
    preview: { accent: "#89b4fa", danger: "#f38ba8", surface: "#11111b", raised: "#1e1e2e", text: "#cdd6f4" },
  },
  {
    id: "gruvbox-dark",
    label: "Gruvbox Dark",
    overrides: {
      "--gm-950": "#1d2021",
      "--gm-900": "#282828",
      "--gm-850": "#32302f",
      "--gm-800": "#3c3836",
      "--gm-700": "#504945",
      "--gm-600": "#665c54",
      "--gm-500": "#7c6f64",
      "--gm-400": "#928374",
      // Gruvbox blue-aqua as accent - the scheme's orange stays out of the
      // accent role so danger (gruvbox red) reads unmistakably.
      "--sapphire-900": "#3a544e",
      "--sapphire-700": "#5b7f75",
      "--sapphire-600": "#6f9489",
      "--sapphire-500": "#83a598",
      "--sapphire-400": "#a3bfb5",
      "--sapphire-300": "#c2d6cf",
      "--ember-800": "#7c1d14",
      "--ember-700": "#9d2418",
      "--ember-600": "#cc241d",
      "--ember-500": "#fb4934",
      "--ember-400": "#fc6f5d",
      "--text-primary": "#ebdbb2",
      "--text-secondary": "#d5c4a1",
      "--text-tertiary": "#a89984",
      "--text-on-accent": "#1d2021",
    },
    preview: { accent: "#83a598", danger: "#fb4934", surface: "#1d2021", raised: "#32302f", text: "#ebdbb2" },
  },
  {
    id: "one-dark",
    label: "One Dark",
    overrides: {
      "--gm-950": "#1b1f27",
      "--gm-900": "#21252b",
      "--gm-850": "#282c34",
      "--gm-800": "#2c313a",
      "--gm-700": "#3a3f4b",
      "--gm-600": "#4b5263",
      "--gm-500": "#5c6370",
      "--gm-400": "#767d8a",
      "--sapphire-900": "#2c4f6d",
      "--sapphire-700": "#4a94d4",
      "--sapphire-600": "#55a2e2",
      "--sapphire-500": "#61afef",
      "--sapphire-400": "#85c2f3",
      "--sapphire-300": "#aad4f7",
      "--ember-800": "#63262c",
      "--ember-700": "#85333b",
      "--ember-600": "#be4b55",
      "--ember-500": "#e06c75",
      "--ember-400": "#e88e95",
      "--text-primary": "#dcdfe4",
      "--text-secondary": "#abb2bf",
      "--text-tertiary": "#5c6370",
      "--text-on-accent": "#171a1f",
    },
    preview: { accent: "#61afef", danger: "#e06c75", surface: "#1b1f27", raised: "#282c34", text: "#dcdfe4" },
  },
  {
    id: "solarized-dark",
    label: "Solarized Dark",
    overrides: {
      "--gm-950": "#00212a",
      "--gm-900": "#002b36",
      "--gm-850": "#03313d",
      "--gm-800": "#073642",
      "--gm-700": "#0e4552",
      "--gm-600": "#175663",
      "--gm-500": "#586e75",
      "--gm-400": "#657b83",
      "--sapphire-900": "#124465",
      "--sapphire-700": "#1e79ba",
      "--sapphire-600": "#2282c6",
      "--sapphire-500": "#268bd2",
      "--sapphire-400": "#4ca4e0",
      "--sapphire-300": "#7fc0ea",
      "--ember-800": "#64230c",
      "--ember-700": "#8a3110",
      "--ember-600": "#ab3f13",
      "--ember-500": "#cb4b16",
      "--ember-400": "#e0703f",
      "--text-primary": "#eee8d5",
      "--text-secondary": "#93a1a1",
      "--text-tertiary": "#657b83",
      "--text-on-accent": "#00212a",
    },
    preview: { accent: "#268bd2", danger: "#cb4b16", surface: "#00212a", raised: "#03313d", text: "#eee8d5" },
  },
  {
    id: "monokai",
    label: "Monokai",
    overrides: {
      "--gm-950": "#1d1e19",
      "--gm-900": "#272822",
      "--gm-850": "#2d2e27",
      "--gm-800": "#34352d",
      "--gm-700": "#45463c",
      "--gm-600": "#57584b",
      "--gm-500": "#6e6f60",
      "--gm-400": "#8a8b7b",
      "--sapphire-900": "#2a5f6a",
      "--sapphire-700": "#4dbcd3",
      "--sapphire-600": "#59cbe1",
      "--sapphire-500": "#66d9ef",
      "--sapphire-400": "#8ce3f3",
      "--sapphire-300": "#b2ecf7",
      "--ember-800": "#6d1233",
      "--ember-700": "#941845",
      "--ember-600": "#d01f60",
      "--ember-500": "#f92672",
      "--ember-400": "#fa5590",
      "--text-primary": "#f8f8f2",
      "--text-secondary": "#c8c8bf",
      "--text-tertiary": "#75715e",
      "--text-on-accent": "#14150f",
    },
    preview: { accent: "#66d9ef", danger: "#f92672", surface: "#1d1e19", raised: "#2d2e27", text: "#f8f8f2" },
  },
  {
    id: "synthwave",
    label: "Synthwave",
    overrides: {
      "--gm-950": "#1a1626",
      "--gm-900": "#241b2f",
      "--gm-850": "#262335",
      "--gm-800": "#2a2139",
      "--gm-700": "#3b3153",
      "--gm-600": "#4e4172",
      "--gm-500": "#635690",
      "--gm-400": "#8079a7",
      // Synthwave '84's neon pink glow as the accent ramp; its hot red stays
      // the danger ramp - close cousins, but the roles keep them apart.
      "--sapphire-900": "#7a3468",
      "--sapphire-700": "#d05eb2",
      "--sapphire-600": "#e76ec7",
      "--sapphire-500": "#ff7edb",
      "--sapphire-400": "#ff9de4",
      "--sapphire-300": "#ffbeed",
      "--ember-800": "#701c22",
      "--ember-700": "#96252d",
      "--ember-600": "#d23640",
      "--ember-500": "#fe4450",
      "--ember-400": "#fe6c76",
      "--text-primary": "#f4eee4",
      "--text-secondary": "#b6a9c7",
      "--text-tertiary": "#8079a7",
      "--text-on-accent": "#241b2f",
    },
    preview: { accent: "#ff7edb", danger: "#fe4450", surface: "#1a1626", raised: "#262335", text: "#f4eee4" },
  },
];

/** The shared contract's ids, in display order. */
export const THEME_IDS = THEMES.map((t) => t.id);

/** Unknown/legacy ids fall back to northstar (empty overrides) rather than throwing - a stale settings.json must never brick the UI. */
export function getThemePreset(id: string): ThemePreset {
  return THEMES.find((t) => t.id === id) ?? THEMES[0];
}

// ---------------------------------------------------------------------------
// Accent-override ramp derivation - a single user-picked hex becomes a small
// --sapphire-* ramp (the hex as -500, plausible lighter/darker HSL steps
// around it) layered on top of whatever theme is active.
// ---------------------------------------------------------------------------

function clamp01(n: number): number {
  return Math.min(1, Math.max(0, n));
}

function hexToHsl(hex: string): { h: number; s: number; l: number } | null {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const int = parseInt(m[1], 16);
  const r = ((int >> 16) & 0xff) / 255;
  const g = ((int >> 8) & 0xff) / 255;
  const b = (int & 0xff) / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return { h: 0, s: 0, l };
  const s = d / (1 - Math.abs(2 * l - 1));
  let h: number;
  if (max === r) h = ((g - b) / d) % 6;
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  h *= 60;
  if (h < 0) h += 360;
  return { h, s: clamp01(s), l };
}

function hslToHex(h: number, s: number, l: number): string {
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hp = ((h % 360) + 360) % 360 / 60;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r = 0;
  let g = 0;
  let b = 0;
  if (hp < 1) [r, g, b] = [c, x, 0];
  else if (hp < 2) [r, g, b] = [x, c, 0];
  else if (hp < 3) [r, g, b] = [0, c, x];
  else if (hp < 4) [r, g, b] = [0, x, c];
  else if (hp < 5) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  const m = l - c / 2;
  const toHex = (v: number) =>
    Math.round(clamp01(v + m) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

/**
 * Derives the accent ramp overrides for a custom accent hex, or null when
 * the string isn't a #rrggbb color (the <input type=color> only emits
 * those, but settings.json is hand-editable).
 */
export function deriveAccentRamp(hex: string): Record<string, string> | null {
  const hsl = hexToHsl(hex);
  if (!hsl) return null;
  const { h, s, l } = hsl;
  return {
    "--sapphire-300": hslToHex(h, s, clamp01(l + 0.24)),
    "--sapphire-400": hslToHex(h, s, clamp01(l + 0.12)),
    "--sapphire-500": hslToHex(h, s, l),
    "--sapphire-600": hslToHex(h, s, clamp01(l - 0.07)),
    "--sapphire-700": hslToHex(h, s, clamp01(l - 0.14)),
    "--sapphire-900": hslToHex(h, clamp01(s - 0.1), clamp01(l - 0.28)),
  };
}
