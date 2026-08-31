import { useRef } from "react";
import clsx from "clsx";
import { Sparkline } from "./Sparkline";
import "./Gauge.css";

interface GaugeProps {
  label: string;
  /** 0-100, or null for an honest "n/a" (a sensor that doesn't exist on this machine). */
  percent: number | null;
  sub?: string;
  tone?: "sapphire" | "ember" | "amber" | "cyan";
  size?: number;
  onClick?: () => void;
  /**
   * Recent readings in poll order, oldest first, drawn as a trend line under
   * the label in this gauge's own tone. `null` entries are sensor gaps and
   * break the line rather than plotting as 0. Omit entirely for a metric
   * that doesn't move fast enough to be worth a trace (Disk Free).
   */
  history?: ReadonlyArray<number | null>;
  /** Capacity of the caller's ring buffer, so a partly-filled one grows from the left. */
  historyCapacity?: number;
}

const TONE_VAR: Record<NonNullable<GaugeProps["tone"]>, string> = {
  sapphire: "var(--sapphire-500)",
  ember: "var(--ember-500)",
  amber: "var(--signal-amber)",
  cyan: "var(--signal-cyan)",
};

/**
 * SVG arc gauge, animated by a plain CSS transition on stroke-dashoffset.
 *
 * This REPLACED a rAF loop that eased the value through setState. The loop
 * was honest about stopping when settled, but real metrics never settle:
 * CPU/mem/GPU jitter on nearly every 2s poll, so with three gauges the
 * widget sustained ~40 React commits per second at idle - each one
 * re-rasterizing the arc's drop-shadow filter over the panel's
 * backdrop-blur. A CSS transition costs ONE commit per poll and hands the
 * tween to the compositor's timeline; --duration-gauge keeps the
 * reduced-motion contract (tokens.css zeroes it) with no JS reader. Moves
 * under one percentage point snap with no transition at all, so poll
 * jitter the eye can't see (an arc point is >1%) costs one paint, not 480ms
 * of them.
 */
export function Gauge({
  label,
  percent,
  sub,
  tone = "sapphire",
  size = 92,
  onClick,
  history,
  historyCapacity,
}: GaugeProps) {
  const target = percent ?? 0;
  // The snap-vs-transition decision is sticky per VALUE change, not per
  // render: GaugesPanel re-renders again immediately after each poll (its
  // history effect), and a per-render comparison let that second pass set
  // transition back to "none" before the browser had begun the tween -
  // every arc move became a snap. Written during render on purpose; the
  // decision has to reach the same commit as the offset it governs.
  const prevTargetRef = useRef(target);
  const animRef = useRef(false);
  if (target !== prevTargetRef.current) {
    animRef.current = Math.abs(target - prevTargetRef.current) >= 1;
    prevTargetRef.current = target;
  }
  const animateArc = animRef.current;

  const radius = (size - 12) / 2;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference * (1 - target / 100);
  const color = TONE_VAR[tone];

  return (
    <button
      type="button"
      className={clsx("devkit-gauge", onClick && "devkit-gauge--clickable")}
      onClick={onClick}
      style={{ width: size, cursor: onClick ? "pointer" : "default" }}
    >
      {/* The readout is centered against the DIAL, not the button: anything
          added below (the label, the sub, the sparkline) would otherwise
          drag the "centered" value down off the arc. */}
      <span className="devkit-gauge__dial">
        <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
          <circle
            cx={size / 2}
            cy={size / 2}
            r={radius}
            fill="none"
            stroke="var(--surface-border)"
            strokeWidth={6}
          />
          {percent !== null && (
            <circle
              cx={size / 2}
              cy={size / 2}
              r={radius}
              fill="none"
              stroke={color}
              strokeWidth={6}
              strokeLinecap="round"
              strokeDasharray={circumference}
              strokeDashoffset={offset}
              transform={`rotate(-90 ${size / 2} ${size / 2})`}
              style={{
                filter: `drop-shadow(0 0 6px ${color})`,
                transition: animateArc
                  ? "stroke-dashoffset var(--duration-gauge, 480ms) var(--ease-standard, ease-out)"
                  : "none",
              }}
            />
          )}
        </svg>
        <span className="devkit-gauge__center">
          <span className="devkit-gauge__value">{percent === null ? "n/a" : `${Math.round(percent)}%`}</span>
        </span>
      </span>
      <div className="devkit-gauge__label">{label}</div>
      {/* The sub and spark slots are ALWAYS rendered, with or without
          content: a line that only exists when it has something to say
          moves everything below it every time a reading appears, wraps, or
          disappears - which is exactly the up-and-down bounce this fixes.
          Fixed slots keep all four gauges pixel-identical in height, so the
          sparklines share one baseline and Disk (no history) still ends on
          the same bottom edge. */}
      <div className="devkit-gauge__sub">{sub ?? ""}</div>
      <span className="devkit-gauge__spark">
        {history && (
          <Sparkline
            values={history}
            capacity={historyCapacity}
            color={color}
            height={28}
            ariaLabel={`${label} recent history`}
          />
        )}
      </span>
    </button>
  );
}
