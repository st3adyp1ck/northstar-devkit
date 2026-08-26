import { StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { CommandPalette } from "./components/palette/CommandPalette";
import { initUiSounds } from "./lib/sounds";
import { initErrorCapture } from "./lib/errorCapture";
import "./styles/global.css";

// Dev-only: the webview half of the MCP bridge (see attach_mcp_bridge in
// src-tauri/src/lib.rs). Without these listeners every agent-facing tool that
// round-trips through JS - execute_js, query_page, click, type_text - just
// times out against a running dev session. import.meta.env.DEV is statically
// false in a production build, so Vite drops this branch and the dependency
// never reaches the shipped bundle.
//
// Deliberately NOT tied to the Rust `mcp` feature: there is no reliable way to
// read a Cargo feature from the webview, and it does not matter. All this does
// is subscribe to events that only the plugin ever emits, so under a plain
// `pnpm tauri dev` (feature off) it registers a handful of listeners that
// never fire. Nothing here invokes an mcp.* command, so a missing Rust half
// cannot produce failed invokes.
if (import.meta.env.DEV) {
  void import("tauri-plugin-mcp")
    .then(({ setupPluginListeners }) => setupPluginListeners())
    .catch((err) => console.warn("MCP bridge listeners unavailable:", err));
}

initUiSounds();

// Start capturing frontend faults (uncaught errors, unhandled rejections)
// into the Error Center's store BEFORE anything renders, so a crash during
// the very first mount is still recorded rather than lost. Idempotent.
initErrorCapture();

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

const windowKind = new URLSearchParams(window.location.search).get("window") ?? "widget";

/**
 * Shared shell for both windows. <CommandPalette/> is mounted here rather
 * than inside either App root for two reasons: every window gets Ctrl+K for
 * free, and the palette sits OUTSIDE the ErrorBoundary, so it stays usable
 * (to reach the other window, switch projects, etc.) even if the window's
 * own tree has crashed. It's inside the QueryClientProvider so its catalog
 * fetch shares the Control Center's ["catalog.get"] cache entry.
 */
function Shell({ children }: { children: ReactNode }) {
  return (
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <ErrorBoundary>{children}</ErrorBoundary>
        <CommandPalette />
      </QueryClientProvider>
    </StrictMode>
  );
}

async function mount() {
  const root = createRoot(document.getElementById("root") as HTMLElement);

  if (windowKind === "control-center") {
    const { ControlCenterApp } = await import("./windows/control-center/ControlCenterApp");
    root.render(
      <Shell>
        <ControlCenterApp />
      </Shell>,
    );
    return;
  }

  const { WidgetApp } = await import("./windows/widget/WidgetApp");
  root.render(
    <Shell>
      <WidgetApp />
    </Shell>,
  );
}

mount();
