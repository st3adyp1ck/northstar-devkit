import { useEffect, useState } from "react";
import type { ErrorEntry } from "../../stores/useErrorStore";
import { Button } from "../primitives/Button";
import { copyText } from "./clipboard";
import { entryToText, formatExact, formatMetaValue, humanizeKey, SEVERITY_LABEL } from "./format";

type CopyState = "idle" | "copied" | "failed";

/**
 * Everything one entry can tell you: the identity fields, every meta field
 * the producer attached (rendered as a labeled list, whatever the keys turn
 * out to be), and the full untruncated text - stack trace, event message,
 * sidecar output - in monospace.
 *
 * Deliberately renders meta generically rather than switching on source:
 * the system feed's fields come from the Windows Event Log and the app
 * feed's from DevKit's own log, and neither should require a code change
 * here to show up.
 */
export function ErrorDetail({ entry, onDismiss }: { entry: ErrorEntry; onDismiss: () => void }) {
  const [copyState, setCopyState] = useState<CopyState>("idle");
  const metaEntries = entry.meta ? Object.entries(entry.meta).filter(([, v]) => v !== undefined) : [];

  useEffect(() => {
    if (copyState === "idle") return;
    const timer = window.setTimeout(() => setCopyState("idle"), 1600);
    return () => window.clearTimeout(timer);
  }, [copyState]);

  async function onCopy() {
    const ok = await copyText(entryToText(entry));
    setCopyState(ok ? "copied" : "failed");
  }

  return (
    <div className="error-detail">
      <dl className="error-detail__fields">
        <Field label="Severity" value={SEVERITY_LABEL[entry.severity]} />
        <Field label="Source" value={entry.source === "system" ? "Windows Event Log" : "DevKit"} />
        <Field label="When" value={`${formatExact(entry.timestamp)}`} mono />
        {entry.origin && <Field label="Origin" value={entry.origin} mono />}
        {entry.count > 1 && <Field label="Occurrences" value={`${entry.count} times`} />}
        {metaEntries.map(([key, value]) => (
          <Field key={key} label={humanizeKey(key)} value={formatMetaValue(value)} mono />
        ))}
      </dl>

      <pre className="error-detail__body">{entry.detail || "(no further detail)"}</pre>

      <div className="error-detail__actions">
        <Button size="sm" variant="ghost" onClick={() => void onCopy()}>
          {copyState === "copied" ? "Copied" : copyState === "failed" ? "Copy failed" : "Copy details"}
        </Button>
        <Button size="sm" variant="ghost" onClick={onDismiss}>
          Dismiss
        </Button>
      </div>
    </div>
  );
}

function Field({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="error-detail__field">
      <dt className="error-detail__label">{label}</dt>
      <dd className={mono ? "error-detail__value error-detail__value--mono" : "error-detail__value"}>{value}</dd>
    </div>
  );
}
