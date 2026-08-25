import { useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { rpcCall, onToolRun } from "../../../lib/ipc";
import { useSettingsStore } from "../../../stores/useSettingsStore";
import { useProjectStore } from "../../../stores/useProjectStore";
import { useUpdaterStore } from "../../../stores/useUpdaterStore";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Button } from "../../../components/primitives/Button";
import { ToolConsole, type ToolConsoleLine } from "../../../components/ToolConsole";
import { BoltIcon } from "./icons";
import type { EnvDrift } from "../../../lib/types";
import "./QuickActionsPanel.css";

interface QuickAction {
  label: string;
  folder: string;
  script: string;
  args: string[];
  danger?: boolean;
  /** Shows an inline port-number input next to the button; the value is spliced in as `-Port <n>` ahead of `args`. */
  needsPort?: boolean;
  /** What the confirmDestructive prompt says this action does - only read when `danger` is set. */
  confirmDescription?: string;
}

const QUICK_ACTIONS: QuickAction[] = [
  { label: "Clear NPM Cache", folder: "node", script: "Clear-NpmCache.ps1", args: ["-Force"] },
  {
    label: "Kill All Node",
    folder: "ports",
    script: "Kill-AllNode.ps1",
    args: ["-Force"],
    danger: true,
    confirmDescription: "This stops every Node.js process currently running - any unsaved dev server state will be lost.",
  },
  { label: "Doctor", folder: "diagnostics", script: "DevKit-Doctor.ps1", args: [] },
  {
    label: "Kill Port",
    folder: "ports",
    script: "Kill-Port.ps1",
    args: ["-Force"],
    danger: true,
    needsPort: true,
    confirmDescription: "This stops whatever process is listening on port",
  },
];

/**
 * Quick Actions + Settings panel. Each action now streams its output into
 * an inline console (ToolConsole, shared with the Control Center's
 * ToolRunDialog) instead of firing and forgetting, and disables every
 * button while one is running - the sidecar runs one tool.run at a time
 * per runId but there's no reason to let two quick actions race visually.
 */
export function QuickActionsPanel() {
  const { settings, error: settingsError, refresh, update } = useSettingsStore();
  const active = useProjectStore((s) => s.active);
  const confirmDestructive = useConfirmDestructive();

  // Reads/drives the SAME store useUpdateCheck() (mounted once in
  // WidgetApp) writes to - this panel never calls useUpdateCheck itself,
  // so clicking "Check for Updates" here can't spin up a second
  // independent 24h-throttled auto-check alongside WidgetApp's. Aliased
  // away from `update`/`status`, which the settings-store destructure and
  // local run-state above already use for unrelated things.
  const updateStatus = useUpdaterStore((s) => s.status);
  const availableUpdate = useUpdaterStore((s) => s.update);
  const checkForUpdatesNow = useUpdaterStore((s) => s.checkNow);

  const [runningLabel, setRunningLabel] = useState<string | null>(null);
  const [lines, setLines] = useState<ToolConsoleLine[]>([]);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const [portValue, setPortValue] = useState("");
  const unlistenRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    refresh();
  }, [refresh]);

  // Unsubscribe from any in-flight run's events if the panel unmounts mid-run.
  useEffect(() => {
    return () => {
      unlistenRef.current?.();
    };
  }, []);

  const envDriftParams = active ? { path: active.path } : undefined;
  const { data: envDrift } = usePolledRpc<EnvDrift | null>("env.drift", envDriftParams, 15000, !!active);
  const silenced = settings?.preferences.envDriftSilencedProjects ?? [];
  const showDriftBanner = !!active && !!envDrift && envDrift.Missing.length > 0 && !silenced.includes(active.id);

  async function executeRun(action: QuickAction, args: string[]) {
    setLines([]);
    setExitCode(null);
    setRunningLabel(action.label);
    const runId = crypto.randomUUID();
    try {
      const unlisten = await onToolRun(runId, {
        onOutput: (stream, line) => setLines((prev) => [...prev, { stream, line }]),
        onFinished: (code) => {
          setExitCode(code);
          setRunningLabel(null);
          unlisten();
          unlistenRef.current = null;
        },
      });
      unlistenRef.current = unlisten;
      await rpcCall("tool.run", { folder: action.folder, script: action.script, args, runId });
    } catch (err) {
      setLines((prev) => [...prev, { stream: "stderr", line: String(err) }]);
      setExitCode(-1);
      setRunningLabel(null);
      unlistenRef.current?.();
      unlistenRef.current = null;
    }
  }

  function run(action: QuickAction) {
    if (runningLabel) return;
    let args = [...action.args];
    let port: number | null = null;
    if (action.needsPort) {
      port = Number(portValue);
      if (!Number.isInteger(port) || port < 1 || port > 65535) return;
      args = ["-Port", String(port), ...args];
    }

    // Only danger-flagged actions (Kill All Node, Kill Port) go through the
    // confirmDestructive gate - Doctor and Clear NPM Cache stay one-click
    // even when the setting is on, since neither is actually destructive.
    if (action.danger) {
      confirmDestructive(
        {
          title: `${action.label}?`,
          description: (
            <>
              {action.confirmDescription}
              {action.needsPort && (
                <>
                  {" "}
                  <strong>{port}</strong>.
                </>
              )}
            </>
          ),
          confirmLabel: action.label,
          danger: true,
        },
        () => executeRun(action, args),
      );
    } else {
      void executeRun(action, args);
    }
  }

  async function silenceDrift() {
    if (!active || silenced.includes(active.id)) return;
    await update({ envDriftSilencedProjects: [...silenced, active.id] });
  }

  /** Inline status next to the manual "Check for Updates" button - mirrors whatever WidgetApp's dialog is (or isn't) showing. */
  function updateStatusLabel(): string | null {
    switch (updateStatus) {
      case "checking":
        return "Checking…";
      case "up-to-date":
        return "Up to date";
      case "available":
        return availableUpdate ? `v${availableUpdate.version} available` : "Update available";
      case "downloading":
        return "Downloading…";
      case "installing":
        return "Installing…";
      case "error":
        return "Check failed";
      default:
        return null;
    }
  }
  const updateBusy = updateStatus === "checking" || updateStatus === "downloading" || updateStatus === "installing";
  const updateLabel = updateStatusLabel();

  return (
    <GlassPanel>
      <div className="panel-header">
        <span className="panel-header__icon">
          <BoltIcon />
        </span>
        <h2 className="panel-header__title">Quick Actions</h2>
      </div>

      {showDriftBanner && envDrift && (
        <div className="quick-actions-panel__drift">
          <span>
            {envDrift.Missing.length} key{envDrift.Missing.length === 1 ? "" : "s"} missing from {envDrift.EnvFile || ".env"} - based on{" "}
            {envDrift.Template}
          </span>
          <button type="button" className="quick-actions-panel__drift-dismiss" onClick={silenceDrift}>
            Dismiss
          </button>
        </div>
      )}

      <div className="quick-actions-panel__actions">
        {QUICK_ACTIONS.map((action) => {
          const isRunning = runningLabel === action.label;
          const disabled = !!runningLabel || (!!action.needsPort && portValue.trim() === "");
          return (
            <div key={action.label} className="quick-actions-panel__action">
              {action.needsPort && (
                <input
                  type="number"
                  min={1}
                  max={65535}
                  placeholder="port"
                  value={portValue}
                  onChange={(e) => setPortValue(e.target.value)}
                  disabled={!!runningLabel}
                  className="quick-actions-panel__port-input"
                  aria-label="Port number"
                />
              )}
              <Button size="sm" variant={action.danger ? "danger" : "subtle"} disabled={disabled} loading={isRunning} onClick={() => run(action)}>
                {action.label}
              </Button>
            </div>
          );
        })}
      </div>

      {(runningLabel || lines.length > 0) && (
        <div className="quick-actions-panel__console">
          <ToolConsole lines={lines} className="tool-console--compact" />
          {exitCode !== null && (
            <span className={exitCode === 0 ? "quick-actions-panel__exit-ok" : "quick-actions-panel__exit-err"}>exit {exitCode}</span>
          )}
        </div>
      )}

      {!settings && !settingsError && (
        <div className="panel-empty">Loading settings…</div>
      )}

      {!settings && settingsError && (
        <div className="panel-empty panel-empty--danger">{settingsError}</div>
      )}

      {settings && (
        <div className="quick-actions-panel__settings">
          {settingsError && <div className="quick-actions-panel__drift">{settingsError}</div>}
          <label className="quick-actions-panel__toggle">
            <input
              type="checkbox"
              checked={settings.preferences.enableAnimations}
              onChange={(e) => update({ enableAnimations: e.target.checked })}
            />
            Animations
          </label>
          <label className="quick-actions-panel__toggle">
            <input
              type="checkbox"
              checked={settings.preferences.confirmDestructive}
              onChange={(e) => update({ confirmDestructive: e.target.checked })}
            />
            Confirm destructive actions
          </label>
          <label className="quick-actions-panel__toggle">
            <input
              type="checkbox"
              checked={settings.preferences.updateCheckEnabled}
              onChange={(e) => update({ updateCheckEnabled: e.target.checked })}
            />
            Check for updates
          </label>

          <div className="quick-actions-panel__update-check">
            <Button size="sm" variant="subtle" disabled={updateBusy} loading={updateStatus === "checking"} onClick={() => void checkForUpdatesNow()}>
              Check for Updates
            </Button>
            {updateLabel && (
              <span
                className={clsx(
                  "quick-actions-panel__update-status",
                  updateStatus === "error" && "quick-actions-panel__update-status--error",
                  updateStatus === "available" && "quick-actions-panel__update-status--available",
                )}
              >
                {updateLabel}
              </span>
            )}
          </div>

          <div className="quick-actions-panel__dock">
            <span>Widget dock</span>
            <div className="quick-actions-panel__segmented">
              {(["Left", "Right"] as const).map((mode) => (
                <button
                  key={mode}
                  type="button"
                  className={clsx(
                    "quick-actions-panel__segment",
                    settings.preferences.widgetDockMode === mode && "quick-actions-panel__segment--active",
                  )}
                  onClick={() => update({ widgetDockMode: mode })}
                >
                  {mode}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {!active && (
        <div className="panel-empty" style={{ marginTop: "var(--space-1)" }}>
          Link a project to unlock per-project tools.
        </div>
      )}
    </GlassPanel>
  );
}
