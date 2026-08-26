import { useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { resolveTerminalTheme } from "../lib/terminalThemes";
import { useSettingsStore } from "../stores/useSettingsStore";
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

const XTERM_FONT_FAMILY = '"Cascadia Code", "Cascadia Mono", Consolas, monospace';

/**
 * One-shot session init, written into the pty right after spawn exactly as
 * if the user had typed it: defines a compact two-tone prompt (bold cyan
 * cwd with `~` for home + bright-blue U+276F chevron) using [char]27 ANSI
 * escapes, then clears the echoed line away with Clear-Host so the session
 * opens on a clean prompt. Deliberately requires nothing beyond stock
 * PowerShell: no oh-my-posh, no profile, no Nerd Font (the chevron is
 * plain unicode Cascadia/Consolas cover), pure-ASCII on the wire (the
 * glyph is built via [char]0x276F, so shell input encoding never matters),
 * and verified against both pwsh 7 and Windows PowerShell 5.1 (the two
 * shells terminal.rs's locate_shell can pick). A parse/runtime failure
 * here just prints an error and leaves the default prompt - it cannot take
 * the shell down. Ends with \r (Enter) so it executes immediately.
 */
const PROMPT_INIT =
  "function prompt { $e=[char]27; $p=\"$($executionContext.SessionState.Path.CurrentLocation)\"; " +
  "if ($HOME -and $p.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase)) { $p = '~' + $p.Substring($HOME.Length) }; " +
  "\"$e[1;36m$p$e[0m $e[94m$([char]0x276F)$e[0m \" }; Clear-Host\r";

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
 *
 * Colors come from settings.preferences.terminalTheme via
 * lib/terminalThemes.ts - applied at creation and live-updated through
 * xterm 5's reactive `terminal.options.theme` setter, so switching themes
 * in Settings restyles the running session without a respawn.
 */
export function TerminalView({ cwd, className }: TerminalViewProps) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const [status, setStatus] = useState<"connecting" | "ready" | "error">("connecting");
  const [error, setError] = useState<string | null>(null);

  const themeId = useSettingsStore((s) => s.settings?.preferences.terminalTheme);
  // Stable per id (record lookup, not a fresh object), so the effect below
  // only fires on real theme changes, not every settings re-render.
  const theme = resolveTerminalTheme(themeId);

  useEffect(() => {
    let disposed = false;
    let unlisten: UnlistenFn | null = null;
    let resizeObserver: ResizeObserver | null = null;
    let sessionId: string | null = null;

    const term = new Terminal({
      // Mount-once effect: read the store imperatively for the initial
      // theme (settings may even still be loading - falls back to
      // northstar); the theme effect below handles every later change.
      theme: resolveTerminalTheme(useSettingsStore.getState().settings?.preferences.terminalTheme),
      fontFamily: XTERM_FONT_FAMILY,
      fontSize: 13,
      lineHeight: 1.2,
      cursorBlink: true,
      scrollback: 5000,
    });
    termRef.current = term;
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);

    const host = hostRef.current;
    if (host) {
      term.open(host);
      fitAddon.fit();
    }

    // Coalesce resizes. A ConPTY resize makes the shell repaint the ENTIRE
    // screen, and resizes arrive in bursts: the flyout tray animates the OS
    // window's width in ~14 steps, each firing window.resize AND the host's
    // ResizeObserver. Measured: one flyout open produced 109 full-screen
    // repaints and pushed Tauri's IPC into its postMessage fallback
    // ("IPC custom protocol failed" from this function). Two guards:
    //   - trailing debounce, so a burst costs one resize instead of ~30
    //   - skip entirely when cols/rows are unchanged, which is the common
    //     case for a width animation whose steps are under one cell wide
    let resizeTimer: ReturnType<typeof setTimeout> | null = null;
    let sentCols = -1;
    let sentRows = -1;

    function pushResize(id: string) {
      if (resizeTimer) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        resizeTimer = null;
        fitAddon.fit();
        if (term.cols === sentCols && term.rows === sentRows) return;
        sentCols = term.cols;
        sentRows = term.rows;
        void invoke("terminal_resize", { sessionId: id, cols: term.cols, rows: term.rows }).catch(() => {});
      }, 90);
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
        // ConPTY queues input written before the shell's first read, so
        // sending immediately is safe - it executes at the first prompt.
        // Best-effort: a failed write just means the stock prompt.
        void invoke("terminal_write", { sessionId: id, data: PROMPT_INIT }).catch(() => {});
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
      if (resizeTimer) clearTimeout(resizeTimer);
      window.removeEventListener("resize", onWindowResize);
      resizeObserver?.disconnect();
      unlisten?.();
      if (sessionId) {
        void invoke("terminal_kill", { sessionId }).catch(() => {});
      }
      termRef.current = null;
      term.dispose();
    };
    // Mount-once by design (see docstring above) - cwd is only read at
    // the moment this effect spawns the session.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Live theme switch: xterm 5 options are reactive setters - assigning
  // repaints the open terminal, no recreate/respawn needed.
  useEffect(() => {
    const term = termRef.current;
    if (term) term.options.theme = theme;
  }, [theme]);

  return (
    // The wrapper (not the xterm mount node) carries the padding and the
    // theme background: FitAddon sizes cols/rows from the element xterm is
    // opened in, so that element must stay padding-free for the math to be
    // exact, while the wrapper painting the theme's own background makes
    // the padding read as terminal, not as a gap around it.
    <div className={clsx("terminal-view", className)} style={{ background: theme.background }}>
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
