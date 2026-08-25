import { useState, type PropsWithChildren, type ReactNode } from "react";
import clsx from "clsx";
import "./Expander.css";

interface ExpanderProps extends PropsWithChildren {
  title: ReactNode;
  /** Rendered on the header's trailing edge (badges, counts) - stays clickable independent of the trigger. */
  actionSlot?: ReactNode;
  defaultOpen?: boolean;
  className?: string;
  /**
   * Don't mount children until the section is opened for the first time
   * (then keep them mounted, so toggling closed doesn't tear them down).
   * Off by default - most expanders (status lists, etc.) are cheap and
   * fine to keep in the DOM for the CSS-only collapse animation. Turn
   * this on for anything with a real side effect on mount (spawning a
   * process, opening a connection) that shouldn't happen just because the
   * section exists on the page.
   */
  lazyMount?: boolean;
}

/**
 * Collapsed-by-default disclosure section. Animates open/close with a CSS
 * grid-template-rows 0fr -> 1fr transition (no JS height measurement, and
 * it degrades gracefully to an instant snap under prefers-reduced-motion
 * since --duration-slow collapses to 0ms there - see tokens.css).
 */
export function Expander({ title, actionSlot, defaultOpen = false, className, lazyMount = false, children }: ExpanderProps) {
  const [open, setOpen] = useState(defaultOpen);
  const [everOpened, setEverOpened] = useState(defaultOpen);

  function toggle() {
    setOpen((v) => {
      const next = !v;
      if (next) setEverOpened(true);
      return next;
    });
  }

  const shouldRenderChildren = !lazyMount || everOpened;

  return (
    <div className={clsx("devkit-expander", className)}>
      <div className="devkit-expander__header">
        <button
          type="button"
          className="devkit-expander__trigger"
          aria-expanded={open}
          onClick={toggle}
        >
          <svg
            className={clsx("devkit-expander__chevron", open && "devkit-expander__chevron--open")}
            width="10"
            height="10"
            viewBox="0 0 10 10"
            aria-hidden="true"
          >
            <path
              d="M1 3 L5 7 L9 3"
              stroke="currentColor"
              strokeWidth="1.5"
              fill="none"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          <span className="devkit-expander__title">{title}</span>
        </button>
        {actionSlot && <div className="devkit-expander__action">{actionSlot}</div>}
      </div>
      <div className={clsx("devkit-expander__panel", open && "devkit-expander__panel--open")}>
        <div className="devkit-expander__panel-inner">{shouldRenderChildren ? children : null}</div>
      </div>
    </div>
  );
}
