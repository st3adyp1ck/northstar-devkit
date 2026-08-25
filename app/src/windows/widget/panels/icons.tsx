import type { SVGProps } from "react";

/**
 * Tiny monochrome line icons for widget panel headers - no icon library
 * dependency, just inline SVG matching Expander's existing chevron
 * aesthetic (currentColor stroke, rounded caps/joins). Purely
 * presentational: one glyph per panel so the stacked widget reads at a
 * glance, same spirit as Gauge's tone-colored arcs.
 */
type IconProps = SVGProps<SVGSVGElement>;

const base: IconProps = {
  width: 14,
  height: 14,
  viewBox: "0 0 16 16",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.4,
  strokeLinecap: "round",
  strokeLinejoin: "round",
};

/** Node & Ports - an activity/pulse line (running processes). */
export function PulseIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M1.5 8.5H5L6.5 3.5L9.5 12.5L11 8.5H14.5" />
    </svg>
  );
}

/** Git - branch/fork glyph. */
export function BranchIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <circle cx="4" cy="3.3" r="1.5" />
      <circle cx="4" cy="12.7" r="1.5" />
      <circle cx="12" cy="7.5" r="1.5" />
      <path d="M4 4.8V11.2" />
      <path d="M4 7.5C4 5.6 6.2 6 10.5 7.1" />
    </svg>
  );
}

/** MCP - stacked server rack. */
export function ServerIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <rect x="2" y="2.5" width="12" height="4" rx="1.1" />
      <rect x="2" y="9.5" width="12" height="4" rx="1.1" />
      <circle cx="4.6" cy="4.5" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="4.6" cy="11.5" r="0.6" fill="currentColor" stroke="none" />
    </svg>
  );
}

/** Files - folder outline. */
export function FolderIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M2 4.6C2 3.72 2.72 3 3.6 3H6.4L7.9 4.5H12.4C13.28 4.5 14 5.22 14 6.1V11.4C14 12.28 13.28 13 12.4 13H3.6C2.72 13 2 12.28 2 11.4V4.6Z" />
    </svg>
  );
}

/** Quick Actions - lightning bolt (filled, reads better solid at this size). */
export function BoltIcon(props: IconProps) {
  return (
    <svg width={14} height={14} viewBox="0 0 16 16" fill="currentColor" stroke="none" {...props}>
      <path d="M9.2 1.6 3.4 9.4H7.1L6.3 14.4L12.6 6.3H8.6L9.2 1.6Z" />
    </svg>
  );
}

/** Terminal - prompt chevron + cursor. */
export function TerminalIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <rect x="1.75" y="2.75" width="12.5" height="10.5" rx="1.6" />
      <path d="M4.6 6 7 8L4.6 10" />
      <path d="M8.2 10H11" />
    </svg>
  );
}
