import { useState, type PropsWithChildren, type ReactNode } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { AnimatePresence } from "framer-motion";
import { useApplyAppearance } from "../hooks/useApplyAppearance";
import { SettingsDialog } from "./settings/SettingsDialog";
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

/**
 * Custom chrome for undecorated windows - a drag region plus minimal window
 * controls, matching decorations:false in tauri.conf.json.
 *
 * Also the app's Settings mount point: both windows render a TitleBar, so
 * hosting the gear button + SettingsDialog here (and the appearance-applier
 * hook that makes themes/fonts/scale live) gives every window Settings for
 * free without touching either App root. The dialog renders as a sibling of
 * the drag-region div (fragment), so its full-window overlay never sits
 * inside -webkit-app-region: drag.
 */
export function TitleBar({ title, icon, onHide, showMaximize, actions, children }: TitleBarProps) {
  const win = getCurrentWindow();
  const [settingsOpen, setSettingsOpen] = useState(false);
  useApplyAppearance();

  return (
    <>
      <div className="devkit-titlebar devkit-drag-region">
        <div className="devkit-titlebar__brand">
          {icon}
          <span className="devkit-titlebar__title">{title}</span>
        </div>
        <div className="devkit-titlebar__middle">{children}</div>
        <div className="devkit-titlebar__actions devkit-no-drag">
          {actions}
          <button
            type="button"
            className="devkit-titlebar__btn devkit-no-drag"
            aria-label="Settings"
            title="Settings"
            onClick={() => setSettingsOpen(true)}
          >
            <GearIcon />
          </button>
          <button
            type="button"
            className="devkit-titlebar__btn"
            aria-label="Minimize"
            onClick={() => win.minimize()}
          >
            &#8211;
          </button>
          {showMaximize && (
            <button
              type="button"
              className="devkit-titlebar__btn"
              aria-label="Maximize"
              onClick={() => win.toggleMaximize()}
            >
              &#9723;
            </button>
          )}
          <button
            type="button"
            className="devkit-titlebar__btn devkit-titlebar__btn--close"
            aria-label={onHide ? "Hide" : "Close"}
            onClick={() => (onHide ? onHide() : win.close())}
          >
            &#10005;
          </button>
        </div>
      </div>
      <AnimatePresence>{settingsOpen && <SettingsDialog onClose={() => setSettingsOpen(false)} />}</AnimatePresence>
    </>
  );
}
