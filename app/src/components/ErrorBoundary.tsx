import { Component, type ErrorInfo, type ReactNode } from "react";
import { Button } from "./primitives/Button";

interface ErrorBoundaryProps {
  children: ReactNode;
}

interface ErrorBoundaryState {
  error: Error | null;
  componentStack: string | null;
}

/**
 * Last-resort catch for render/lifecycle throws. Without this, any uncaught
 * render error unmounts the React root and the window goes permanently
 * blank (there is no navigation to recover through in a Tauri webview).
 * Wraps both window roots in main.tsx.
 */
export class ErrorBoundary extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null, componentStack: null };

  static getDerivedStateFromError(error: Error): Partial<ErrorBoundaryState> {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    this.setState({ error, componentStack: info.componentStack ?? null });
  }

  render() {
    const { error, componentStack } = this.state;
    if (!error) return this.props.children;

    return (
      <div
        style={{
          minHeight: "100vh",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: "16px",
          padding: "24px",
          background: "var(--surface-app)",
          color: "var(--text-primary)",
          textAlign: "center",
        }}
      >
        <h1 style={{ fontSize: "16px", fontWeight: 600, margin: 0 }}>Something went wrong.</h1>
        <pre
          style={{
            maxWidth: "100%",
            overflow: "auto",
            padding: "12px",
            borderRadius: "8px",
            background: "color-mix(in srgb, var(--ember-400) 8%, transparent)",
            color: "var(--ember-400)",
            fontFamily: "var(--font-mono)",
            fontSize: "12px",
            whiteSpace: "pre-wrap",
            textAlign: "left",
          }}
        >
          {error.message || String(error)}
        </pre>
        <Button variant="primary" size="sm" onClick={() => window.location.reload()}>
          Reload
        </Button>
        {componentStack && (
          <details style={{ maxWidth: "100%", textAlign: "left" }}>
            <summary style={{ cursor: "pointer", fontSize: "12px" }}>Component stack</summary>
            <pre
              style={{
                overflow: "auto",
                fontFamily: "var(--font-mono)",
                fontSize: "11px",
                whiteSpace: "pre-wrap",
              }}
            >
              {componentStack}
            </pre>
          </details>
        )}
      </div>
    );
  }
}
