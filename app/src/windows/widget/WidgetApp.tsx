import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { AnimatePresence, motion, MotionConfig } from "framer-motion";
import clsx from "clsx";
import { useSyncAnimationsAttribute } from "../../hooks/useSyncAnimationsAttribute";
import { useUpdateCheck } from "../../hooks/useUpdateCheck";
import { useSettingsStore } from "../../stores/useSettingsStore";
import { TitleBar } from "../../components/TitleBar";
import { ProjectPicker } from "../../components/ProjectPicker";
import { Button } from "../../components/primitives/Button";
import { Expander } from "../../components/primitives/Expander";
import { ConfirmDialogHost } from "../../components/ConfirmDialogHost";
import { UpdateDialog } from "../../components/UpdateDialog";
import { showWindow, toggleWindow } from "../../lib/ipc";
import { playSound } from "../../lib/sounds";
import { GaugesPanel } from "./panels/GaugesPanel";
import { NodePortsPanel } from "./panels/NodePortsPanel";
import { GitPanel } from "./panels/GitPanel";
import { GitHubPanel } from "./panels/GitHubPanel";
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
 * Panels are wrapped once here, at the slot they occupy in the column, not
 * inside each panel component - so the stagger plays exactly once when the
 * widget window itself first mounts (opening the widget), not every time a
 * panel's own polled data resolves or a project gets linked/unlinked
 * underneath an already-mounted slot.
 */
export function WidgetApp() {
  useSyncAnimationsAttribute();
  const enableAnimations = useSettingsStore((s) => s.settings?.preferences.enableAnimations);
  const dockMode = useSettingsStore((s) => s.settings?.preferences.widgetDockMode);
  const docked = dockMode === "Left" || dockMode === "Right";
  const [collapsed, setCollapsed] = useState(false);

  // Slide the OS window itself (see commands::slide_widget) - the tray
  // behavior. Sound cues make the glass feel physical.
  async function slideTo(nextCollapsed: boolean) {
    if (!docked || !dockMode) return;
    setCollapsed(nextCollapsed);
    playSound("swoosh");
    try {
      await invoke("slide_widget", { side: dockMode, collapsed: nextCollapsed });
    } catch {
      setCollapsed(false); // window didn't move - don't strand the rail UI
    }
  }

  // Leaving docked mode (settings switch to Floating / dock side change
  // re-pins) always returns the surface to expanded so the rail can't
  // linger over a normal window.
  useEffect(() => {
    if (!docked) setCollapsed(false);
  }, [docked]);

  const container = staggerContainerVariants();
  // Docked panels glide out of the docked edge - the tray reveal; floating
  // keeps the original rise-in. Keyed on `collapsed` below so every
  // expand replays the cascade.
  const item = docked && dockMode ? slideItemVariants(dockMode === "Left" ? "left" : "right") : staggerItemVariants();

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
        >
          {/* Tray rail: the 18px sliver that stays on screen while the
              window is slid off its edge. Sits on the INNER edge (the one
              facing the desktop). Clicking it glides the glass back out. */}
          {docked && dockMode && (
            <button
              type="button"
              className={clsx("widget-rail", dockMode === "Right" ? "widget-rail--left" : "widget-rail--right")}
              aria-label="Expand DevKit"
              title="Expand DevKit"
              onClick={() => void slideTo(false)}
            >
              <span className="widget-rail__glyph">
                <CollapseChevron side={dockMode === "Right" ? "Left" : "Right"} />
              </span>
              <span className="widget-rail__line" />
            </button>
          )}
          <TitleBar
            title="DevKit"
            onHide={() => toggleWindow("widget")}
            actions={
              <>
                {docked && dockMode && (
                  <button
                    type="button"
                    className="devkit-titlebar__btn devkit-no-drag"
                    aria-label="Collapse to tray"
                    title="Collapse to tray"
                    onClick={() => void slideTo(true)}
                  >
                    <CollapseChevron side={dockMode === "Left" ? "Left" : "Right"} />
                  </button>
                )}
                <Button size="sm" variant="primary" onClick={() => showWindow("control-center")}>
                  DEVKIT
                </Button>
              </>
            }
          >
            <ProjectPicker />
          </TitleBar>
          <motion.div
            key={docked ? `panels-${collapsed ? "in" : "out"}` : "panels"}
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
            <motion.div variants={item}>
              <GitPanel />
            </motion.div>
            <motion.div variants={item}>
              <GitHubPanel />
            </motion.div>
            <motion.div variants={item}>
              <McpPanel />
            </motion.div>
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
          </motion.div>
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
