import { useState } from "react";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Button } from "../../../components/primitives/Button";
import { TerminalView } from "../../../components/TerminalView";
import { useProjectStore } from "../../../stores/useProjectStore";
import { TerminalIcon } from "./icons";
import "./TerminalPanel.css";

/**
 * Thin GlassPanel wrapper around TerminalView for the widget - a real
 * ConPTY `pwsh` session (src-tauri/src/terminal.rs), scoped to the active
 * project's folder when one is linked. This is the in-app replacement for
 * the old WPF widget's "launch an external Windows Terminal window"
 * flyout. Wired into WidgetApp.tsx inside a collapsed-by-default Expander
 * (a full ConPTY session in an always-on widget shouldn't claim vertical
 * space until asked for).
 */
export function TerminalPanel() {
  const active = useProjectStore((s) => s.active);
  const [restartNonce, setRestartNonce] = useState(0);

  // `key` forces a full unmount/remount, which gives us a clean
  // terminal_kill + terminal_spawn pair without TerminalView needing its
  // own imperative restart API. Keying off active?.path too means
  // switching projects respawns the session in the new directory instead
  // of leaving a stale cwd running (TerminalView only reads cwd at mount).
  const sessionKey = `${active?.path ?? "none"}:${restartNonce}`;

  return (
    <GlassPanel className="terminal-panel" padded={false}>
      <div className="panel-header terminal-panel__header">
        <span className="panel-header__icon">
          <TerminalIcon />
        </span>
        <h2 className="panel-header__title">Terminal</h2>
        <div className="panel-header__actions">
          <Button size="sm" variant="ghost" onClick={() => setRestartNonce((n) => n + 1)} title="Kill and restart the session">
            Restart
          </Button>
        </div>
      </div>
      <div className="terminal-panel__body">
        {/* A Missing project's folder no longer exists - spawning ConPTY there fails, so fall back to the default dir. */}
        <TerminalView key={sessionKey} cwd={active?.Missing ? undefined : active?.path} />
      </div>
    </GlassPanel>
  );
}
