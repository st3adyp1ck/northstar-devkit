import { useEffect, useRef, useState } from "react";
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
 * Reads --duration-gauge off the root so the rAF loop's fill duration
 * follows the same reduced-motion contract as every CSS transition in the
 * app (tokens.css zeroes it under prefers-reduced-motion) instead of a
 * hardcoded ms value that would silently ignore that setting.
 */
function gaugeDurationMs(): number {
  if (typeof window === "undefined") return 480;
  const raw = getComputedStyle(document.documentElement).getPropertyValue("--duration-gauge").trim();
  const value = parseFloat(raw);
  if (Number.isNaN(value)) return 480;
  return raw.endsWith("ms") ? value : value * 1000;
}

/**
 * SVG arc gauge, animated via a spring-eased rAF loop rather than WPF
 * Storyboards - this is the fix for the old widget's "hovering a gauge
 * spikes CPU/GPU" bug: no per-frame layout/paint work beyond updating one
 * `stroke-dashoffset`, and the loop stops entirely once the value settles.
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
  const [display, setDisplay] = useState(percent ?? 0);
  const rafRef = useRef<number | null>(null);

  useEffect(() => {
    const target = percent ?? 0;
    const start = display;
    const durationMs = gaugeDurationMs();

    if (rafRef.current) cancelAnimationFrame(rafRef.current);

    if (durationMs <= 0) {
      // Reduced motion: jump straight to the settled value, no rAF loop.
      setDisplay(target);
      return;
    }

    const startTime = performance.now();

    function tick(now: number) {
      const t = Math.min(1, (now - startTime) / durationMs);
      const eased = 1 - Math.pow(1 - t, 3);
      setDisplay(start + (target - start) * eased);
      if (t < 1) {
        rafRef.current = requestAnimationFrame(tick);
      } else {
        rafRef.current = null;
      }
    }
    rafRef.current = requestAnimationFrame(tick);
    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [percent]);

  const radius = (size - 12) / 2;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference * (1 - display / 100);
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
              style={{ filter: `drop-shadow(0 0 6px ${color})` }}
            />
          )}
        </svg>
        <span className="devkit-gauge__center">
          <span className="devkit-gauge__value">{percent === null ? "n/a" : `${Math.round(percent)}%`}</span>
        </span>
      </span>
      <div className="devkit-gauge__label">{label}</div>
      {sub && <div className="devkit-gauge__sub">{sub}</div>}
      {history && (
        <span className="devkit-gauge__spark">
          <Sparkline
            values={history}
            capacity={historyCapacity}
            color={color}
            height={28}
            ariaLabel={`${label} recent history`}
          />
        </span>
      )}
    </button>
  );
}
