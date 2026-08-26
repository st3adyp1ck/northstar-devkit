import { useCallback, useEffect, useRef, useState, type PropsWithChildren, type ReactNode } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { AnimatePresence } from "framer-motion";
import clsx from "clsx";
import { useApplyAppearance } from "../hooks/useApplyAppearance";
import { useVisibility } from "../hooks/useVisibility";
import { useSettingsStore } from "../stores/useSettingsStore";
import { sidecarRestart, sidecarStatus } from "../lib/ipc";
import { playSound } from "../lib/sounds";
import { SettingsDialog } from "./settings/SettingsDialog";
import { ErrorCenterHost, openErrorCenter, useUnseenErrorCount } from "./errors";
import "./TitleBar.css";

interface TitleBarProps extends PropsWithChildren {
  title: string;
  icon?: ReactNode;
  onHide?: () => void;
  showMaximize?: boolean;
  actions?: ReactNode;
}

function GearIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h.01a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

/** How often to ask Rust whether the PowerShell sidecar process is still up. */
const SIDECAR_POLL_MS = 10_000;

type SidecarHealth = "unknown" | "alive" | "dead";

function describeInvokeError(err: unknown): string {
  if (err instanceof Error && err.message) return err.message;
  if (typeof err === "string" && err) return err;
  return "The sidecar host did not respond.";
}

/**
 * The one place in the app that tells you the PowerShell sidecar has died.
 *
 * Every window renders a TitleBar, so hosting this here covers all of them
 * with a single mount - the same trick the Settings gear uses. It is the
 * shared half of the "honest errors" fix: individual panels say what THEY
 * can't show (see usePolledRpc's PolledRpcStatus), this says why, once, and
 * offers the one action that fixes it.
 *
 * Healthy is a small green dot with a soft breathing halo (see
 * .devkit-sidecar--ok): a positive signal you can read at a glance without
 * it ever becoming a control. It stays a 6px dot with no label and no click
 * target, because a status monitor that SHOUTS while everything is fine
 * trains you to stop looking at it - the glow is the whole message.
 *
 * A failed status CHECK is not treated as a dead sidecar. `sidecar_status`
 * only reads an AtomicBool, so a rejection means the question broke, not
 * the answer - we hold the last known state and put the reason in the
 * tooltip rather than raising a false alarm.
 */
function SidecarHealthIndicator() {
  const visible = useVisibility();
  const [health, setHealth] = useState<SidecarHealth>("unknown");
  const [checkError, setCheckError] = useState<string | null>(null);
  const [restarting, setRestarting] = useState(false);
  const [restartError, setRestartError] = useState<string | null>(null);
  const mounted = useRef(true);

  // Declared first so it is the LAST cleanup to run on unmount, and so a
  // StrictMode remount flips it back to true before the poll effect below
  // schedules anything.
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const check = useCallback(async (): Promise<boolean | null> => {
    try {
      const alive = await sidecarStatus();
      if (mounted.current) {
        setCheckError(null);
        setHealth(alive ? "alive" : "dead");
      }
      return alive;
    } catch (err) {
      if (mounted.current) setCheckError(describeInvokeError(err));
      return null;
    }
  }, []);

  // Same contract as every polled panel: nothing runs while the window is
  // hidden, and the first check on becoming visible is immediate.
  useEffect(() => {
    if (!visible) return;
    void check();
    const timer = window.setInterval(() => void check(), SIDECAR_POLL_MS);
    return () => window.clearInterval(timer);
  }, [visible, check]);

  async function restart() {
    setRestarting(true);
    setRestartError(null);
    try {
      await sidecarRestart();
      // Re-ask rather than assume: sidecar_restart resolving means the
      // respawn returned Ok, and the status bool is the authority.
      const alive = await check();
      if (alive) {
        playSound("success");
      }
    } catch (err) {
      if (mounted.current) setRestartError(describeInvokeError(err));
      playSound("error");
    } finally {
      if (mounted.current) setRestarting(false);
    }
    // Panels recover on their own from here - every usePolledRpc query keeps
    // its refetchInterval running through an error, so the next tick lands
    // on a live sidecar with no per-panel retry needed.
  }

  if (health !== "dead") {
    const label = health === "alive" ? "Sidecar healthy" : "Checking sidecar…";
    return (
      <span
        className={clsx("devkit-sidecar", health === "alive" && "devkit-sidecar--ok")}
        role="img"
        aria-label={label}
        title={checkError ? `${label} (status check failed: ${checkError})` : label}
      >
        <span className="devkit-sidecar__dot" />
      </span>
    );
  }

  return (
    <span className="devkit-sidecar devkit-sidecar--down">
      <button
        type="button"
        className="devkit-sidecar__btn devkit-no-drag"
        onClick={() => void restart()}
        disabled={restarting}
        aria-label="Sidecar offline - restart it"
        title="The PowerShell sidecar isn't running. Click to restart it."
      >
        <span className="devkit-sidecar__dot" />
        <span className="devkit-sidecar__label">{restarting ? "Restarting…" : "Sidecar offline"}</span>
      </button>
      {restartError && (
        <span className="devkit-sidecar__error" role="alert">
          {restartError}
        </span>
      )}
    </span>
  );
}

/**
 * Custom chrome for undecorated windows - a drag region plus minimal window
 * controls, matching decorations:false in tauri.conf.json.
 *
 * Also the app's Settings mount point: both windows render a TitleBar, so
 * hosting the gear button + SettingsDialog here (and the appearance-applier
 * hook that makes themes/fonts/scale live) gives every window Settings for
 * free without touching either App root. The dialog renders as a sibling of
 * the drag-region div (fragment), so its full-window overlay never sits
 * inside -webkit-app-region: drag. The sidecar health dot rides along for
 * the same reason - one mount, every window.
 */
export function TitleBar({ title, icon, onHide, showMaximize, actions, children }: TitleBarProps) {
  const win = getCurrentWindow();
  const [settingsOpen, setSettingsOpen] = useState(false);
  useApplyAppearance();

  // While the widget is DOCKED (Left/Right), it must be genuinely
  // immovable: the Rust side already made it non-resizable and pinned it,
  // but an undecorated window is dragged via -webkit-app-region: drag on
  // this titlebar - so drop the drag region entirely in docked mode. The
  // Control Center (and a Floating widget) stay draggable as normal.
  //
  // This MUST stay a live read off the settings store with no local copy.
  // Caching it (or reading it once on mount) is what produced the
  // undraggable-floating-window bug: switching Right -> Floating from the
  // Control Center changed settings.json, but this window's own store was
  // never told, so it kept withholding the drag region on a window that was
  // no longer docked. The fix is the `devkit://settings-changed` broadcast
  // being wired into useSettingsStore by the settings-sync work; the moment
  // that lands, this selector re-runs and the drag region comes back with
  // zero changes here.
  const dockMode = useSettingsStore((s) => s.settings?.preferences.widgetDockMode);
  const isDockedWidget = win.label === "widget" && (dockMode === "Left" || dockMode === "Right");

  return (
    <>
      <div className={clsx("devkit-titlebar", !isDockedWidget && "devkit-drag-region")}>
        <div className="devkit-titlebar__brand">
          {icon}
          <span className="devkit-titlebar__title">{title}</span>
        </div>
        <div className="devkit-titlebar__middle">{children}</div>
        {/*
          Two groups, one hairline. Left of the rule: things that act on the
          APP - sidecar health, then whatever this window contributes via
          `actions`, then the two affordances every window gets for free.
          Right of the rule: things that act on the WINDOW. The separation is
          what lets a 380px-wide docked widget still read as ordered rather
          than as one undifferentiated run of icons.
        */}
        <div className="devkit-titlebar__controls devkit-no-drag">
          <div className="devkit-titlebar__group">
            <SidecarHealthIndicator />
            {actions}
            <ErrorCenterButton />
            <button
              type="button"
              className="devkit-titlebar__btn devkit-no-drag"
              aria-label="Settings"
              title="Settings"
              onClick={() => setSettingsOpen(true)}
            >
              <GearIcon />
            </button>
          </div>
          <span className="devkit-titlebar__divider" aria-hidden="true" />
          <div className="devkit-titlebar__group devkit-titlebar__group--window">
            <button
              type="button"
              className="devkit-titlebar__btn"
              aria-label="Minimize"
              title="Minimize"
              onClick={() => win.minimize()}
            >
              &#8211;
            </button>
            {showMaximize && (
              <button
                type="button"
                className="devkit-titlebar__btn"
                aria-label="Maximize"
                title="Maximize"
                onClick={() => win.toggleMaximize()}
              >
                &#9723;
              </button>
            )}
            <button
              type="button"
              className="devkit-titlebar__btn devkit-titlebar__btn--close"
              aria-label={onHide ? "Hide" : "Close"}
              title={onHide ? "Hide" : "Close"}
              onClick={() => (onHide ? onHide() : win.close())}
            >
              &#10005;
            </button>
          </div>
        </div>
      </div>
      <AnimatePresence>{settingsOpen && <SettingsDialog onClose={() => setSettingsOpen(false)} />}</AnimatePresence>
      {/* One mount per window, same trick as SettingsDialog above. TitleBar
          renders inside <ConfirmDialogHost> in both window roots, which the
          Error Center needs for its destructive "clear" confirmations. */}
      <ErrorCenterHost />
    </>
  );
}

/**
 * Raises the Error Center, with a badge counting entries the user hasn't
 * looked at yet.
 *
 * Deliberately quiet when there is nothing to report: no badge, standard
 * titlebar-button styling, same visual weight as the gear. It only draws
 * attention (accent badge, danger tint) once something has actually gone
 * wrong - the same restraint the sidecar health dot uses, so a healthy app
 * has no permanent warning furniture in its chrome.
 */
function ErrorCenterButton() {
  const unseen = useUnseenErrorCount();
  const label = unseen > 0 ? `Errors (${unseen} new)` : "Errors";

  return (
    <button
      type="button"
      className={clsx("devkit-titlebar__btn devkit-no-drag", unseen > 0 && "devkit-titlebar__btn--alert")}
      aria-label={label}
      title={label}
      onClick={() => {
        playSound("click");
        openErrorCenter();
      }}
    >
      <AlertIcon />
      {unseen > 0 && (
        <span className="devkit-titlebar__badge" aria-hidden="true">
          {unseen > 99 ? "99+" : unseen}
        </span>
      )}
    </button>
  );
}

function AlertIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z" />
      <line x1="12" y1="9" x2="12" y2="13" />
      <line x1="12" y1="17" x2="12.01" y2="17" />
    </svg>
  );
}
