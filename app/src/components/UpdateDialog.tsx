import { motion, useReducedMotion, type Transition } from "framer-motion";
import { Button } from "./primitives/Button";
import { GlassPanel } from "./primitives/GlassPanel";
import type { Update, UpdateDownloadProgress } from "../lib/updater";
import type { UpdateCheckStatus } from "../stores/useUpdaterStore";
import "./UpdateDialog.css";

export interface UpdateDialogProps {
  /** Only "available" | "downloading" | "installing" | "error" ever reach this component - see WidgetApp.tsx's render condition. */
  status: UpdateCheckStatus;
  update: Update | null;
  progress: UpdateDownloadProgress | null;
  error: string | null;
  onInstall: () => void;
  onLater: () => void;
}

/**
 * Shown by WidgetApp when useUpdateCheck() surfaces an available update.
 * Mirrors ConfirmDialog.tsx's overlay/backdrop-blur/GlassPanel structure
 * and entrance animation exactly - same overlay fade, same spring-in
 * panel, same click-outside-to-close (blocked while busy) - so an update
 * prompt reads as the same surface family as a confirm/tool-run dialog,
 * not a bolted-on native one.
 *
 * Dumb/presentational by design, like ConfirmDialog - hooks/useUpdateCheck.ts
 * (backed by stores/useUpdaterStore.ts) owns the actual check/download/
 * install state machine; this component just renders whatever status it's
 * handed and reports the two things a person can do: install, or dismiss.
 */
export function UpdateDialog({ status, update, progress, error, onInstall, onLater }: UpdateDialogProps) {
  const reducedMotion = useReducedMotion();
  const busy = status === "downloading" || status === "installing";

  const overlayTransition: Transition = reducedMotion ? { duration: 0 } : { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] };
  const panelTransition: Transition = reducedMotion
    ? { duration: 0 }
    : { type: "spring", stiffness: 420, damping: 32, mass: 0.9 };

  function handleOverlayClick() {
    if (busy) return; // don't let a click-outside orphan an in-flight download/install
    onLater();
  }

  const percent = progress?.total ? Math.min(100, Math.round((progress.downloaded / progress.total) * 100)) : null;

  return (
    <motion.div
      className="update-dialog__overlay"
      onClick={handleOverlayClick}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={overlayTransition}
    >
      <motion.div
        initial={reducedMotion ? false : { opacity: 0, scale: 0.94, y: 16 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: 0.96, y: 8 }}
        transition={panelTransition}
      >
        <GlassPanel strong className="update-dialog">
          <div onClick={(e) => e.stopPropagation()}>
            <div className="update-dialog__title">Update available{update ? `: v${update.version}` : ""}</div>

            {update?.body && <div className="update-dialog__notes">{update.body}</div>}

            {status === "error" && error && <div className="update-dialog__error">{error}</div>}

            {busy && (
              <div className="update-dialog__progress">
                <div className="update-dialog__progress-track">
                  <div
                    className="update-dialog__progress-fill"
                    style={{ width: percent !== null ? `${percent}%` : "40%" }}
                    data-indeterminate={percent === null || undefined}
                  />
                </div>
                <span className="update-dialog__progress-label">
                  {status === "installing" ? "Installing…" : percent !== null ? `Downloading… ${percent}%` : "Downloading…"}
                </span>
              </div>
            )}

            <div className="update-dialog__actions">
              <Button variant="ghost" disabled={busy} onClick={onLater}>
                Later
              </Button>
              <Button variant="primary" loading={busy} onClick={onInstall}>
                {status === "error" ? "Retry & Restart" : "Install & Restart"}
              </Button>
            </div>
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}
