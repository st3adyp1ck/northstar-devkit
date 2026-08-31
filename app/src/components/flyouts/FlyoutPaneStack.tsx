import { useCallback, useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent, type KeyboardEvent as ReactKeyboardEvent, type ReactNode } from "react";
import clsx from "clsx";
import { motion } from "framer-motion";
import { staggerContainerVariants, slideItemVariants } from "../../windows/widget/panels/motion";
import { playSound } from "../../lib/sounds";
import type { FlyoutDockSide } from "./useWidgetFlyout";
import "./WidgetFlyout.css";

/** Matches the clamp settings are persisted through, so a drag can't store a width the next open would refuse. */
export const PANE_MIN_WIDTH = 220;
export const PANE_MAX_WIDTH = 900;

export interface FlyoutPaneDef {
  id: string;
  label: string;
  icon: ReactNode;
  content: ReactNode;
  /**
   * Pane fills the available height with a single child (the terminal)
   * instead of scrolling a stack of natural-height cards.
   */
  fill?: boolean;
}

interface FlyoutPaneStackProps {
  panes: FlyoutPaneDef[];
  /** Ids that have ever been opened - rendered and then kept mounted. */
  mountedIds: string[];
  activeId: string | null;
  /** Pane width in logical px (gitFlyoutWidth / notesFlyoutWidth / flyoutWidth). */
  width: number;
  side: FlyoutDockSide;
  /** Rust widened the window for us: the region is a real flex column in the layout. */
  expanded: boolean;
  /** Fallback mode - no window widening available, so float the pane over the column. */
  overlay: boolean;
  onClose: () => void;
  /**
   * A drag (or keyboard nudge) on the pane's edge. `commit` is true on
   * release: that is the one the caller should persist.
   */
  onResize?: (width: number, commit: boolean) => void;
}

function CloseGlyph() {
  return (
    <svg width="11" height="11" viewBox="0 0 12 12" fill="none" aria-hidden="true">
      <path d="M3 3 L9 9 M9 3 L3 9" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  );
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

interface DragState {
  pointerId: number;
  /** SCREEN x, not client x - see the comment in `beginDrag`. */
  startX: number;
  startWidth: number;
  min: number;
  max: number;
}

/**
 * The flyout pane itself: a sheet of projected glass that slides out BESIDE
 * the sidebar, never over it (the Rust side widens the OS window; see
 * useWidgetFlyout's `overlay` for what happens when it can't).
 *
 * Every tray that has ever been opened stays mounted, stacked absolutely on
 * top of each other, and is cross-faded rather than swapped - so switching
 * from Terminal to Git does not kill the ConPTY session, lose a note draft
 * or reset the files tree, and switching back finds everything as it was.
 * Inactive panes keep their pixel size (visibility, not display), which is
 * what keeps xterm's FitAddon from reflowing scrollback into a 0-wide box
 * while the tray is shut.
 */
export function FlyoutPaneStack({
  panes,
  mountedIds,
  activeId,
  width,
  side,
  expanded,
  overlay,
  onClose,
  onResize,
}: FlyoutPaneStackProps) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const dragRef = useRef<DragState | null>(null);
  const draftRef = useRef<number | null>(null);
  const frameRef = useRef<number | null>(null);
  const [draftWidth, setDraftWidth] = useState<number | null>(null);
  const [dragging, setDragging] = useState(false);

  /**
   * How wide this pane is allowed to get right now.
   *
   * The cap is real, not decorative: growing the pane grows the OS WINDOW,
   * and Rust silently clips any request that would push sidebar+pane past
   * the work area - which would leave the pane permanently drawn wider than
   * the window can show it. Everything the sidebar itself occupies (panel
   * column + tab rail) is measured off the live layout rather than assumed,
   * because the rail's width is a user setting.
   */
  const resizeBounds = useCallback((): { min: number; max: number } => {
    let max = PANE_MAX_WIDTH;
    const host = hostRef.current;
    const stack = host?.querySelector<HTMLElement>(".widget-flyout__stack");
    const shell = host?.parentElement;
    if (host && stack && shell && typeof window !== "undefined") {
      const chrome = Math.max(0, shell.getBoundingClientRect().width - stack.getBoundingClientRect().width);
      const available = window.screen?.availWidth ?? 0;
      if (available > 0) {
        const screenBound = Math.round(available - chrome);
        // The Control Center tray opens at fill-the-remaining-screen width,
        // which is legitimately PAST the 900px panel cap on big monitors.
        // Its drag ceiling is the screen itself, or the first drag touch
        // would snap it straight back down to the cap.
        max = activeId === "control-center" ? screenBound : Math.min(max, screenBound);
      }
    }
    return { min: PANE_MIN_WIDTH, max: Math.max(PANE_MIN_WIDTH, max) };
  }, [activeId]);

  /**
   * The ceiling the resizer REPORTS has to be the one the drag enforces. The
   * Control Center tray's is the screen rather than the 900px panel cap, so
   * publishing PANE_MAX_WIDTH left an opened tray reporting an aria-valuenow
   * well past its own aria-valuemax. Resolved in an effect because
   * resizeBounds measures live layout, which a render must not do.
   */
  const [resizeMax, setResizeMax] = useState(PANE_MAX_WIDTH);
  useEffect(() => {
    if (activeId === null) return;
    setResizeMax(resizeBounds().max);
  }, [activeId, resizeBounds]);

  const flushDraft = useCallback(
    (commit: boolean) => {
      const next = draftRef.current;
      if (next === null) return;
      onResize?.(next, commit);
    },
    [onResize],
  );

  function beginDrag(e: ReactPointerEvent<HTMLDivElement>) {
    if (e.button !== 0 || activeId === null || !onResize) return;
    const bounds = resizeBounds();
    dragRef.current = {
      pointerId: e.pointerId,
      // SCREEN coordinates, deliberately. Docked Right, growing the pane
      // moves the OS window's LEFT edge outward, which shifts the viewport
      // origin under a stationary pointer - clientX would then keep climbing
      // on its own and the pane would run away to the cap. screenX is fixed
      // to the monitor and immune to that.
      startX: e.screenX,
      startWidth: width,
      ...bounds,
    };
    draftRef.current = width;
    setDraftWidth(width);
    setDragging(true);
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // The pointer was released between the event and this call. The drag
      // still tracks - it just stops if the cursor leaves the handle.
    }
    e.preventDefault();
  }

  function trackDrag(e: ReactPointerEvent<HTMLDivElement>) {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    // The handle sits on the pane's INNER edge, which is pinned in screen
    // space in both orientations (the sidebar stays flush to its monitor
    // edge and the window grows outward). So "wider" is always away from the
    // dock: right when docked Left, left when docked Right.
    const direction = side === "Left" ? 1 : -1;
    const next = clamp(drag.startWidth + direction * (e.screenX - drag.startX), drag.min, drag.max);
    draftRef.current = next;
    setDraftWidth(next);
    // Coalesced to one window request per frame; useWidgetFlyout coalesces
    // again down to one settled call at a time.
    if (frameRef.current !== null) return;
    frameRef.current = requestAnimationFrame(() => {
      frameRef.current = null;
      flushDraft(false);
    });
  }

  function endDrag(e: ReactPointerEvent<HTMLDivElement>) {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    dragRef.current = null;
    if (frameRef.current !== null) {
      cancelAnimationFrame(frameRef.current);
      frameRef.current = null;
    }
    setDragging(false);
    flushDraft(true);
    draftRef.current = null;
    setDraftWidth(null);
    playSound("thud");
    if (e.currentTarget.hasPointerCapture(drag.pointerId)) {
      e.currentTarget.releasePointerCapture(drag.pointerId);
    }
  }

  function nudge(e: ReactKeyboardEvent<HTMLDivElement>) {
    if (!onResize || activeId === null) return;
    const bounds = resizeBounds();
    const direction = side === "Left" ? 1 : -1;
    const step = e.shiftKey ? 48 : 16;
    let next: number;
    if (e.key === "Home") next = bounds.min;
    else if (e.key === "End") next = bounds.max;
    else if (e.key === "ArrowLeft") next = width - direction * step;
    else if (e.key === "ArrowRight") next = width + direction * step;
    else return;
    e.preventDefault();
    onResize(clamp(Math.round(next), bounds.min, bounds.max), true);
  }

  const mounted = panes.filter((pane) => mountedIds.includes(pane.id));
  if (mounted.length === 0) return null;

  const container = staggerContainerVariants();
  // Content cascades in from the docked edge, so it reads as glass being
  // drawn out of the sidebar rather than a pane fading up in place.
  const item = slideItemVariants(side === "Left" ? "left" : "right");
  // The draft leads the committed width, so the glass tracks the pointer at
  // frame rate while the OS window catches up behind it.
  const shownWidth = draftWidth ?? width;

  return (
    <div
      ref={hostRef}
      className={clsx(
        "widget-flyout",
        side === "Right" ? "widget-flyout--dock-right" : "widget-flyout--dock-left",
        overlay ? "widget-flyout--overlay" : expanded && "widget-flyout--expanded",
        activeId === null && "widget-flyout--closed",
        dragging && "widget-flyout--resizing",
      )}
      style={{ "--flyout-w": `${shownWidth}px` } as CSSProperties}
    >
      <div className="widget-flyout__stack">
        {onResize && activeId !== null && (
          <div
            className="widget-flyout__resizer"
            role="separator"
            aria-orientation="vertical"
            aria-label="Resize tray"
            aria-valuenow={Math.round(shownWidth)}
            aria-valuemin={PANE_MIN_WIDTH}
            // Never below the width actually on screen: the effect above
            // resolves the real ceiling a tick after the tray opens, and
            // valuenow must not outrun valuemax in the meantime.
            aria-valuemax={Math.max(resizeMax, Math.round(shownWidth))}
            tabIndex={0}
            onPointerDown={beginDrag}
            onPointerMove={trackDrag}
            onPointerUp={endDrag}
            onPointerCancel={endDrag}
            onKeyDown={nudge}
          >
            <span className="widget-flyout__grip" aria-hidden="true" />
          </div>
        )}
        {dragging && (
          <div className="widget-flyout__readout" aria-hidden="true">
            {Math.round(shownWidth)}
            <span className="widget-flyout__readout-unit">px</span>
          </div>
        )}
        {mounted.map((pane) => {
          const active = pane.id === activeId;
          return (
            <motion.section
              key={pane.id}
              className={clsx(
                "widget-flyout__pane",
                active && "widget-flyout__pane--active",
                pane.fill && "widget-flyout__pane--fill",
              )}
              aria-label={pane.label}
              aria-hidden={!active}
              variants={container}
              initial="hidden"
              // Variant-driven, never key-driven: the pane must animate in
              // and out without ever unmounting its contents.
              animate={active ? "visible" : "hidden"}
            >
              <motion.header className="widget-flyout__head" variants={item}>
                <span className="widget-flyout__head-icon">{pane.icon}</span>
                <h2 className="widget-flyout__title">{pane.label}</h2>
                <button
                  type="button"
                  className="widget-flyout__close"
                  onClick={onClose}
                  aria-label={`Close ${pane.label}`}
                  title="Close (Esc)"
                >
                  <CloseGlyph />
                </button>
              </motion.header>
              <motion.div className="widget-flyout__body" variants={item}>
                {pane.content}
              </motion.div>
            </motion.section>
          );
        })}
      </div>
    </div>
  );
}
