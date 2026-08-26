import { AnimatePresence, motion, MotionConfig } from "framer-motion";
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
import { GaugesPanel } from "./panels/GaugesPanel";
import { NodePortsPanel } from "./panels/NodePortsPanel";
import { GitPanel } from "./panels/GitPanel";
import { GitHubPanel } from "./panels/GitHubPanel";
import { McpPanel } from "./panels/McpPanel";
import { NotesOnDeckPanel } from "./panels/NotesOnDeckPanel";
import { FilesPanel } from "./panels/FilesPanel";
import { QuickActionsPanel } from "./panels/QuickActionsPanel";
import { TerminalPanel } from "./panels/TerminalPanel";
import { staggerContainerVariants, staggerItemVariants } from "./panels/motion";
import "./WidgetApp.css";

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
  const container = staggerContainerVariants();
  const item = staggerItemVariants();

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
        <div className="widget-app">
          <TitleBar
            title="DevKit"
            onHide={() => toggleWindow("widget")}
            actions={
              <Button size="sm" variant="primary" onClick={() => showWindow("control-center")}>
                DEVKIT
              </Button>
            }
          >
            <ProjectPicker />
          </TitleBar>
          <motion.div className="widget-app__body" variants={container} initial="hidden" animate="visible">
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
