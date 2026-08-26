import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { AnimatePresence, motion, MotionConfig } from "framer-motion";
import clsx from "clsx";
import { useSyncAnimationsAttribute } from "../../hooks/useSyncAnimationsAttribute";
import { useUpdateCheck } from "../../hooks/useUpdateCheck";
import { useSettingsStore } from "../../stores/useSettingsStore";
import type { DevKitPreferences } from "../../lib/types";
import { TitleBar } from "../../components/TitleBar";
import { ProjectPicker } from "../../components/ProjectPicker";
import { Button } from "../../components/primitives/Button";
import { Expander } from "../../components/primitives/Expander";
import { ConfirmDialogHost } from "../../components/ConfirmDialogHost";
import { UpdateDialog } from "../../components/UpdateDialog";
import { FlyoutTabRail, type FlyoutTabDef } from "../../components/flyouts/FlyoutTabRail";
import {
  FlyoutPaneStack,
  PANE_MAX_WIDTH,
  PANE_MIN_WIDTH,
  type FlyoutPaneDef,
} from "../../components/flyouts/FlyoutPaneStack";
import { RailIcon, normalizeIconTheme, type RailIconName } from "../../components/flyouts/railIcons";
import { useWidgetFlyout } from "../../components/flyouts/useWidgetFlyout";
import { showWindow, toggleWindow } from "../../lib/ipc";
import { playSound } from "../../lib/sounds";
import { GaugesPanel } from "./panels/GaugesPanel";
import { NodePortsPanel } from "./panels/NodePortsPanel";
import { GitPanel } from "./panels/GitPanel";
import { McpPanel } from "./panels/McpPanel";
import { NotesOnDeckPanel } from "./panels/NotesOnDeckPanel";
import { FilesPanel } from "./panels/FilesPanel";
import { QuickActionsPanel } from "./panels/QuickActionsPanel";
import { TerminalPanel } from "./panels/TerminalPanel";
import { staggerContainerVariants, staggerItemVariants, slideItemVariants } from "./panels/motion";
import "./WidgetApp.css";

/** Chevron pointing toward the docked edge (collapse direction). */
function CollapseChevron({ side }: { side: "Left" | "Right" }) {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
      <path
        d={side === "Right" ? "M4 2 L8 6 L4 10" : "M8 2 L4 6 L8 10"}
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/**
 * The four trays, in rail order, with their content elements created once at
 * module scope so a tray that is already mounted is never rebuilt when the
 * icon theme (or anything else) changes underneath it.
 */
const TRAYS: ReadonlyArray<{
  id: string;
  label: string;
  icon: RailIconName;
  content: ReactNode;
  fill?: boolean;
}> = [
  { id: "git", label: "Git", icon: "git", content: <GitPanel /> },
  { id: "terminal", label: "Terminal", icon: "terminal", content: <TerminalPanel />, fill: true },
  { id: "files", label: "Files", icon: "files", content: <FilesPanel /> },
  { id: "notes", label: "Notes", icon: "notes", content: <NotesOnDeckPanel /> },
];

/** Keeps a stored/absent flyout width inside something the window can actually show. */
function clampFlyoutWidth(value: number | undefined, fallback: number): number {
  const width = typeof value === "number" && Number.isFinite(value) ? value : fallback;
  return Math.round(Math.min(PANE_MAX_WIDTH, Math.max(PANE_MIN_WIDTH, width)));
}

/** Rail geometry from settings, kept inside what the strip can actually draw. */
function clampRail(value: number | undefined, fallback: number, min: number, max: number): number {
  const size = typeof value === "number" && Number.isFinite(value) ? value : fallback;
  return Math.round(Math.min(max, Math.max(min, size)));
}

/** A drag emits a width per frame; settings.set is a sidecar round-trip. Coalesce. */
const PANE_WIDTH_PERSIST_MS = 300;

/**
 * Width of the collapsed sliver, in LOGICAL px - the strip of glass left on
 * screen when the docked sidebar slides off its edge.
 *
 * THE single owner of that number, and the reason it is here rather than in
 * two places: the sliver has to be exactly as wide as the gap Rust parks the
 * OS window at, and it used to be declared twice - `width: 18px` in
 * WidgetApp.css and `RAIL_FALLBACK_LOGICAL = 18.0` in commands.rs - with
 * nothing tying them together. Worse, `slide_widget` was invoked with no
 * `railWidth` argument at all (it is the only caller), so Rust's
 * `WidgetState::rail_width` was permanently 0 and the fallback was what
 * actually ran; and the CSS `18px` sits inside a root carrying the uiScale
 * `zoom`, so it RENDERED at 18 * uiScale (17.1 logical at 0.95) while Rust
 * reserved a flat 18. Now this constant is both passed to `slide_widget` and
 * published as `--sliver-width`, which the CSS divides by `--ui-scale` (the
 * same idiom as `--flyout-rail-w`) so the drawn strip lands on exactly these
 * logical px at every scale.
 *
 * NOT `preferences.railWidth`: that setting sizes the in-window ICON TAB RAIL,
 * a different strip that lives inside the sidebar's own width.
 */
const WIDGET_RAIL_LOGICAL = 18;

/**
 * The `devkit://widget-geometry` payload (commands.rs::widget_geometry_payload).
 * LOGICAL px, which is the space settings.json speaks.
 */
interface WidgetGeometry {
  side: "Left" | "Right" | "Floating";
  baseWidth: number;
  flyoutWidth: number;
  minWidth: number | null;
  maxWidth: number | null;
  collapsed: boolean;
}

/**
 * Panels are wrapped once here, at the slot they occupy in the column, not
 * inside each panel component - so the stagger plays exactly once when the
 * widget window itself first mounts (opening the widget), not every time a
 * panel's own polled data resolves or a project gets linked/unlinked
 * underneath an already-mounted slot.
 *
 * Docked, the column is only the glanceable half: gauges, quick actions,
 * ports, MCP and GitHub stay inline, while Git / Terminal / Files / Notes
 * move into slide-out trays on the inner edge (see components/flyouts).
 * Floating keeps the original single scrolling column with all nine.
 */
export function WidgetApp() {
  useSyncAnimationsAttribute();
  const enableAnimations = useSettingsStore((s) => s.settings?.preferences.enableAnimations);
  const dockMode = useSettingsStore((s) => s.settings?.preferences.widgetDockMode);
  const gitFlyoutWidth = useSettingsStore((s) => s.settings?.preferences.gitFlyoutWidth);
  const notesFlyoutWidth = useSettingsStore((s) => s.settings?.preferences.notesFlyoutWidth);
  const defaultFlyoutWidth = useSettingsStore((s) => s.settings?.preferences.flyoutWidth);
  const iconThemePref = useSettingsStore((s) => s.settings?.preferences.iconTheme);
  const railWidthPref = useSettingsStore((s) => s.settings?.preferences.railWidth);
  const railIconSizePref = useSettingsStore((s) => s.settings?.preferences.railIconSize);
  const widgetSavedWidth = useSettingsStore((s) => s.settings?.preferences.widgetSavedWidth);
  const updateSettings = useSettingsStore((s) => s.update);

  const iconTheme = normalizeIconTheme(iconThemePref);
  const railWidth = clampRail(railWidthPref, 44, 28, 96);
  const railIconSize = clampRail(railIconSizePref, 18, 10, 40);

  // One derivation of "which edge are we pinned to", null when floating.
  // Everything downstream - the tray rail, the collapse chevron, the flyouts,
  // the entrance direction - reads this, so a dock-mode change arriving from
  // the store (this window's own Settings, or the Control Center via the
  // devkit://settings-changed broadcast) re-derives the whole shell in one
  // render.
  const side = dockMode === "Left" || dockMode === "Right" ? dockMode : null;
  const docked = side !== null;

  // MIRRORED from Rust, not owned here - see the geometry effect below.
  // `WidgetState::collapsed` in commands.rs is the authority, because Rust is
  // what actually parks the OS window off its edge.
  const [collapsed, setCollapsed] = useState(false);
  const mainRef = useRef<HTMLDivElement | null>(null);

  const widthFor = useCallback(
    (id: string) => {
      if (id === "git") return clampFlyoutWidth(gitFlyoutWidth, 300);
      if (id === "notes") return clampFlyoutWidth(notesFlyoutWidth, 300);
      return clampFlyoutWidth(defaultFlyoutWidth, 380);
    },
    [gitFlyoutWidth, notesFlyoutWidth, defaultFlyoutWidth],
  );

  const flyout = useWidgetFlyout({ side, widthFor, mainRef });

  const flyoutPanes = useMemo<FlyoutPaneDef[]>(
    () =>
      TRAYS.map((tray) => ({
        id: tray.id,
        label: tray.label,
        // The pane header is chrome, not rail furniture: it follows the icon
        // THEME but keeps its own size, so widening the rail doesn't inflate
        // every pane title.
        icon: <RailIcon name={tray.icon} theme={iconTheme} size={15} />,
        content: tray.content,
        fill: tray.fill,
      })),
    [iconTheme],
  );
  const flyoutTabs = useMemo<FlyoutTabDef[]>(
    () => TRAYS.map(({ id, label, icon }) => ({ id, label, icon })),
    [],
  );

  const openControlCenter = useCallback(() => {
    playSound("click");
    void showWindow("control-center");
  }, []);

  // ---------- persistence ----------
  // Both of these are patch-only writes (see useSettingsStore.update): only
  // the key that changed is sent, so a width saved here can never revert a
  // preference the Control Center changed a moment ago.

  const paneWidthTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (paneWidthTimer.current) clearTimeout(paneWidthTimer.current);
    },
    [],
  );

  const { activeId: openTrayId, resizePane } = flyout;
  const handlePaneResize = useCallback(
    (width: number, commit: boolean) => {
      // Apply to the window immediately either way - the hook coalesces the
      // stream down to one settled call at a time.
      resizePane(width);
      if (!commit) return;
      // Git and Notes carry their own widths; everything else shares the
      // default. Patch keys only, never the whole preferences object.
      const patch: Partial<DevKitPreferences> =
        openTrayId === "git"
          ? { gitFlyoutWidth: width }
          : openTrayId === "notes"
            ? { notesFlyoutWidth: width }
            : { flyoutWidth: width };
      if (paneWidthTimer.current) clearTimeout(paneWidthTimer.current);
      paneWidthTimer.current = setTimeout(() => {
        paneWidthTimer.current = null;
        void updateSettings(patch);
      }, PANE_WIDTH_PERSIST_MS);
    },
    [openTrayId, resizePane, updateSettings],
  );

  // Last width we know is on disk, so an idle resize storm doesn't turn into
  // a settings write per frame.
  const savedWidthRef = useRef<number | null>(null);
  if (typeof widgetSavedWidth === "number") savedWidthRef.current = widgetSavedWidth;

  // ---------- the geometry round trip ----------
  //
  // Rust owns the widget's geometry state machine (commands.rs) and broadcasts
  // it as `devkit://widget-geometry`, in LOGICAL px, whenever anything changes
  // it. This one listener closes both halves of the loop:
  //
  // 1. `collapsed` is MIRRORED from Rust instead of being an independent copy
  //    here. Every "show the widget" path un-collapses in Rust now (tray click,
  //    tray menu, command palette, global hotkey, second launch - all routed
  //    through commands::surface_widget), and this is how React finds out. It
  //    also makes a webview reload recoverable: a reload that lands while the
  //    sidebar is collapsed used to start React at `collapsed = false` with the
  //    OS window still parked off its edge, which left `.widget-rail` at
  //    `pointer-events: none` - the one control that would slide the window
  //    back out was invisible and unclickable, and the only exit was the
  //    Control Center's dock toggle. The mount-time pull below is what fixes
  //    that specific case, because a reload changes nothing, so no event fires.
  //
  // 2. `widgetSavedWidth` is persisted from the payload's `baseWidth` rather
  //    than by measuring the window here. The window has two rects on Windows
  //    (see the COORDINATE SPACES banner in commands.rs); this used to store
  //    `outerSize()` while `set_widget_dock` read the same number back as a
  //    CLIENT width, so every launch handed the sidebar its own frame inset -
  //    ~15 logical px at 150% - and it grew monotonically, forever, with no
  //    fixed point, until opening any tray pinned min == max and nothing could
  //    be resized in either direction. `baseWidth` is by construction the exact
  //    value Rust will feed back into `base_width`, so N launches with no user
  //    resize now store an identical number. It is also already the SIDEBAR's
  //    own width - an open tray and the collapsed park are both excluded by
  //    Rust - so it needs no guarding for either.
  const applyGeometry = useCallback(
    (geom: WidgetGeometry) => {
      setCollapsed(geom.collapsed === true);
      if (geom.side !== "Left" && geom.side !== "Right") return;
      const width = Math.round(geom.baseWidth);
      if (!Number.isFinite(width) || width <= 0) return;
      // Rust clamps `baseWidth` into this monitor's own range before reporting
      // it, so a value outside [minWidth, maxWidth] means the payload is not
      // describing a real window and must not reach disk. Defence in depth
      // against exactly the artefact sitting in the live settings.json today:
      // `widgetSavedWidth: 158`, which is a minimized window's iconic outer
      // width (237) over the 1.5 scale factor and less than half the floor.
      const min = typeof geom.minWidth === "number" ? geom.minWidth : 1;
      const max = typeof geom.maxWidth === "number" ? geom.maxWidth : Number.MAX_SAFE_INTEGER;
      if (width < min || width > max) return;
      if (width === savedWidthRef.current) return;
      savedWidthRef.current = width;
      // Patch-only write (see useSettingsStore.update): nothing else in
      // preferences is touched.
      void updateSettings({ widgetSavedWidth: width });
    },
    [updateSettings],
  );

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    // Pull once on mount. An event only arrives when something CHANGES, and
    // the state most in need of reconciling - a reload that landed on a
    // collapsed sidebar - is precisely the one where nothing changed.
    void invoke<WidgetGeometry>("widget_geometry")
      .then((geom) => {
        if (!cancelled && geom) applyGeometry(geom);
      })
      .catch(() => {
        // Outside a Tauri webview (vite dev in a plain browser) there is no
        // window and no geometry. The widget still renders; it just can't
        // remember or reconcile.
      });
    void listen<WidgetGeometry>("devkit://widget-geometry", (event) => {
      if (!cancelled && event.payload) applyGeometry(event.payload);
    }).then((un) => {
      // Resolved after unmount - drop it rather than leak a live listener.
      if (cancelled) un();
      else unlisten = un;
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [applyGeometry]);

  // Slide the OS window itself (see commands::slide_widget) - the tray
  // behavior. Sound cues make the glass feel physical.
  async function slideTo(nextCollapsed: boolean) {
    if (!side) return;
    // A collapsing sidebar has to take its tray with it. slide_widget parks
    // the window by reading its CURRENT outer width, so an open flyout would
    // park a double-width window (leaving the pane, not the rail, on screen)
    // and expand back into a sidebar with a tray hanging off it. Settle the
    // width back down first, and wait for it - close() now resolves only
    // once the window has genuinely finished narrowing.
    if (nextCollapsed) await flyout.close();
    // Optimistic: the authoritative value comes back on
    // devkit://widget-geometry a moment later, and matches.
    setCollapsed(nextCollapsed);
    playSound("swoosh");
    try {
      // railWidth was never passed before, and this is slide_widget's ONLY
      // caller - so WidgetState::rail_width sat at 0 for the life of every
      // session and Rust always fell back to RAIL_FALLBACK_LOGICAL. Passing it
      // is what makes the sliver Rust parks and the strip the CSS draws one
      // number with one owner; see WIDGET_RAIL_LOGICAL.
      await invoke("slide_widget", {
        side,
        collapsed: nextCollapsed,
        railWidth: WIDGET_RAIL_LOGICAL,
      });
    } catch {
      setCollapsed(false); // window didn't move - don't strand the rail UI
    }
  }

  // ANY dock-mode change re-pins the window flush against its (new) edge, in
  // the expanded position - so a lingering collapsed=true would render a
  // blank sidebar behind the rail (Left -> Right while collapsed), or a rail
  // floating over a normal window (docked -> Floating). Reset on every
  // change of the mode, not just on leaving docked. (useWidgetFlyout runs
  // the matching reset for the tray itself.)
  useEffect(() => {
    setCollapsed(false);
  }, [dockMode]);

  // NOTE: there is deliberately no devkit://hotkey listener here any more.
  // Un-collapsing on the hotkey used to be this component's private extra
  // step - which is exactly why the other four ways of summoning the widget
  // (tray click, tray menu, command palette, second launch) each surfaced a
  // window parked ~97% off its edge. Rust does it for all five now, in
  // commands::surface_widget, and the geometry listener above carries the
  // resulting `collapsed: false` back here.

  const container = staggerContainerVariants();
  // Docked panels glide out of the docked edge - the tray reveal; floating
  // keeps the original rise-in.
  const item = side ? slideItemVariants(side === "Left" ? "left" : "right") : staggerItemVariants();

  // The ONE auto-check-on-mount call for the whole app - see
  // useUpdateCheck.ts's own comment. QuickActionsPanel's manual "Check for
  // Updates" button reads/drives useUpdaterStore directly instead of
  // calling this hook again.
  const updateCheck = useUpdateCheck();
  const showUpdateDialog =
    updateCheck.status === "downloading" ||
    updateCheck.status === "installing" ||
    (updateCheck.status === "available" && !updateCheck.dismissed) ||
    // An install that failed after the dialog was already showing (status
    // flips to "error" but `update` is still the one that was being
    // installed) stays visible with the error surfaced, rather than
    // vanishing silently - a plain check-time error (`update` still null)
    // has nothing to show here and never reaches this dialog at all.
    (updateCheck.status === "error" && updateCheck.update !== null && !updateCheck.dismissed);

  return (
    // See ControlCenterApp.tsx's own <MotionConfig> for why "never" (not
    // "user"): it's a no-op when animations are enabled. "always" reduces
    // any motion.* element here that doesn't already derive its timing from
    // a --duration-* token - chiefly GlassPanel's own mount fade, which each
    // panel below renders as its root and which checks framer-motion's own
    // (OS-only) useReducedMotion() rather than this setting.
    <MotionConfig reducedMotion={enableAnimations === false ? "always" : "never"}>
      <ConfirmDialogHost>
        <div
          className={clsx(
            "widget-app",
            docked && "widget-app--docked",
            // Which side the dock sits on decides which panel edge is the
            // "interior" one that catches the light (see GlassPanel.css).
            docked && dockMode === "Right" && "widget-app--dock-right",
            collapsed && "widget-app--collapsed",
          )}
          // The two settings that size the icon rail. Raw logical px here;
          // WidgetApp.css divides them by --ui-scale before anything renders
          // - see the comment on --flyout-rail-w there.
          style={
            {
              "--rail-width": `${railWidth}px`,
              "--rail-icon": `${railIconSize}px`,
              // The collapsed sliver, same raw-logical-px convention as the
              // two above: WidgetApp.css divides it by --ui-scale.
              "--sliver-width": `${WIDGET_RAIL_LOGICAL}px`,
            } as CSSProperties
          }
        >
          {/* Tray rail: the WIDGET_RAIL_LOGICAL-wide sliver that stays on
              screen while the window is slid off its edge. Sits on the INNER
              edge (the one facing the desktop). Clicking it glides the glass
              back out - and since `collapsed` is mirrored from Rust, it is
              live even after a webview reload that landed collapsed. */}
          {side && (
            <button
              type="button"
              className={clsx("widget-rail", side === "Right" ? "widget-rail--left" : "widget-rail--right")}
              aria-label="Expand DevKit"
              title="Expand DevKit"
              onClick={() => void slideTo(false)}
            >
              <span className="widget-rail__glyph">
                <CollapseChevron side={side === "Right" ? "Left" : "Right"} />
              </span>
              <span className="widget-rail__line" />
            </button>
          )}
          <div className="widget-app__shell">
            <div
              ref={mainRef}
              className="widget-app__main"
              // Held at a fixed width across the OS window resize so the
              // inline panels never reflow while a tray opens, closes or is
              // dragged wider - see useWidgetFlyout's columnWidth.
              style={
                flyout.columnWidth !== null ? { flex: "0 0 auto", width: flyout.columnWidth } : undefined
              }
            >
              <TitleBar
                title="DevKit"
                onHide={() => toggleWindow("widget")}
                actions={
                  <>
                    {side && (
                      <button
                        type="button"
                        className="devkit-titlebar__btn devkit-no-drag"
                        aria-label="Collapse to tray"
                        title="Collapse to tray"
                        onClick={() => void slideTo(true)}
                      >
                        <CollapseChevron side={side} />
                      </button>
                    )}
                    {/* Docked, this moved to the plate at the foot of the
                        icon rail. Floating there IS no rail, so the titlebar
                        stays the way into the Control Center rather than
                        leaving the window with no way there at all. */}
                    {!docked && (
                      <Button size="sm" variant="primary" onClick={openControlCenter}>
                        DEVKIT
                      </Button>
                    )}
                  </>
                }
              >
                <ProjectPicker />
              </TitleBar>
              {/*
                NO `key` here, deliberately. A key that changes with
                `collapsed` unmounts and remounts this entire subtree on
                every collapse/expand, which killed the live ConPTY session,
                dropped in-flight tool-output subscriptions, and reset every
                draft and scroll position in the column. Variants alone
                replay the cascade: flipping `animate` between "hidden" and
                "visible" re-runs the stagger on the SAME mounted children.
              */}
              <motion.div
                className="widget-app__body"
                variants={container}
                initial="hidden"
                animate={collapsed ? "hidden" : "visible"}
              >
                <motion.div variants={item}>
                  <GaugesPanel />
                </motion.div>
                <motion.div variants={item}>
                  <QuickActionsPanel />
                </motion.div>
                <motion.div variants={item}>
                  <NodePortsPanel />
                </motion.div>
                {/* Docked, these four live in trays instead (below). */}
                {!docked && (
                  <motion.div variants={item}>
                    <GitPanel />
                  </motion.div>
                )}
                {/*
                  PRs and issues are NOT here any more. They live in the Git
                  tray as <GitHubSections/>, which GitPanel renders - so the
                  floating layout above (which renders GitPanel inline,
                  because there are no trays when floating) still shows them,
                  and the docked layout shows them only in the Git tray.
                  Rendering <GitHubPanel/> here as well listed every PR twice.
                */}
                <motion.div variants={item}>
                  <McpPanel />
                </motion.div>
                {!docked && (
                  <>
                    <motion.div variants={item}>
                      <NotesOnDeckPanel />
                    </motion.div>
                    <motion.div variants={item}>
                      <FilesPanel />
                    </motion.div>
                    <motion.div variants={item}>
                      <Expander title="Embedded Terminal" lazyMount>
                        <TerminalPanel />
                      </Expander>
                    </motion.div>
                  </>
                )}
                {/*
                  Docked, four of the nine panels moved into trays and the
                  column now ends well short of the bottom of a full-height
                  sidebar. Rather than backfill that with more data - which
                  would undo the point of moving them out - the run of empty
                  glass is terminated deliberately: `margin-top: auto` pushes
                  this horizon to the foot of the column, so the space above
                  it reads as the instrument's own margin instead of as a
                  panel that failed to load.
                */}
                <motion.div className="widget-app__plinth" variants={item}>
                  <span className="widget-app__horizon" aria-hidden="true" />
                  <span className="widget-app__plinth-legend">Northstar DevKit</span>
                </motion.div>
              </motion.div>
            </div>
            {side && (
              <>
                <FlyoutTabRail
                  tabs={flyoutTabs}
                  activeId={flyout.activeId}
                  side={side}
                  iconTheme={iconTheme}
                  onSelect={flyout.toggle}
                  onBrand={openControlCenter}
                  brandTitle="Open the DevKit Control Center"
                />
                <FlyoutPaneStack
                  panes={flyoutPanes}
                  mountedIds={flyout.mountedIds}
                  activeId={flyout.activeId}
                  width={flyout.paneWidth}
                  side={side}
                  expanded={flyout.expanded}
                  overlay={flyout.overlay}
                  onClose={() => void flyout.close()}
                  onResize={handlePaneResize}
                />
              </>
            )}
          </div>
        </div>
      </ConfirmDialogHost>
      <AnimatePresence>
        {showUpdateDialog && (
          <UpdateDialog
            status={updateCheck.status}
            update={updateCheck.update}
            progress={updateCheck.progress}
            error={updateCheck.error}
            onInstall={() => void updateCheck.installAndRestart()}
            onLater={updateCheck.dismiss}
          />
        )}
      </AnimatePresence>
    </MotionConfig>
  );
}
