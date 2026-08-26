import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ErrorBoundary } from "./components/ErrorBoundary";
import "./styles/global.css";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

const windowKind = new URLSearchParams(window.location.search).get("window") ?? "widget";

async function mount() {
  const root = createRoot(document.getElementById("root") as HTMLElement);

  if (windowKind === "control-center") {
    const { ControlCenterApp } = await import("./windows/control-center/ControlCenterApp");
    root.render(
      <StrictMode>
        <QueryClientProvider client={queryClient}>
          <ErrorBoundary>
            <ControlCenterApp />
          </ErrorBoundary>
        </QueryClientProvider>
      </StrictMode>,
    );
    return;
  }

  const { WidgetApp } = await import("./windows/widget/WidgetApp");
  root.render(
    <StrictMode>
      <QueryClientProvider client={queryClient}>
        <ErrorBoundary>
          <WidgetApp />
        </ErrorBoundary>
      </QueryClientProvider>
    </StrictMode>,
  );
}

mount();
