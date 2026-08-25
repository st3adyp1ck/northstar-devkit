import type { PropsWithChildren, ReactNode } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import "./TitleBar.css";

interface TitleBarProps extends PropsWithChildren {
  title: string;
  icon?: ReactNode;
  onHide?: () => void;
  showMaximize?: boolean;
  actions?: ReactNode;
}

/** Custom chrome for undecorated windows - a drag region plus minimal window controls, matching decorations:false in tauri.conf.json. */
export function TitleBar({ title, icon, onHide, showMaximize, actions, children }: TitleBarProps) {
  const win = getCurrentWindow();

  return (
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
  );
}
