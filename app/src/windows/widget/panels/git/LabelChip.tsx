import type { CSSProperties } from "react";
import { labelChipColors } from "./labelColors";
import type { GitHubLabel } from "./model";
import "./GitSections.css";

/**
 * One GitHub label, in the repo's own color with a foreground picked by real
 * WCAG contrast math (see labelColors.ts) so it stays readable on both a
 * "#fef2c0" and a "#0e8a16".
 */
export function LabelChip({ label }: { label: GitHubLabel }) {
  const colors = labelChipColors(label.color);
  const style = {
    "--label-bg": colors.background,
    "--label-fg": colors.foreground,
  } as CSSProperties;

  const title = label.description
    ? `${label.name} - ${label.description}`
    : label.name;

  return (
    <span className="gh-label" style={style} title={title}>
      {label.name}
    </span>
  );
}

/**
 * A row of labels, capped so one over-tagged issue can't push everything
 * else off the row. `max` of 0 means "no cap" (the detail view).
 */
export function LabelChips({ labels, max = 0 }: { labels: GitHubLabel[]; max?: number }) {
  if (labels.length === 0) return null;
  const shown = max > 0 ? labels.slice(0, max) : labels;
  const hidden = labels.length - shown.length;
  return (
    <span className="gh-labels">
      {shown.map((label, i) => (
        <LabelChip key={label.id ?? `${label.name}-${i}`} label={label} />
      ))}
      {hidden > 0 && (
        <span className="gh-label gh-label--more" title={labels.slice(shown.length).map((l) => l.name).join(", ")}>
          +{hidden}
        </span>
      )}
    </span>
  );
}
