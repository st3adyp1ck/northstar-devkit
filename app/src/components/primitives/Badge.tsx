import type { PropsWithChildren } from "react";
import clsx from "clsx";
import "./Badge.css";

interface BadgeProps extends PropsWithChildren {
  tone?: "neutral" | "accent" | "danger" | "success" | "warning";
  className?: string;
}

export function Badge({ children, tone = "neutral", className }: BadgeProps) {
  return <span className={clsx("devkit-badge", `devkit-badge--${tone}`, className)}>{children}</span>;
}
