import { useEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";
import clsx from "clsx";
import type { FlyoutDockSide } from "./useWidgetFlyout";
import { RailIcon, type IconTheme, type RailIconName } from "./railIcons";
import { moveTrayId } from "./tabOrder";
import "./WidgetFlyout.css";

export interface FlyoutTabDef {
  id: string;
  label: string;
  icon: RailIconName;
}

interface FlyoutTabRailProps {
  tabs: FlyoutTabDef[];
  /** Which tab reads "lit", or null when every tray is shut. */
  activeId: string | null;
  /** Dock side of the widget - the rail lives on the opposite (screen-facing) edge. */
  side: FlyoutDockSide;
  /** Glyph style, straight off preferences.iconTheme. */
  iconTheme: IconTheme;
  onSelect: (id: string) => void;
  /**
   * Commits a rearrangement - the COMPLETE tab id list in its new order,
   * from a pointer drag or Alt+Arrow. Omit to render a fixed rail.
   */
  onReorder?: (ids: string[]) => void;
  /** The brand plate at the foot of the rail - the Control Center tray's tab. */
  onBrand: () => void;
  /** True while the Control Center tray is the open one - the plate lights like any other active tab. */
  brandActive?: boolean;
  /** Tooltip/label for the brand plate, e.g. "Open the Control Center tray". */
  brandTitle: string;
}

/** Movement below this is a click; at or past it, a drag. */
const DRAG_THRESHOLD_PX = 5;

interface DragState {
  id: string;
  from: number;
  /** Slot the dragged tab would land in if released now. */
  over: number;
  /** Raw pointer travel, for the dragged tab's own transform. */
  dy: number;
}

function clampIndex(value: number, count: number): number {
  return Math.max(0, Math.min(count - 1, value));
}

/**
 * The pull-tabs from the original WPF widget, redrawn in the JARVIS
 * language: a vertical strip of glyph buttons on the sidebar's INNER edge
 * (right edge when docked Left, left edge when docked Right), each with a
 * hairline accent light on the pane-facing side that brightens on hover and
 * breathes while its tray is open - the same living-light-strip vocabulary
 * as .widget-rail, one notch quieter because there are five of them.
 *
 * Two zones, and the split is the whole point of the layout: the tab group
 * takes ALL the leftover height and centres itself inside it, while the
 * DEVKIT plate is a fixed block flush to the foot. Adding another tray
 * re-centres the group automatically and never moves the plate.
 *
 * The tabs are DRAG-REARRANGEABLE (and Alt+ArrowUp/Down for keyboard).
 * Pointer-based, not HTML5 DnD, for the same reason the pane resizer is:
 * full control over threshold, capture and visuals. A press only becomes a
 * drag after DRAG_THRESHOLD_PX of travel, and a completed drag swallows the
 * click that the browser fires after pointerup - otherwise every
 * rearrangement would also toggle the dragged tray. The commit hands the
 * full id order to onReorder; this component owns no order state, so the
 * parent's persisted answer is the only truth and a failed save simply
 * snaps the rail back.
 *
 * Sizing (rail width, glyph size, glyph style) is entirely settings-driven -
 * see .widget-app's --rail-width / --rail-icon in WidgetApp.css for why
 * those are divided by --ui-scale before they reach here.
 */
export function FlyoutTabRail({
  tabs,
  activeId,
  side,
  iconTheme,
  onSelect,
  onReorder,
  onBrand,
  brandActive = false,
  brandTitle,
}: FlyoutTabRailProps) {
  const tabsRef = useRef<HTMLDivElement>(null);
  /** Pressed-but-not-yet-dragging, keyed to one pointer. */
  const pressRef = useRef<{ id: string; index: number; startY: number; pointerId: number } | null>(null);
  /** Centre-to-centre distance between adjacent tab slots, measured at drag start. */
  const slotHeightRef = useRef(0);
  /** A completed drag must eat the click the browser fires right after it. */
  const suppressClickRef = useRef(false);
  /**
   * The LIVE gesture. Pointer events arrive faster than React re-renders
   * (real hardware delivers moves at 125-250Hz), so a handler that read the
   * render-time `drag` closure would see stale state for every event inside
   * a frame - re-entering the start branch per move and racing the commit.
   * The ref is the truth the handlers read and write; the state below only
   * mirrors it so the transforms render.
   */
  const dragRef = useRef<DragState | null>(null);
  const [drag, setDrag] = useState<DragState | null>(null);

  function updateDrag(next: DragState | null) {
    dragRef.current = next;
    setDrag(next);
  }
  /**
   * Tab to refocus after a KEYBOARD move. Reordering makes React move the
   * button's DOM node, and a moved node loses focus to the document - so
   * without this, Alt+Arrow works exactly once and then types into nothing.
   */
  const refocusIdRef = useRef<string | null>(null);

  useEffect(() => {
    if (!refocusIdRef.current) return;
    const id = refocusIdRef.current;
    refocusIdRef.current = null;
    tabsRef.current?.querySelector<HTMLButtonElement>(`[data-tab-id="${CSS.escape(id)}"]`)?.focus();
  }, [tabs]);

  function beginPress(e: ReactPointerEvent<HTMLButtonElement>, id: string, index: number) {
    if (e.button !== 0 || !onReorder) return;
    suppressClickRef.current = false;
    pressRef.current = { id, index, startY: e.clientY, pointerId: e.pointerId };
  }

  function trackPress(e: ReactPointerEvent<HTMLButtonElement>, id: string) {
    const press = pressRef.current;
    if (!press || press.pointerId !== e.pointerId || press.id !== id) return;
    const dy = e.clientY - press.startY;

    const live = dragRef.current;
    if (!live) {
      if (Math.abs(dy) < DRAG_THRESHOLD_PX) return;
      const tabsEl = tabsRef.current;
      const first = tabsEl?.children[0] as HTMLElement | undefined;
      const second = tabsEl?.children[1] as HTMLElement | undefined;
      // Slot pitch from live layout (button height + the flex gap), so a
      // resized rail or icon setting never desyncs the math. Measured with
      // rects, NOT offsetTop: the widget root carries a CSS `zoom`, and
      // offsetTop answers in pre-zoom layout px while the pointer's clientY
      // (the numerator) is in visual px - rects speak the pointer's space.
      slotHeightRef.current =
        first && second
          ? second.getBoundingClientRect().top - first.getBoundingClientRect().top
          : (first?.getBoundingClientRect().height ?? 40);
      try {
        e.currentTarget.setPointerCapture(e.pointerId);
      } catch {
        // Capture is an assist (it keeps moves flowing when the pointer
        // strays off the button mid-drag), not a precondition - a pointer
        // that cannot be captured still drags while it stays on the rail.
      }
      suppressClickRef.current = true;
      updateDrag({ id: press.id, from: press.index, over: press.index, dy });
      return;
    }

    const shift = Math.round(dy / Math.max(1, slotHeightRef.current));
    updateDrag({ ...live, dy, over: clampIndex(press.index + shift, tabs.length) });
  }

  function endPress(e: ReactPointerEvent<HTMLButtonElement>) {
    const press = pressRef.current;
    if (!press || press.pointerId !== e.pointerId) return;
    pressRef.current = null;
    const live = dragRef.current;
    if (live && live.id === press.id) {
      if (live.over !== live.from && onReorder) {
        onReorder(
          moveTrayId(
            tabs.map((t) => t.id),
            live.id,
            live.over,
          ),
        );
      }
      updateDrag(null);
    }
  }

  function keyboardMove(e: React.KeyboardEvent<HTMLButtonElement>, id: string, index: number) {
    if (!onReorder || !e.altKey || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
    e.preventDefault();
    const to = index + (e.key === "ArrowUp" ? -1 : 1);
    if (to < 0 || to >= tabs.length) return;
    refocusIdRef.current = id;
    onReorder(
      moveTrayId(
        tabs.map((t) => t.id),
        id,
        to,
      ),
    );
  }

  /** During a drag, how many slots tab `index` is displaced to make room. */
  function displacedBy(index: number): number {
    if (!drag || index === drag.from) return 0;
    if (drag.from < drag.over && index > drag.from && index <= drag.over) return -1;
    if (drag.over < drag.from && index >= drag.over && index < drag.from) return 1;
    return 0;
  }

  return (
    <nav
      className={clsx(
        "flyout-rail",
        side === "Right" ? "flyout-rail--dock-right" : "flyout-rail--dock-left",
        drag && "flyout-rail--reordering",
      )}
      aria-label="Trays"
    >
      <div className="flyout-rail__tabs" ref={tabsRef}>
        {tabs.map((tab, index) => {
          const active = tab.id === activeId;
          const dragging = drag?.id === tab.id;
          const displaced = displacedBy(index);
          const style: CSSProperties | undefined = dragging
            ? { transform: `translateY(${drag.dy}px)` }
            : displaced !== 0
              ? { transform: `translateY(${displaced * slotHeightRef.current}px)` }
              : undefined;
          return (
            <button
              key={tab.id}
              data-tab-id={tab.id}
              type="button"
              className={clsx(
                "flyout-rail__tab",
                active && "flyout-rail__tab--active",
                dragging && "flyout-rail__tab--dragging",
              )}
              style={style}
              aria-label={tab.label}
              aria-pressed={active}
              aria-keyshortcuts={onReorder ? "Alt+ArrowUp Alt+ArrowDown" : undefined}
              title={active ? `Close ${tab.label}` : `Open ${tab.label}`}
              onClick={() => {
                // The click that trails a completed drag is not a toggle.
                if (suppressClickRef.current) {
                  suppressClickRef.current = false;
                  return;
                }
                onSelect(tab.id);
              }}
              onPointerDown={(e) => beginPress(e, tab.id, index)}
              onPointerMove={(e) => trackPress(e, tab.id)}
              onPointerUp={endPress}
              onPointerCancel={endPress}
              onKeyDown={(e) => keyboardMove(e, tab.id, index)}
            >
              <RailIcon name={tab.icon} theme={iconTheme} />
              <span className="flyout-rail__light" aria-hidden="true" />
            </button>
          );
        })}
      </div>

      {/* A plate, not a button: full rail width, square, seated on a lit
          seam, with the rose silkscreened over a legend. It should read as
          the bottom section of the instrument's chassis. */}
      <button
        type="button"
        className={clsx("flyout-rail__brand", brandActive && "flyout-rail__brand--active")}
        aria-label={brandTitle}
        aria-pressed={brandActive}
        title={brandTitle}
        onClick={onBrand}
      >
        <span className="flyout-rail__brand-seam" aria-hidden="true" />
        <RailIcon name="devkit" theme={iconTheme} className="flyout-rail__brand-mark" />
        <span className="flyout-rail__brand-label">DEVKIT</span>
      </button>
    </nav>
  );
}
