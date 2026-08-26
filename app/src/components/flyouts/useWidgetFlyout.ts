import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import { invoke } from "@tauri-apps/api/core";
import { playSound } from "../../lib/sounds";

export type FlyoutDockSide = "Left" | "Right";

/**
 * How long to let one width change land before issuing the next.
 *
 * commands.rs::animate_widget steps the OS window over 14 frames of 14ms
 * (~200ms) and then writes the exact target. Every `set_widget_flyout` call
 * re-derives the SIDEBAR's own width from the LIVE window width, so a call
 * that arrives mid-glide reads a half-resized window and bakes the shortfall
 * into the sidebar permanently. See `pumpWindowWidth`.
 */
const WINDOW_SETTLE_MS = 240;

/**
 * Modals that own the Escape key while they're up. SettingsDialog listens on
 * `window` without stopping propagation, so without this check one Escape
 * would close both the dialog and the tray.
 */
const DIALOG_OVERLAY_SELECTOR =
  ".settings-dialog__overlay, .confirm-dialog__overlay, .update-dialog__overlay";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface UseWidgetFlyoutOptions {
  /** Docked side, or null while the widget is Floating (trays are docked-only). */
  side: FlyoutDockSide | null;
  /** Pane width, in logical px, for a given flyout id (git/notes have their own settings). */
  widthFor: (id: string) => number;
  /**
   * The panel column. Measured - not resized - so the column can be held at
   * a fixed pixel width across the moment the OS window changes size.
   */
  mainRef: RefObject<HTMLElement | null>;
}

export interface WidgetFlyoutController {
  /** Which tray is open, or null. */
  activeId: string | null;
  /**
   * Every tray opened at least once. They stay mounted after that: a tray is
   * a place a live thing lives (a ConPTY session, an unsent note draft, a
   * scrolled git log), and unmounting it to "close" it would tear that down -
   * the same class of bug as keying the panel column on `collapsed`.
   */
  mountedIds: string[];
  /** Width the pane currently claims, in logical px. Held through the close animation. */
  paneWidth: number;
  /**
   * Fixed width to hold the panel column at, or null to let it flex.
   *
   * The Rust side widens the OS window a frame or two AFTER React has already
   * rendered the pane beside the column. Without a pin, the column absorbs
   * that shortfall and every inline panel reflows (gauges rewrap, text
   * re-ellipsizes) for those frames. Pinned, the column is immovable and the
   * flyout region simply grows from 0 to its width as the window widens -
   * which is also exactly the "pane slides out of the sidebar" motion we want.
   */
  columnWidth: number | null;
  /** True while the flyout region should claim layout width (open, or still closing). */
  expanded: boolean;
  /**
   * True when the MOST RECENT `set_widget_flyout` was refused. The pane then
   * renders as an in-window overlay drawer instead of waiting on a window
   * that isn't going to widen.
   *
   * Deliberately not a latch: it clears again the moment a call succeeds.
   */
  overlay: boolean;
  /** Open `id`, swap to it, or - if it's already open - close it. */
  toggle: (id: string) => void;
  /**
   * Close whatever is open. Resolves once the window has actually finished
   * narrowing, so callers that need the window back at sidebar width first
   * (collapsing to the tray rail) can await it.
   */
  close: () => Promise<void>;
  /**
   * Retune the open tray to `width` logical px. Safe to call at pointer-move
   * rate: requests coalesce and only ever land on a settled window.
   */
  resizePane: (width: number) => void;
}

/**
 * State machine behind the widget's flyout trays: which tray is open, how
 * wide it is, whether the OS window is playing along, and the transitions
 * that would otherwise strand the user (dock side changing underneath an
 * open tray; the window resize racing React; a tray being dragged wider).
 */
export function useWidgetFlyout({ side, widthFor, mainRef }: UseWidgetFlyoutOptions): WidgetFlyoutController {
  const [activeId, setActiveId] = useState<string | null>(null);
  const [mountedIds, setMountedIds] = useState<string[]>([]);
  const [paneWidth, setPaneWidth] = useState(0);
  const [pinnedMainWidth, setPinnedMainWidth] = useState<number | null>(null);
  const [overlay, setOverlay] = useState(false);

  // Mirrors of the state above, for the event handlers and effects that read
  // "what is open right now" outside of a render.
  const activeIdRef = useRef<string | null>(null);
  const paneWidthRef = useRef(0);
  const overlayRef = useRef(false);
  const sideRef = useRef<FlyoutDockSide | null>(side);
  sideRef.current = side;

  // ---------- the window-width queue ----------
  // `desired` is what the UI wants applied; `applied` is what Rust has been
  // told. The pump walks one to the other, one settled call at a time.
  const desiredWidth = useRef(0);
  const appliedWidth = useRef(0);
  const pumping = useRef(false);
  const drainWaiters = useRef<Array<() => void>>([]);
  const disposed = useRef(false);

  useEffect(
    () => () => {
      disposed.current = true;
    },
    [],
  );

  /**
   * Walks `applied` toward `desired`, one settled window change at a time.
   *
   * Serialising these is not tidiness, it is the fix for the sidebar growing
   * on every fast toggle. `set_widget_flyout` derives the sidebar's own base
   * width as `live window width - the growth it last applied`; fire a second
   * call while the first is still animating and that subtraction reads a
   * window that is only part way there, so the difference is attributed to
   * the SIDEBAR and kept forever. One call, let it land, then the next.
   *
   * `desired` is re-read each turn, so a burst of clicks (or a whole resize
   * drag) collapses into the final width rather than animating through every
   * intermediate one.
   */
  const pump = useCallback(() => {
    if (pumping.current) return;
    pumping.current = true;
    void (async () => {
      try {
        while (!disposed.current) {
          const dockSide = sideRef.current;
          if (!dockSide) {
            // Floating: there is no window to widen, and Rust would refuse.
            desiredWidth.current = 0;
            appliedWidth.current = 0;
            break;
          }
          const want = desiredWidth.current;
          if (want === appliedWidth.current) break;
          try {
            await invoke("set_widget_flyout", {
              side: dockSide,
              open: want > 0,
              // Closing: Rust ignores this and applies 0. Passing the growth
              // being taken back off keeps the call self-describing.
              flyoutWidth: want > 0 ? want : Math.max(0, appliedWidth.current),
            });
          } catch {
            // Per ATTEMPT, never latched. The old code set this on the first
            // rejection and never cleared it, so a single startup race - or
            // one call landing in the instant the widget was Floating -
            // silently downgraded all four trays to in-window drawers for
            // the rest of the session. Now the next open/close asks again.
            overlayRef.current = true;
            setOverlay(true);
            // An un-widened window has to keep flexing.
            setPinnedMainWidth(null);
            break;
          }
          appliedWidth.current = want;
          if (overlayRef.current) {
            overlayRef.current = false;
            setOverlay(false);
          }
          await sleep(WINDOW_SETTLE_MS);
        }
      } finally {
        pumping.current = false;
        const waiters = drainWaiters.current;
        drainWaiters.current = [];
        for (const done of waiters) done();
      }
    })();
  }, []);

  /**
   * Ask Rust for a window that is the sidebar plus `width` logical px, or
   * plus nothing when `width` is 0.
   *
   * INVARIANT: this number is the PANE's width and nothing else. The tab
   * rail, its DEVKIT plate and the whole panel column are IN-WINDOW elements
   * that live inside the sidebar's own width - adding the rail to this
   * figure (or taking it off) is exactly the arithmetic that left the
   * sidebar a rail wider every time a tray was closed. Rust grows the window
   * by round(width * scaleFactor) physical px and shrinks it by the same
   * recorded amount, so open(w) followed by close() is byte-identical -
   * provided every call lands on a settled window, which `pump` guarantees.
   */
  const requestWindowWidth = useCallback(
    (width: number) => {
      desiredWidth.current = width > 0 ? Math.round(width) : 0;
      pump();
    },
    [pump],
  );

  /** Resolves once the queue has drained - i.e. the window really is at the width we asked for. */
  const whenSettled = useCallback((): Promise<void> => {
    if (!pumping.current && desiredWidth.current === appliedWidth.current) return Promise.resolve();
    return new Promise<void>((resolve) => {
      drainWaiters.current.push(resolve);
    });
  }, []);

  const closeInternal = useCallback((): Promise<void> => {
    if (activeIdRef.current === null) return Promise.resolve();
    activeIdRef.current = null;
    setActiveId(null);
    playSound("swoosh");
    requestWindowWidth(0);
    const settled = whenSettled();
    void settled.then(() => {
      // Held until the window has genuinely finished narrowing - releasing
      // the pin early would let the column snap out to fill a window that is
      // still double width. Re-checked because the user may have reopened a
      // tray while we were waiting.
      if (activeIdRef.current === null) setPinnedMainWidth(null);
    });
    return settled;
  }, [requestWindowWidth, whenSettled]);

  const toggle = useCallback(
    (id: string) => {
      if (!side) return;
      if (activeIdRef.current === id) {
        void closeInternal();
        return;
      }
      const width = widthFor(id);
      const wasClosed = activeIdRef.current === null;
      activeIdRef.current = id;
      paneWidthRef.current = width;
      // Only measure on a true open. Swapping trays leaves the column exactly
      // where it is (already pinned), so re-measuring would be a no-op at
      // best and would capture a mid-resize width at worst.
      if (wasClosed) {
        const el = mainRef.current;
        if (el) setPinnedMainWidth(el.offsetWidth);
      }
      setActiveId(id);
      setPaneWidth(width);
      setMountedIds((ids) => (ids.includes(id) ? ids : [...ids, id]));
      playSound("swoosh");
      requestWindowWidth(width);
    },
    [side, widthFor, mainRef, requestWindowWidth, closeInternal],
  );

  const close = useCallback((): Promise<void> => closeInternal(), [closeInternal]);

  const resizePane = useCallback(
    (width: number) => {
      if (activeIdRef.current === null) return;
      const next = Math.round(width);
      if (next === paneWidthRef.current) return;
      paneWidthRef.current = next;
      setPaneWidth(next);
      requestWindowWidth(next);
    },
    [requestWindowWidth],
  );

  // ---------- reconcile once, on first dock ----------
  // Rust's flyout bookkeeping outlives this webview. A reload (a dev-server
  // hot update, a crashed-and-restored webview) starts React back at "no
  // tray open" while FLYOUT_EXTRA_WIDTH still holds the growth from the tray
  // that was open a moment ago - so the sidebar is left permanently a pane
  // wider than it should be, with nothing on this side aware of it.
  //
  // One close on the way in fixes it, and costs nothing on a genuine cold
  // start: Rust's own applied-growth is 0 there, so the call resolves to the
  // width the window already has and returns without moving it.
  const reconciled = useRef(false);
  useEffect(() => {
    if (!side || reconciled.current) return;
    reconciled.current = true;
    // -1 is "we don't know what Rust has applied", which is the honest
    // starting state and the only value that guarantees the pump actually
    // issues the call rather than seeing 0 === 0 and skipping it.
    appliedWidth.current = -1;
    desiredWidth.current = 0;
    pump();
  }, [side, pump]);

  // Escape closes the open tray - but not when a modal is up (it owns the
  // key), and not when the keystroke was typed into the embedded terminal,
  // where Escape belongs to whatever is running in the shell.
  useEffect(() => {
    if (activeId === null) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      if (document.querySelector(DIALOG_OVERLAY_SELECTOR)) return;
      const target = e.target;
      if (target instanceof Element && target.closest(".terminal-view")) return;
      void closeInternal();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [activeId, closeInternal]);

  // Dock mode changing underneath us (Settings, in either window) re-pins the
  // OS window flush to its new edge. An open tray would be baked into that
  // width as permanent sidebar, and its pane would be sitting on the wrong
  // side, so force the tray shut on every real change of side - including
  // Left <-> Right and docked -> Floating.
  //
  // Note what this deliberately does NOT do: send a close of its own.
  // commands.rs::set_widget_dock already folds any flyout growth back into
  // the window and zeroes its own bookkeeping before re-pinning, so the tray
  // is off the window by the time we get here. A close call would at best be
  // a no-op and at worst arrive while the widget was momentarily Floating,
  // where Rust refuses it - a refusal we would then have to treat as a real
  // failure. Resyncing to "nothing applied" is both correct and quieter.
  const prevSide = useRef<FlyoutDockSide | null | undefined>(undefined);
  useEffect(() => {
    const previous = prevSide.current;
    prevSide.current = side;
    if (previous === undefined || previous === side) return;
    if (activeIdRef.current !== null) {
      activeIdRef.current = null;
      setActiveId(null);
    }
    desiredWidth.current = 0;
    appliedWidth.current = 0;
    setPinnedMainWidth(null);
  }, [side]);

  // gitFlyoutWidth / notesFlyoutWidth / flyoutWidth changing while that very
  // tray is open retunes it in place rather than waiting for the next open -
  // which is also how a resize drag's persisted width flows back in (a no-op
  // by then, since resizePane already applied it). Declared AFTER the
  // dock-change effect on purpose: that one nulls activeIdRef synchronously,
  // so a dock flip can't resize a tray it just shut. Reads the ref, not the
  // render's `activeId`, for the same reason.
  useEffect(() => {
    const id = activeIdRef.current;
    if (id === null || !side) return;
    const next = widthFor(id);
    if (next === paneWidthRef.current) return;
    paneWidthRef.current = next;
    setPaneWidth(next);
    requestWindowWidth(next);
  }, [activeId, side, widthFor, requestWindowWidth]);

  return {
    activeId,
    mountedIds,
    paneWidth,
    columnWidth: pinnedMainWidth,
    // The region must keep claiming layout width for the whole close, not
    // just while a tray is nominally open, or the pane would vanish a beat
    // before the window narrows around it.
    expanded: activeId !== null || pinnedMainWidth !== null,
    overlay,
    toggle,
    close,
    resizePane,
  };
}
