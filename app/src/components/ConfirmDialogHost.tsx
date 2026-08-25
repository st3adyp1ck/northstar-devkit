import { useCallback, useEffect, useMemo, useState, type PropsWithChildren } from "react";
import { AnimatePresence } from "framer-motion";
import { ConfirmDialogContext, type ConfirmOptions, type PendingConfirm } from "../hooks/useConfirmDestructive";
import { useSettingsStore } from "../stores/useSettingsStore";
import { ConfirmDialog } from "./ConfirmDialog";

/**
 * Owns the single confirm-dialog's open/pending/busy state for one
 * window. Mount once near the root of each window's App component (see
 * WidgetApp.tsx, ControlCenterApp.tsx) - every useConfirmDestructive()
 * call anywhere under it shares this one dialog instance instead of each
 * caller managing its own dialog-open state by hand.
 *
 * Also kicks off the settings.get fetch each window needs to know
 * confirmDestructive's current value at all. QuickActionsPanel does its
 * own refresh() too, but that panel only exists in the widget; each Tauri
 * window is a separate webview with its own zustand store (state isn't
 * shared across windows), so Control Center - and any future window that
 * mounts this host - needs its own fetch too. Calling refresh() twice on
 * the widget (here and in QuickActionsPanel) is harmless.
 */
export function ConfirmDialogHost({ children }: PropsWithChildren) {
  const settings = useSettingsStore((s) => s.settings);
  const refresh = useSettingsStore((s) => s.refresh);
  const [pending, setPending] = useState<PendingConfirm | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!settings) refresh();
  }, [settings, refresh]);

  const request = useCallback((options: ConfirmOptions, action: () => void | Promise<void>) => {
    setPending({ ...options, action });
  }, []);

  const handleConfirm = useCallback(async () => {
    if (!pending) return;
    setBusy(true);
    try {
      await pending.action();
    } finally {
      setBusy(false);
      setPending(null);
    }
  }, [pending]);

  const handleCancel = useCallback(() => {
    if (busy) return;
    setPending(null);
  }, [busy]);

  const contextValue = useMemo(() => ({ request }), [request]);

  return (
    <ConfirmDialogContext.Provider value={contextValue}>
      {children}
      <AnimatePresence>
        {pending && (
          <ConfirmDialog
            title={pending.title}
            description={pending.description}
            confirmLabel={pending.confirmLabel}
            cancelLabel={pending.cancelLabel}
            danger={pending.danger}
            busy={busy}
            onConfirm={handleConfirm}
            onCancel={handleCancel}
          />
        )}
      </AnimatePresence>
    </ConfirmDialogContext.Provider>
  );
}
