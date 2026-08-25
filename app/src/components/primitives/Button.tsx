import type { ButtonHTMLAttributes } from "react";
import clsx from "clsx";
import "./Button.css";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "primary" | "ghost" | "danger" | "subtle";
  size?: "sm" | "md";
  /** Shows an inline spinner and forces disabled, so callers with a "running" concept don't have to hand-roll their own spinner or swap label text. */
  loading?: boolean;
}

export function Button({ variant = "subtle", size = "md", loading = false, disabled, className, children, ...rest }: ButtonProps) {
  return (
    <button
      className={clsx("devkit-btn", `devkit-btn--${variant}`, `devkit-btn--${size}`, loading && "devkit-btn--loading", className)}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...rest}
    >
      {loading && <span className="devkit-btn__spinner" aria-hidden="true" />}
      {children}
    </button>
  );
}
