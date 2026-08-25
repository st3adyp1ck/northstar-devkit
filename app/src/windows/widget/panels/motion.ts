/**
 * Motion helpers shared by the widget panels. Framer Motion needs numeric
 * seconds, not CSS custom properties, so this reads the live --duration-*
 * value off :root and converts it - which means it automatically collapses
 * to 0 under prefers-reduced-motion too, since tokens.css already zeroes
 * those custom properties in that media query. One read covers both
 * concerns (see tokens.css's own reduced-motion block).
 */

function readCssDurationMs(varName: string, fallbackMs: number): number {
  if (typeof window === "undefined" || typeof getComputedStyle !== "function") return fallbackMs;
  const raw = getComputedStyle(document.documentElement).getPropertyValue(varName).trim();
  if (!raw) return fallbackMs;
  const value = raw.endsWith("ms") ? parseFloat(raw) : raw.endsWith("s") ? parseFloat(raw) * 1000 : NaN;
  return Number.isFinite(value) ? value : fallbackMs;
}

/** Seconds form of a --duration-* token, for framer-motion's `transition.duration`. */
export function motionDuration(varName: "--duration-fast" | "--duration-base" | "--duration-slow", fallbackMs: number): number {
  return readCssDurationMs(varName, fallbackMs) / 1000;
}

/** True when motion should be skipped/collapsed entirely (reduced-motion users get 0ms tokens). */
export function motionReduced(): boolean {
  return readCssDurationMs("--duration-base", 200) === 0;
}

/** Mirrors tokens.css's --ease-standard cubic-bezier, for framer-motion `transition.ease`. */
export const EASE_STANDARD: [number, number, number, number] = [0.2, 0.8, 0.2, 1];
/** Mirrors tokens.css's --ease-spring cubic-bezier. */
export const EASE_SPRING: [number, number, number, number] = [0.34, 1.56, 0.64, 1];

/** Stagger container variants for a first-mount list reveal (WidgetApp's panel column). */
export function staggerContainerVariants() {
  const reduced = motionReduced();
  return {
    hidden: {},
    visible: {
      transition: reduced ? {} : { staggerChildren: 0.06, delayChildren: 0.02 },
    },
  };
}

/** Per-item fade/slide-up variants for staggerContainerVariants' children. */
export function staggerItemVariants() {
  const duration = motionDuration("--duration-slow", 360);
  return {
    hidden: { opacity: 0, y: 10 },
    visible: { opacity: 1, y: 0, transition: { duration, ease: EASE_STANDARD } },
  };
}
