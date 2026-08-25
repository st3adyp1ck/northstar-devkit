import { useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import "./TerminalView.css";

export interface TerminalViewProps {
  /**
   * Working directory for the spawned shell; omit to inherit the app
   * process's own cwd. Read once at mount time (see the mount-once note
   * below) - pass a new `key` from the parent to respawn against a
   * different cwd (e.g. the active project changed).
   */
  cwd?: string;
  className?: string;
}

interface TerminalEventPayload {
  sessionId: string;
  data: string;
}

/**
 * Hardcoded from app/src/styles/tokens.css - xterm.js needs a literal
 * theme object (its canvas/DOM renderers can't resolve CSS custom
 * properties), so these are copied by hand rather than referenced live.
 * Keep in sync if the token values change.
 */
const XTERM_THEME = {
  foreground: "#f2f5f9", // --text-primary
  background: "#0d1219", // --surface-sunken (--gm-950)
  cursor: "#4fa3ff", // --sapphire-500
  cursorAccent: "#061019", // --text-on-accent
  selectionBackground: "rgba(79, 163, 255, 0.25)", // --sapphire-500 @ 25%
  black: "#131a26", // --gm-900
  red: "#ef5350", // --signal-red
  green: "#98c379", // --signal-green
  yellow: "#ffb020", // --signal-amber
  blue: "#4fa3ff", // --sapphire-500
  magenta: "#c678dd", // --signal-violet
  cyan: "#56b6c2", // --signal-cyan
  white: "#aab4c4", // --text-secondary
  brightBlack: "#6b7a90", // --gm-400
  brightRed: "#ff6b3d", // --ember-500
  brightGreen: "#98c379", // --signal-green
  brightYellow: "#e5c07b", // --signal-sand
  brightBlue: "#79c0ff", // --sapphire-400
  brightMagenta: "#c678dd", // --signal-violet
  brightCyan: "#56b6c2", // --signal-cyan
  brightWhite: "#f2f5f9", // --text-primary
};

const XTERM_FONT_FAMILY = '"Cascadia Code", "Cascadia Mono", ui-monospace, Consolas, monospace';

/**
 * Reusable embedded terminal - a real ConPTY `pwsh` session owned by Rust
 * (src-tauri/src/terminal.rs), independent of the RPC sidecar. This is
 * the upgrade over the old WPF widget's TermHostSurface, which could only
 * launch an external Windows Terminal window; this one lives in-app.
 *
 * Spawns exactly one session on mount and kills it on unmount - it does
 * NOT react to `cwd` changing while mounted. Give it a fresh `key` from
 * the parent (e.g. a "Restart" button, or a project switch) to force a
 * clean respawn.
 */
export function TerminalView({ cwd, className }: TerminalViewProps) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const [status, setStatus] = useState<"connecting" | "ready" | "error">("connecting");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let disposed = false;
    let unlisten: UnlistenFn | null = null;
    let resizeObserver: ResizeObserver | null = null;
    let sessionId: string | null = null;

    const term = new Terminal({
      theme: XTERM_THEME,
      fontFamily: XTERM_FONT_FAMILY,
      fontSize: 13,
      lineHeight: 1.2,
      cursorBlink: true,
      scrollback: 5000,
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);

    const host = hostRef.current;
    if (host) {
      term.open(host);
      fitAddon.fit();
    }

    function pushResize(id: string) {
      fitAddon.fit();
      void invoke("terminal_resize", { sessionId: id, cols: term.cols, rows: term.rows }).catch(() => {});
    }

    void (async () => {
      try {
        const id = await invoke<string>("terminal_spawn", { cwd: cwd ?? null });
        if (disposed) {
          // Unmounted while the spawn was in flight - clean up the
          // session we just created rather than leaking it.
          void invoke("terminal_kill", { sessionId: id }).catch(() => {});
          return;
        }
        sessionId = id;

        unlisten = await listen<TerminalEventPayload>("devkit://terminal", (e) => {
          if (e.payload.sessionId === id) term.write(e.payload.data);
        });

        term.onData((data) => {
          void invoke("terminal_write", { sessionId: id, data }).catch(() => {});
        });

        pushResize(id);
        setStatus("ready");
      } catch (err) {
        if (!disposed) {
          setError(typeof err === "string" ? err : String(err));
          setStatus("error");
        }
      }
    })();

    if (host) {
      resizeObserver = new ResizeObserver(() => {
        if (sessionId) pushResize(sessionId);
        else fitAddon.fit();
      });
      resizeObserver.observe(host);
    }
    const onWindowResize = () => {
      if (sessionId) pushResize(sessionId);
    };
    window.addEventListener("resize", onWindowResize);

    return () => {
      disposed = true;
      window.removeEventListener("resize", onWindowResize);
      resizeObserver?.disconnect();
      unlisten?.();
      if (sessionId) {
        void invoke("terminal_kill", { sessionId }).catch(() => {});
      }
      term.dispose();
    };
    // Mount-once by design (see docstring above) - cwd is only read at
    // the moment this effect spawns the session.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className={clsx("terminal-view", className)}>
      <div ref={hostRef} className="terminal-view__host" />
      {status === "connecting" && <div className="terminal-view__status">Starting terminal…</div>}
      {status === "error" && (
        <div className="terminal-view__status terminal-view__status--error">
          Terminal failed to start{error ? `: ${error}` : "."}
        </div>
      )}
    </div>
  );
}
