import clsx from "clsx";
import "./Sparkline.css";

export interface SparklineProps {
  /**
   * Samples in POLL ORDER, oldest first. `null` is an honest gap (a sensor
   * that reported n/a for that tick) and is never plotted as 0 - the line
   * breaks and resumes on the far side.
   */
  values: ReadonlyArray<number | null>;
  /**
   * Full capacity of the caller's ring buffer. A half-full buffer then draws
   * across half the width and grows rightward, instead of stretching four
   * samples across the whole box and pretending to be a full minute.
   */
  capacity?: number;
  /** Value range mapped to the box. Defaults to a 0-100 percentage. */
  min?: number;
  max?: number;
  /** Stroke/fill colour - pass the owning element's tone, e.g. "var(--sapphire-500)". */
  color: string;
  /** Rendered height in CSS px. Width always fills the container. */
  height?: number;
  /** Screen-reader description. Omit for a purely decorative trace. */
  ariaLabel?: string;
  className?: string;
}

/** Horizontal viewBox units. Width is stretched to the container; see preserveAspectRatio below. */
const VIEW_WIDTH = 100;
/** Vertical breathing room so a 0% or 100% sample isn't half-clipped by the stroke. */
const PAD_Y = 1.5;
const STROKE_WIDTH = 1.4;

interface Point {
  x: number;
  y: number;
}

/**
 * Tiny axis-less trend line for a gauge or stat tile.
 *
 * Deliberately dumb about time: it plots sample ORDER, not wall clock. The
 * widget stops polling whenever its window is hidden, so a gap in real time
 * is simply a gap in samples - spacing points by timestamp would either
 * invent data across the pause or squash the live trace into a sliver. What
 * you see is exactly the readings that were actually taken, in the order
 * they arrived.
 *
 * `preserveAspectRatio="none"` stretches the 100-unit-wide viewBox to the
 * container while y stays in real px (viewBox height == CSS height), so
 * every stroke carries `vector-effect: non-scaling-stroke` to keep its
 * thickness honest under that non-uniform scale.
 */
export function Sparkline({
  values,
  capacity,
  min = 0,
  max = 100,
  color,
  height = 28,
  ariaLabel,
  className,
}: SparklineProps) {
  const slots = Math.max(capacity ?? values.length, values.length);
  const span = Math.max(1, slots - 1);
  const range = max - min || 1;
  const baseY = height - 0.5;

  const toPoint = (value: number, index: number): Point => {
    const fraction = Math.min(1, Math.max(0, (value - min) / range));
    return {
      x: (index / span) * VIEW_WIDTH,
      y: PAD_Y + (1 - fraction) * (height - PAD_Y * 2),
    };
  };

  // Split into contiguous runs of real readings. Each run is drawn as its
  // own path, which is what turns a null sample into a visible break.
  const runs: Point[][] = [];
  let current: Point[] = [];
  values.forEach((value, index) => {
    if (value === null || value === undefined || !Number.isFinite(value)) {
      if (current.length) runs.push(current);
      current = [];
      return;
    }
    current.push(toPoint(value, index));
  });
  if (current.length) runs.push(current);

  return (
    <svg
      className={clsx("devkit-sparkline", className)}
      viewBox={`0 0 ${VIEW_WIDTH} ${height}`}
      height={height}
      preserveAspectRatio="none"
      role={ariaLabel ? "img" : undefined}
      aria-label={ariaLabel}
      aria-hidden={ariaLabel ? undefined : true}
    >
      {/* Ground line - keeps an empty or barely-filled buffer reading as
          "no samples yet" rather than as a broken, blank element. */}
      <line
        x1={0}
        y1={baseY}
        x2={VIEW_WIDTH}
        y2={baseY}
        stroke="var(--surface-border)"
        strokeWidth={1}
        vectorEffect="non-scaling-stroke"
      />
      {runs.map((run, i) => {
        const key = `${run[0].x}-${i}`;
        if (run.length === 1) {
          // A lone reading between two gaps: a zero-length round-capped
          // stroke renders as a dot that the horizontal stretch can't
          // squash into an ellipse (unlike <circle>).
          const only = run[0];
          return (
            <path
              key={key}
              d={`M ${only.x} ${only.y} L ${only.x} ${only.y}`}
              fill="none"
              stroke={color}
              strokeWidth={STROKE_WIDTH * 1.4}
              strokeLinecap="round"
              vectorEffect="non-scaling-stroke"
            />
          );
        }
        const line = run.map((p, j) => `${j === 0 ? "M" : "L"} ${p.x.toFixed(2)} ${p.y.toFixed(2)}`).join(" ");
        const area = `M ${run[0].x.toFixed(2)} ${baseY} ${run
          .map((p) => `L ${p.x.toFixed(2)} ${p.y.toFixed(2)}`)
          .join(" ")} L ${run[run.length - 1].x.toFixed(2)} ${baseY} Z`;
        return (
          <g key={key}>
            <path d={area} fill={color} fillOpacity={0.14} stroke="none" />
            <path
              d={line}
              fill="none"
              stroke={color}
              strokeWidth={STROKE_WIDTH}
              strokeLinecap="round"
              strokeLinejoin="round"
              vectorEffect="non-scaling-stroke"
            />
          </g>
        );
      })}
    </svg>
  );
}
