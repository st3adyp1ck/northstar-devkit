import { AnimatePresence, motion, type Transition } from "framer-motion";
import clsx from "clsx";
import type { ErrorEntry } from "../../stores/useErrorStore";
import { Badge } from "../primitives/Badge";
import { EASE_STANDARD, motionDuration, motionReduced } from "../../windows/widget/panels/motion";
import { ErrorDetail } from "./ErrorDetail";
import { formatRelative, SEVERITY_LABEL } from "./format";

interface ErrorRowProps {
  entry: ErrorEntry;
  expanded: boolean;
  /** The app-errors section is deliberately the smaller of the two - tighter rows, smaller type. */
  compact?: boolean;
  onToggle: () => void;
  onDismiss: () => void;
}

/**
 * One fault, collapsed to a single line: severity dot, title, origin,
 * relative time, and an ×N badge when the store has collapsed repeats into
 * this row. Clicking anywhere on the line opens the full detail drawer
 * (ErrorDetail) underneath it - the dismiss button sits outside that
 * click target so "get rid of this" never means "expand this".
 */
export function ErrorRow({ entry, expanded, compact, onToggle, onDismiss }: ErrorRowProps) {
  const transition: Transition = motionReduced()
    ? { duration: 0 }
    : { duration: motionDuration("--duration-base", 200), ease: EASE_STANDARD };

  return (
    <div className={clsx("error-row", compact && "error-row--compact", expanded && "error-row--expanded")}>
      <div className="error-row__head">
        <button type="button" className="error-row__summary" aria-expanded={expanded} onClick={onToggle}>
          <span className={clsx("error-row__dot", `error-row__dot--${entry.severity}`)} aria-hidden="true" />
          <span className="error-row__text">
            <span className="error-row__title">{entry.title}</span>
            <span className="error-row__sub">
              <span>{SEVERITY_LABEL[entry.severity]}</span>
              {entry.origin && (
                <>
                  <span aria-hidden="true">·</span>
                  <span className="error-row__origin">{entry.origin}</span>
                </>
              )}
              <span aria-hidden="true">·</span>
              <span>{formatRelative(entry.timestamp)}</span>
            </span>
          </span>
          {entry.count > 1 && (
            <Badge tone="neutral" className="error-row__count">
              &times;{entry.count}
            </Badge>
          )}
          <svg
            className={clsx("error-row__chevron", expanded && "error-row__chevron--open")}
            width="10"
            height="10"
            viewBox="0 0 10 10"
            aria-hidden="true"
          >
            <path d="M1 3 L5 7 L9 3" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <button
          type="button"
          className="error-row__dismiss"
          aria-label={`Dismiss: ${entry.title}`}
          title="Dismiss"
          onClick={onDismiss}
        >
          &#10005;
        </button>
      </div>

      <AnimatePresence initial={false}>
        {expanded && (
          <motion.div
            className="error-row__drawer"
            initial={{ height: 0, opacity: 0 }}
            animate={{ height: "auto", opacity: 1 }}
            exit={{ height: 0, opacity: 0 }}
            transition={transition}
          >
            <ErrorDetail entry={entry} onDismiss={onDismiss} />
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
