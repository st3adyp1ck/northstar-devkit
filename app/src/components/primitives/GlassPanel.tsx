import type { CSSProperties, PropsWithChildren } from "react";
import clsx from "clsx";
import { motion } from "framer-motion";
import { useAnimationsEnabled } from "../../hooks/useApplyAppearance";
import "./GlassPanel.css";

interface GlassPanelProps extends PropsWithChildren {
  className?: string;
  style?: CSSProperties;
  strong?: boolean;
  padded?: boolean;
  /** Skip the mount fade/rise - for a panel rendered inside a parent that's already animating it in (avoids a double entrance). */
  noAnimate?: boolean;
}

const ENTRANCE = {
  hidden: { opacity: 0, y: 8 },
  visible: { opacity: 1, y: 0 },
};

/**
 * Base surface for cards, flyouts, and dialogs - blur + border + shadow,
 * the visual language every panel shares. Also owns the one entrance
 * transition every panel/card gets "for free": a quick fade + rise on
 * first mount (a window's panel appearing, a tool card entering search
 * results, a dialog opening) - not on re-render, since `initial` only
 * applies once per mount and this component's own data changes don't
 * unmount it.
 *
 * `useAnimationsEnabled` short-circuits to the settled state with no
 * animation at all when EITHER the OS prefers reduced motion or the in-app
 * Animations setting is off. It has to be both: this entrance animates
 * opacity, which neither framer's `useReducedMotion()` (OS media query
 * only) nor `MotionConfig reducedMotion="always"` (positional keys only)
 * would ever suppress, so "Animations: off" used to leave every panel and
 * every tool card still fading in.
 */
export function GlassPanel({ children, className, style, strong, padded = true, noAnimate = false }: GlassPanelProps) {
  const animationsEnabled = useAnimationsEnabled();
  const animate = !noAnimate && animationsEnabled;

  return (
    <motion.div
      className={clsx("devkit-glass", strong && "devkit-glass--strong", padded && "devkit-glass--padded", className)}
      style={style}
      initial={animate ? "hidden" : false}
      animate="visible"
      variants={ENTRANCE}
      transition={{ duration: 0.2, ease: [0.2, 0.8, 0.2, 1] }}
    >
      {children}
    </motion.div>
  );
}
