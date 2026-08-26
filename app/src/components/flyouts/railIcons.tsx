import type { CSSProperties, ReactNode } from "react";
import clsx from "clsx";
import "./WidgetFlyout.css";

/**
 * ---------- the rail icon set ----------
 * The four tray glyphs plus the DevKit compass rose, drawn three ways so
 * `preferences.iconTheme` is a real change of drawing rather than a filter
 * laid over one picture.
 *
 * Every glyph is authored ONCE, in a single 24-unit box, as up to three
 * pieces:
 *
 *   shape  a CLOSED silhouette. Filled in solid, tinted in duotone,
 *          stroked in outline - the same `d` reads correctly all three ways,
 *          which is what keeps the variants recognisably the same icon.
 *   inner  line work that sits INSIDE the silhouette. Knocked out of the
 *          fill in solid (hence --rail-icon-knockout), drawn in currentColor
 *          everywhere else.
 *   outer  line work OUTSIDE the silhouette (git's branch connectors). Always
 *          currentColor - knocking it out would erase it against the rail.
 *
 * Nothing here is sized in px: the box is 24 units, the SVG stretches to
 * whatever CSS box it is given (--rail-icon-size by default), and stroke
 * widths are in the same 24-unit space - so a glyph at railIconSize 12 and
 * the same glyph at 32 are the identical drawing, scaled. That is the whole
 * reason there is one viewBox and no per-size tuning.
 *
 * Lives in components/flyouts because the rail is its only consumer today;
 * it is deliberately free of any flyout state, so the Settings icon-theme
 * picker can render live previews straight off <RailIcon> (see the report).
 */

export type IconTheme = "outline" | "solid" | "duotone";
export type RailIconName = "git" | "terminal" | "files" | "notes" | "devkit";

const ICON_THEMES: readonly IconTheme[] = ["outline", "solid", "duotone"];

/** Settings can hold anything an older build (or a hand-edited file) wrote. */
export function normalizeIconTheme(value: unknown): IconTheme {
  return ICON_THEMES.includes(value as IconTheme) ? (value as IconTheme) : "outline";
}

interface Glyph {
  shape: ReactNode;
  inner?: ReactNode;
  outer?: ReactNode;
}

const GLYPHS: Record<RailIconName, Glyph> = {
  // Git - three commit nodes on a branch that rejoins the trunk.
  git: {
    shape: (
      <>
        <circle cx="7" cy="5.6" r="2.4" />
        <circle cx="7" cy="18.4" r="2.4" />
        <circle cx="17" cy="10.6" r="2.4" />
      </>
    ),
    outer: (
      <>
        <path d="M7 8V16" />
        <path d="M7 12.4C7 9.6 9.6 9 14.6 10.2" />
      </>
    ),
  },
  // Terminal - a screen with a prompt chevron and a command rule.
  terminal: {
    shape: <rect x="2.6" y="4.2" width="18.8" height="15.6" rx="3.2" />,
    inner: (
      <>
        <path d="M7.2 10L10.2 12.6L7.2 15.2" />
        <path d="M12.8 15.4H16.8" />
      </>
    ),
  },
  // Files - a folder, with the seam of its front flap as the interior line.
  files: {
    shape: (
      <path d="M2.8 7C2.8 5.9 3.7 5 4.8 5H8.9L11.1 7.4H19.2C20.3 7.4 21.2 8.3 21.2 9.4V17.2C21.2 18.3 20.3 19.2 19.2 19.2H4.8C3.7 19.2 2.8 18.3 2.8 17.2V7Z" />
    ),
    inner: <path d="M2.8 9.8H21.2" />,
  },
  // Notes - a dog-eared sheet with two written rules.
  notes: {
    shape: <path d="M5.2 3.8H13.5L18.8 9.1V20.2H5.2V3.8Z" />,
    inner: (
      <>
        <path d="M13.5 3.8V9.1H18.8" />
        <path d="M8.4 13.4H15.6" />
        <path d="M8.4 16.6H12.8" />
      </>
    ),
  },
  // DevKit - the Northstar compass rose: a cardinal four-point star crossed
  // by a smaller inter-cardinal one, pierced at the hub.
  devkit: {
    shape: (
      <>
        <path d="M18.4 5.6L14 12L18.4 18.4L12 14L5.6 18.4L10 12L5.6 5.6L12 10Z" />
        <path d="M12 1.8L14.2 9.8L22.2 12L14.2 14.2L12 22.2L9.8 14.2L1.8 12L9.8 9.8Z" />
      </>
    ),
    inner: <circle cx="12" cy="12" r="1.6" />,
  },
};

export interface RailIconProps {
  name: RailIconName;
  theme?: IconTheme;
  /**
   * Any CSS length. Omit to inherit --rail-icon-size, which is what the rail
   * itself does so one settings value drives every glyph at once.
   */
  size?: string | number;
  className?: string;
}

export function RailIcon({ name, theme = "outline", size, className }: RailIconProps) {
  const glyph = GLYPHS[name];
  const style: CSSProperties | undefined =
    size === undefined ? undefined : { width: size, height: size };

  return (
    <svg
      className={clsx("rail-icon", className)}
      style={style}
      viewBox="0 0 24 24"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {theme === "solid" ? (
        <>
          <g fill="currentColor" stroke="none">
            {glyph.shape}
          </g>
          {glyph.inner && (
            // Knocked out of the fill rather than drawn on top of it: the
            // detail has to read as absence of ink, or a solid icon is just
            // a blob. Falls back to the app surface when the host hasn't
            // published the colour it is actually sitting on.
            <g fill="none" stroke="var(--rail-icon-knockout, var(--surface-app))" strokeWidth="2">
              {glyph.inner}
            </g>
          )}
          {glyph.outer && (
            <g fill="none" stroke="currentColor" strokeWidth="2.2">
              {glyph.outer}
            </g>
          )}
        </>
      ) : theme === "duotone" ? (
        <>
          <g fill="currentColor" stroke="none" opacity="0.24">
            {glyph.shape}
          </g>
          <g fill="none" stroke="currentColor" strokeWidth="1.6">
            {glyph.shape}
            {glyph.inner}
            {glyph.outer}
          </g>
        </>
      ) : (
        <g fill="none" stroke="currentColor" strokeWidth="1.6">
          {glyph.shape}
          {glyph.inner}
          {glyph.outer}
        </g>
      )}
    </svg>
  );
}
