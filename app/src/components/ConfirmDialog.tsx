import { useEffect, useRef, type ReactNode } from "react";
import { motion, type Transition } from "framer-motion";
import { Button } from "./primitives/Button";
import { GlassPanel } from "./primitives/GlassPanel";
import { useAnimationsEnabled } from "../hooks/useApplyAppearance";
import "./ConfirmDialog.css";

export interface ConfirmDialogProps {
  title: string;
  /** ReactNode, not string - so callers can bold/highlight the target, e.g. Stop <strong>{name}</strong> (PID {pid})? */
  description: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  /** Renders the confirm button as Button's "danger" variant instead of "primary" (per Button.tsx's variants) - for anything that kills a process, deletes state, etc. */
  danger?: boolean;
  /** True while the confirmed action is in flight - disables both buttons, shows a spinner on Confirm, and blocks the overlay/Cancel dismiss so an in-flight request can't be orphaned mid-run. */
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * Shared confirm modal behind the confirmDestructive setting - mirrors
 * control-center/ToolRunDialog.tsx's overlay/backdrop-blur/GlassPanel
 * structure and entrance animation exactly (same overlay fade, same
 * spring-in panel, same click-outside-to-close via the overlay's onClick +
 * e.stopPropagation() on the inner content) so a confirm prompt reads as
 * the same surface family as a tool run, not a bolted-on native dialog.
 *
 * Dumb/presentational by design - see hooks/useConfirmDestructive.ts and
 * components/ConfirmDialogHost.tsx for the piece that owns open/pending
 * state and decides whether to show this at all.
 */
export function ConfirmDialog({
  title,
  description,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  danger = false,
  busy = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  // The in-app Animations setting AND the OS query - framer's own
  // useReducedMotion() only ever reads the OS one, and these transitions
  // animate opacity/scale that MotionConfig's "always" never suppresses.
  const animationsEnabled = useAnimationsEnabled();
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  /*
   * Escape cancels this dialog and owns the key while it is up:
   * preventDefault + stopPropagation keep a surrounding listener (the
   * widget flyout's tray-wide Escape) from unwinding two levels at once.
   * Same terminal/textarea exemption as ToolRunDialog - an Escape typed
   * there belongs to whatever is running or editing.
   */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented || busy) return;
      const t = e.target;
      if (t instanceof Element && (t.closest(".terminal-view") || t.closest("textarea, [contenteditable='true']"))) return;
      e.preventDefault();
      e.stopPropagation();
      onCancel();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [busy, onCancel]);

  const overlayTransition: Transition = animationsEnabled ? { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] } : { duration: 0 };
  const panelTransition: Transition = animationsEnabled
    ? { type: "spring", stiffness: 420, damping: 32, mass: 0.9 }
    : { duration: 0 };

  function handleOverlayClick() {
    if (busy) return; // don't let a click-outside orphan an in-flight action
    onCancel();
  }

  return (
    <motion.div
      className="confirm-dialog__overlay"
      onClick={handleOverlayClick}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={overlayTransition}
    >
      <motion.div
        initial={animationsEnabled ? { opacity: 0, scale: 0.94, y: 16 } : false}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={animationsEnabled ? { opacity: 0, scale: 0.96, y: 8 } : { opacity: 0 }}
        transition={panelTransition}
      >
        <GlassPanel strong className="confirm-dialog">
          <div
            ref={panelRef}
            role="dialog"
            aria-modal="true"
            aria-label={title}
            tabIndex={-1}
            className="confirm-dialog__panel"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="confirm-dialog__title">{title}</div>
            <div className="confirm-dialog__description">{description}</div>
            <div className="confirm-dialog__actions">
              <Button variant="ghost" disabled={busy} onClick={onCancel}>
                {cancelLabel}
              </Button>
              <Button variant={danger ? "danger" : "primary"} loading={busy} onClick={onConfirm}>
                {confirmLabel}
              </Button>
            </div>
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}
