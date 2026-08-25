import { createContext, useCallback, useContext, type ReactNode } from "react";
import { useSettingsStore } from "../stores/useSettingsStore";

export interface ConfirmOptions {
  title: string;
  /** ReactNode, not string - so callers can bold/highlight the target, e.g. Stop <strong>{name}</strong> (PID {pid})? */
  description: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  /** Renders the confirm button as Button's "danger" variant instead of "primary" - pass true for anything that kills a process, deletes state, etc. */
  danger?: boolean;
}

export interface PendingConfirm extends ConfirmOptions {
  action: () => void | Promise<void>;
}

export interface ConfirmDialogContextValue {
  request: (options: ConfirmOptions, action: () => void | Promise<void>) => void;
}

/**
 * Provided by <ConfirmDialogHost/> (components/ConfirmDialogHost.tsx),
 * which is mounted once near the root of each window's App component.
 * Not meant to be read directly anywhere else - go through
 * useConfirmDestructive below.
 */
export const ConfirmDialogContext = createContext<ConfirmDialogContextValue | null>(null);

/**
 * The gate every destructive action in the app should call through
 * instead of firing its RPC directly. Reads
 * settings.preferences.confirmDestructive and either runs `action`
 * immediately (setting off) or hands it to the shared ConfirmDialog and
 * only runs it if the user confirms:
 *
 *   const confirmDestructive = useConfirmDestructive();
 *   // in a click handler:
 *   confirmDestructive(
 *     { title: "Kill process?", description: <>Stop <strong>{name}</strong> (PID {pid})?</>, danger: true },
 *     async () => { await rpcCall("process.kill", { pid }); },
 *   );
 *
 * Requires a <ConfirmDialogHost/> mounted somewhere above in the tree
 * (WidgetApp and ControlCenterApp each mount one - see WidgetApp.tsx /
 * ControlCenterApp.tsx) so every caller in a window shares one dialog
 * instance instead of hand-rolling its own open/busy state. If no host is
 * mounted, falls back to running the action immediately rather than
 * silently swallowing the click.
 *
 * While settings are still loading (settings === null, briefly, right
 * after a window opens - ConfirmDialogHost kicks off the fetch on mount),
 * this defaults to confirming rather than skipping the prompt: the
 * backend's own default for this preference is `true` (see
 * tools/lib/DevKit-Common.ps1's Get-DevKitSettings $defaults), so failing
 * open here would let a destructive click through unconfirmed during that
 * gap even though the value that's about to load is almost always "on".
 */
export function useConfirmDestructive() {
  const ctx = useContext(ConfirmDialogContext);
  const settings = useSettingsStore((s) => s.settings);

  return useCallback(
    (options: ConfirmOptions, action: () => void | Promise<void>) => {
      const confirmEnabled = settings ? settings.preferences.confirmDestructive : true;
      if (!confirmEnabled || !ctx) {
        void action();
        return;
      }
      ctx.request(options, action);
    },
    [ctx, settings],
  );
}
