import type { ITheme } from "@xterm/xterm";

/**
 * xterm.js color schemes for the embedded terminal, keyed by the shared
 * theme-id contract (settings.preferences.terminalTheme; the Settings
 * dialog's picker writes these exact ids). Every entry is a *full* ITheme:
 * background/foreground/cursor/cursorAccent/selectionBackground plus all
 * 16 ANSI slots, taken from each scheme's published palette.
 *
 * These are inherently literal hex values - xterm's renderer cannot
 * resolve CSS custom properties, so `northstar` copies the app's own
 * tokens (app/src/styles/tokens.css) by hand. Keep that entry in sync if
 * the tokens ever change.
 */

export const TERMINAL_THEME_IDS = [
  "northstar",
  "dracula",
  "nord",
  "tokyo-night",
  "catppuccin-mocha",
  "gruvbox-dark",
  "one-dark",
  "solarized-dark",
  "monokai",
  "synthwave",
] as const;

export type TerminalThemeId = (typeof TERMINAL_THEME_IDS)[number];

export const DEFAULT_TERMINAL_THEME: TerminalThemeId = "northstar";

export const TERMINAL_THEMES: Record<TerminalThemeId, ITheme> = {
  /** The app's own look - tokens.css as literals (gunmetal ground, sapphire accent, ember red). */
  northstar: {
    background: "#0d1219", // --gm-950 / --surface-sunken
    foreground: "#f2f5f9", // --text-primary
    cursor: "#4fa3ff", // --sapphire-500
    cursorAccent: "#061019", // --text-on-accent
    selectionBackground: "#4fa3ff40", // --sapphire-500 @ 25%
    black: "#131a26", // --gm-900
    red: "#ff6b3d", // --ember-500
    green: "#98c379", // --signal-green
    yellow: "#ffb020", // --signal-amber
    blue: "#4fa3ff", // --sapphire-500
    magenta: "#c678dd", // --signal-violet
    cyan: "#56b6c2", // --signal-cyan
    white: "#aab4c4", // --text-secondary
    brightBlack: "#6b7a90", // --gm-400
    brightRed: "#ff8f66", // --ember-400
    brightGreen: "#b5e890",
    brightYellow: "#e5c07b", // --signal-sand
    brightBlue: "#79c0ff", // --sapphire-400
    brightMagenta: "#d99df2",
    brightCyan: "#7bd4de",
    brightWhite: "#f2f5f9", // --text-primary
  },

  dracula: {
    background: "#282a36",
    foreground: "#f8f8f2",
    cursor: "#f8f8f2",
    cursorAccent: "#282a36",
    selectionBackground: "#44475a",
    black: "#21222c",
    red: "#ff5555",
    green: "#50fa7b",
    yellow: "#f1fa8c",
    blue: "#bd93f9",
    magenta: "#ff79c6",
    cyan: "#8be9fd",
    white: "#f8f8f2",
    brightBlack: "#6272a4",
    brightRed: "#ff6e6e",
    brightGreen: "#69ff94",
    brightYellow: "#ffffa5",
    brightBlue: "#d6acff",
    brightMagenta: "#ff92df",
    brightCyan: "#a4ffff",
    brightWhite: "#ffffff",
  },

  nord: {
    background: "#2e3440",
    foreground: "#d8dee9",
    cursor: "#d8dee9",
    cursorAccent: "#2e3440",
    selectionBackground: "#434c5e",
    black: "#3b4252",
    red: "#bf616a",
    green: "#a3be8c",
    yellow: "#ebcb8b",
    blue: "#81a1c1",
    magenta: "#b48ead",
    cyan: "#88c0d0",
    white: "#e5e9f0",
    brightBlack: "#4c566a",
    brightRed: "#bf616a",
    brightGreen: "#a3be8c",
    brightYellow: "#ebcb8b",
    brightBlue: "#81a1c1",
    brightMagenta: "#b48ead",
    brightCyan: "#8fbcbb",
    brightWhite: "#eceff4",
  },

  "tokyo-night": {
    background: "#1a1b26",
    foreground: "#c0caf5",
    cursor: "#c0caf5",
    cursorAccent: "#1a1b26",
    selectionBackground: "#283457",
    black: "#15161e",
    red: "#f7768e",
    green: "#9ece6a",
    yellow: "#e0af68",
    blue: "#7aa2f7",
    magenta: "#bb9af7",
    cyan: "#7dcfff",
    white: "#a9b1d6",
    brightBlack: "#414868",
    brightRed: "#f7768e",
    brightGreen: "#9ece6a",
    brightYellow: "#e0af68",
    brightBlue: "#7aa2f7",
    brightMagenta: "#bb9af7",
    brightCyan: "#7dcfff",
    brightWhite: "#c0caf5",
  },

  "catppuccin-mocha": {
    background: "#1e1e2e", // base
    foreground: "#cdd6f4", // text
    cursor: "#f5e0dc", // rosewater
    cursorAccent: "#1e1e2e",
    selectionBackground: "#585b70", // surface2
    black: "#45475a", // surface1
    red: "#f38ba8",
    green: "#a6e3a1",
    yellow: "#f9e2af",
    blue: "#89b4fa",
    magenta: "#f5c2e7", // pink
    cyan: "#94e2d5", // teal
    white: "#bac2de", // subtext1
    brightBlack: "#585b70", // surface2
    brightRed: "#f38ba8",
    brightGreen: "#a6e3a1",
    brightYellow: "#f9e2af",
    brightBlue: "#89b4fa",
    brightMagenta: "#f5c2e7",
    brightCyan: "#94e2d5",
    brightWhite: "#a6adc8", // subtext0
  },

  "gruvbox-dark": {
    background: "#282828",
    foreground: "#ebdbb2",
    cursor: "#ebdbb2",
    cursorAccent: "#282828",
    selectionBackground: "#504945",
    black: "#282828",
    red: "#cc241d",
    green: "#98971a",
    yellow: "#d79921",
    blue: "#458588",
    magenta: "#b16286",
    cyan: "#689d6a",
    white: "#a89984",
    brightBlack: "#928374",
    brightRed: "#fb4934",
    brightGreen: "#b8bb26",
    brightYellow: "#fabd2f",
    brightBlue: "#83a598",
    brightMagenta: "#d3869b",
    brightCyan: "#8ec07c",
    brightWhite: "#ebdbb2",
  },

  "one-dark": {
    background: "#282c34",
    foreground: "#abb2bf",
    cursor: "#528bff",
    cursorAccent: "#282c34",
    selectionBackground: "#3e4451",
    black: "#282c34",
    red: "#e06c75",
    green: "#98c379",
    yellow: "#d19a66",
    blue: "#61afef",
    magenta: "#c678dd",
    cyan: "#56b6c2",
    white: "#abb2bf",
    brightBlack: "#5c6370",
    brightRed: "#e06c75",
    brightGreen: "#98c379",
    brightYellow: "#e5c07b",
    brightBlue: "#61afef",
    brightMagenta: "#c678dd",
    brightCyan: "#56b6c2",
    brightWhite: "#ffffff",
  },

  "solarized-dark": {
    background: "#002b36", // base03
    foreground: "#839496", // base0
    cursor: "#839496",
    cursorAccent: "#002b36",
    selectionBackground: "#073642", // base02
    black: "#073642", // base02
    red: "#dc322f",
    green: "#859900",
    yellow: "#b58900",
    blue: "#268bd2",
    magenta: "#d33682",
    cyan: "#2aa198",
    white: "#eee8d5", // base2
    brightBlack: "#586e75", // base01 (kept visible - the canonical #002b36 slot vanishes on its own background)
    brightRed: "#cb4b16", // orange
    brightGreen: "#859900",
    brightYellow: "#b58900",
    brightBlue: "#839496", // base0
    brightMagenta: "#6c71c4", // violet
    brightCyan: "#93a1a1", // base1
    brightWhite: "#fdf6e3", // base3
  },

  monokai: {
    background: "#272822",
    foreground: "#f8f8f2",
    cursor: "#f8f8f2",
    cursorAccent: "#272822",
    selectionBackground: "#49483e",
    black: "#272822",
    red: "#f92672",
    green: "#a6e22e",
    yellow: "#f4bf75",
    blue: "#66d9ef",
    magenta: "#ae81ff",
    cyan: "#a1efe4",
    white: "#f8f8f2",
    brightBlack: "#75715e",
    brightRed: "#f92672",
    brightGreen: "#a6e22e",
    brightYellow: "#f4bf75",
    brightBlue: "#66d9ef",
    brightMagenta: "#ae81ff",
    brightCyan: "#a1efe4",
    brightWhite: "#f9f8f5",
  },

  /**
   * Blend of the published "synthwave-everything" terminal scheme and
   * Robb Owen's SynthWave '84 editor palette (same family; the terminal
   * port's literal cyan slots are pink, which wrecks ls/git legibility,
   * so cyan here uses '84's iconic #36f9f6 instead).
   */
  synthwave: {
    background: "#262335",
    foreground: "#f0eff1",
    cursor: "#f92aad",
    cursorAccent: "#262335",
    selectionBackground: "#463465",
    black: "#2a2139",
    red: "#fe4450",
    green: "#72f1b8",
    yellow: "#fede5d",
    blue: "#6d77b3",
    magenta: "#ff7edb",
    cyan: "#36f9f6",
    white: "#d5d0e5",
    brightBlack: "#848bbd",
    brightRed: "#f97e72",
    brightGreen: "#72f1b8",
    brightYellow: "#fff951",
    brightBlue: "#36f9f6",
    brightMagenta: "#e1acff",
    brightCyan: "#36f9f6",
    brightWhite: "#fefefe",
  },
};

/**
 * Resolves a terminalTheme preference value (possibly unset while settings
 * load, possibly an id this build doesn't know) to a concrete ITheme.
 * Falls back to northstar rather than throwing - an unknown id in
 * settings.json must never take the terminal down.
 */
export function resolveTerminalTheme(id: string | null | undefined): ITheme {
  return TERMINAL_THEMES[(id ?? DEFAULT_TERMINAL_THEME) as TerminalThemeId] ?? TERMINAL_THEMES[DEFAULT_TERMINAL_THEME];
}
