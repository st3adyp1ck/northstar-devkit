import { useId, useMemo, useState, type FormEvent } from "react";
import clsx from "clsx";
import { openUrl } from "@tauri-apps/plugin-opener";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import { asArray } from "../../../lib/arrays";
import { playSound } from "../../../lib/sounds";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { Button } from "../../../components/primitives/Button";
import { ToolConsole } from "../../../components/ToolConsole";
import { PulseIcon } from "./icons";
import { startWidgetToolRun, stopWatchingWidgetRun, useWidgetToolRun } from "./widgetToolRun";
import type { NodeProcessInfo, NodeSnapshot } from "../../../lib/types";
import "./NodePortsPanel.css";

/**
 * Node process + listening-port table for the widget. Backed by
 * metrics.node (Get-DevKitNodeSnapshot in core/DevKit-WidgetCore.ps1),
 * polled every 3s.
 *
 * Each row is a compact three-line summary that expands to the full facts,
 * because the honest answer to "is this safe to close?" needs the command
 * line and the idle derivation, and neither fits in a 380px sidebar.
 * Exactly VISIBLE_ROWS rows are shown; the rest scroll inside the panel so
 * the panel's own height never depends on how many node processes are
 * running.
 */

/** Rows visible before the list scrolls. The matching pixel budget lives in
 *  NodePortsPanel.css as --node-row-h / --node-row-gap - keep them in sync. */
const VISIBLE_ROWS = 5;

/*
 * The three machine-wide node/port tools, moved here out of Quick Actions:
 * a control that ends a process or frees a port belongs beside the list of
 * processes and ports, not in a generic button bar two panels away.
 *
 * Kill-AllNode and Kill-Port carry a literal -Force because both genuinely
 * declare that switch (verified against their param blocks) and they are
 * always reached through the confirm gate below. Clear-NpmCache does NOT:
 * it declares only -Path and -Verify, and passing -Force to a script that
 * does not declare it is a hard parameter-binding error under `pwsh -File`
 * - which is exactly how this button used to fail every single time it was
 * pressed, with "A parameter cannot be found that matches parameter name
 * 'Force'". It is also not destructive and has no prompt to bypass.
 */
const KILL_ALL_NODE = { label: "Kill All Node", folder: "ports", script: "Kill-AllNode.ps1", args: ["-Force"] };
const KILL_PORT = { label: "Kill Port", folder: "ports", script: "Kill-Port.ps1", args: ["-Force"] };
const CLEAR_CACHE = { label: "Clear NPM Cache", folder: "node", script: "Clear-NpmCache.ps1", args: [] as string[] };

export function NodePortsPanel() {
  const { data, refetch, pending, failed, stale, errorMessage } = usePolledRpc<NodeSnapshot>("metrics.node", undefined, 3000);
  const processes = useMemo(() => sortForDisplay(asArray(data?.Processes)), [data]);
  const otherPorts = asArray(data?.OtherPorts);
  const reservedPorts = asArray(data?.ReservedPorts);
  const staleCount = processes.filter((p) => p.IsStale).length;
  const [killError, setKillError] = useState<string | null>(null);
  const [retrying, setRetrying] = useState(false);
  const confirmDestructive = useConfirmDestructive();

  // The widget's single tool-run channel, shared with Quick Actions - the
  // sidecar has exactly one `tool` lane, so a run started anywhere in the
  // widget really does hold these buttons shut. See ./widgetToolRun.
  const toolRun = useWidgetToolRun();
  const { runId, label: runningLabel, surface, lines, exitCode, degraded, launchError } = toolRun;
  /** This panel's own transcript - a Quick Actions run belongs on that panel. */
  const mine = surface === "node-ports";
  const blockedBy = runningLabel && !mine ? runningLabel : null;

  // View state, fine to lose on unmount - unlike the run itself.
  const [portValue, setPortValue] = useState("");
  const portNumber = Number(portValue);
  const portValid = Number.isInteger(portNumber) && portNumber >= 1 && portNumber <= 65535;

  // A frozen last-known snapshot must not be allowed to disable the button:
  // "0 running" from a poll that failed is not evidence there is nothing to
  // kill, which is the whole reason usePolledRpc separates `stale` out.
  const nodeCountIsLive = data !== undefined && !stale;

  function runTool(spec: { label: string; folder: string; script: string; args: string[] }, caution = false) {
    if (runId) return;
    void startWidgetToolRun({ surface: "node-ports", ...spec, caution });
  }

  function killAllNode() {
    if (runId) return;
    confirmDestructive(
      {
        title: "Kill every Node process?",
        description: (
          <>
            This stops <strong>every Node.js process on the machine</strong>
            {processes.length > 0 ? ` (${processes.length} right now)` : ""} in one go, including the ones DevKit has
            NOT flagged as safe to close. Any unsaved dev server state is lost.
            <br />
            To end just one - with DevKit&apos;s read on whether that one is safe - cancel and use the &#10005; on its row.
          </>
        ),
        confirmLabel: "Kill all",
        danger: true,
      },
      () => runTool(KILL_ALL_NODE, true),
    );
  }

  function killPort(e: FormEvent) {
    e.preventDefault();
    if (runId || !portValid) return;
    confirmDestructive(
      {
        title: "Kill port?",
        description: (
          <>
            This stops whatever process is listening on port <strong>{portNumber}</strong> - node or not, and whether or
            not it appears in the list above.
          </>
        ),
        confirmLabel: "Kill port",
        danger: true,
      },
      () => runTool({ ...KILL_PORT, args: ["-Port", String(portNumber), ...KILL_PORT.args] }, true),
    );
  }

  function kill(proc: NodeProcessInfo) {
    confirmDestructive(
      {
        title: proc.IsStale ? "Close this idle process?" : "Kill process?",
        description: (
          <>
            Stop <strong>{proc.Name}</strong> (PID {proc.Pid})
            {proc.CommandLine ? (
              <>
                {" "}
                &mdash; <code>{shortenCommandLine(proc.CommandLine)}</code>
              </>
            ) : null}
            ?<br />
            {proc.IsStale && proc.StaleReason
              ? `DevKit thinks this one is safe to close: ${proc.StaleReason}.`
              : describeRisk(proc)}
          </>
        ),
        confirmLabel: proc.IsStale ? "Close it" : "Kill",
        danger: true,
      },
      async () => {
        setKillError(null);
        try {
          await rpcCall("process.kill", { pid: proc.Pid });
          refetch();
        } catch (err) {
          setKillError(err instanceof RpcClientError ? err.message : `Could not stop ${proc.Name} (pid ${proc.Pid}).`);
        }
      },
    );
  }

  async function retry() {
    setRetrying(true);
    try {
      await refetch();
    } finally {
      setRetrying(false);
    }
  }

  // Nothing ever arrived and the last attempt failed. The old panel rendered
  // "0 running / No Node.js processes running." here, which describes a
  // perfectly idle machine - the one reading a user is most likely to trust
  // and act on, and the one that is flatly untrue when the sidecar is down.
  if (failed) {
    return (
      <GlassPanel className="node-ports-panel">
        <div className="panel-header">
          <span className="panel-header__icon">
            <PulseIcon />
          </span>
          <h2 className="panel-header__title">Node &amp; Ports</h2>
        </div>
        <div className="node-ports-panel__offline">
          <div className="node-ports-panel__offline-title">
            Can&apos;t read the process list &mdash; the DevKit sidecar isn&apos;t answering.
          </div>
          {errorMessage && <div className="node-ports-panel__offline-detail">{errorMessage}</div>}
          <div>
            <Button size="sm" variant="ghost" loading={retrying} onClick={() => void retry()}>
              Retry
            </Button>
          </div>
        </div>
      </GlassPanel>
    );
  }

  return (
    <GlassPanel className="node-ports-panel">
      <div className="panel-header">
        <span className="panel-header__icon">
          <PulseIcon />
        </span>
        <h2 className="panel-header__title">Node &amp; Ports</h2>
        <div className="panel-header__actions">
          {staleCount > 0 && <Badge tone="warning">{staleCount} stale</Badge>}
          <Badge tone={processes.length ? "accent" : "neutral"}>{processes.length} running</Badge>
        </div>
      </div>

      {/* Data is on screen but the newest poll failed: say so rather than
          letting a frozen list read as a quiet machine. */}
      {stale && <div className="node-ports-panel__stale-note">last known &mdash; sidecar not answering</div>}
      {killError && <div className="panel-empty panel-empty--danger">{killError}</div>}

      {pending ? (
        <div className="node-ports-panel__skeleton">
          <div className="panel-skeleton-row" />
          <div className="panel-skeleton-row" />
        </div>
      ) : processes.length === 0 ? (
        <div className="panel-empty">No Node.js processes running.</div>
      ) : (
        <>
          <div className="node-ports-panel__list">
            {processes.map((p) => (
              <ProcessRow key={p.Pid} proc={p} onKill={kill} />
            ))}
          </div>
          {processes.length > VISIBLE_ROWS && (
            <div className="node-ports-panel__more">
              Showing {VISIBLE_ROWS} of {processes.length} &mdash; scroll the list for the rest
            </div>
          )}
        </>
      )}

      {/* The controls that used to sit in Quick Actions, now beside the data
          they act on. Kept out of an Expander on purpose: this is the panel's
          control surface, and hiding a panel's own controls behind a
          disclosure would undo the move. Placed BELOW the list so the
          five-rows-then-scroll window still owns the top of the panel. */}
      <div className="node-ports-panel__actions">
        <div className="node-ports-panel__actions-header">Machine-wide actions</div>

        <div className="node-ports-panel__actions-row">
          <Button
            size="sm"
            variant="danger"
            className="node-ports-panel__action-btn"
            disabled={!!runId || (nodeCountIsLive && processes.length === 0)}
            loading={mine && runningLabel === KILL_ALL_NODE.label}
            onClick={killAllNode}
          >
            Kill all node{nodeCountIsLive && processes.length > 0 ? ` (${processes.length})` : ""}
          </Button>
          <Button
            size="sm"
            variant="subtle"
            className="node-ports-panel__action-btn"
            disabled={!!runId}
            loading={mine && runningLabel === CLEAR_CACHE.label}
            onClick={() => runTool(CLEAR_CACHE)}
            title="Cleans the detected package manager's cache (npm/yarn/pnpm/bun). Touches no process and no port."
          >
            Clear package cache
          </Button>
        </div>

        {/* A form, so Enter in the port field fires the same guarded path the
            button does rather than doing nothing. */}
        <form className="node-ports-panel__port-row" onSubmit={killPort}>
          <input
            type="number"
            min={1}
            max={65535}
            placeholder="port"
            value={portValue}
            onChange={(e) => setPortValue(e.target.value)}
            disabled={!!runId}
            className="node-ports-panel__port-input"
            aria-label="Port number to free"
          />
          <Button
            type="submit"
            size="sm"
            variant="danger"
            className="node-ports-panel__action-btn"
            disabled={!!runId || !portValid}
            loading={mine && runningLabel === KILL_PORT.label}
          >
            Kill port
          </Button>
        </form>

        {/* Two kill affordances on one panel need to differ out loud, or the
            per-row X reads as a duplicate of the button above it. */}
        <p className="node-ports-panel__actions-note">
          The <span aria-hidden="true">&#10005;</span> on a row ends that one process, after telling you whether that
          one looks safe. Kill all node ends every one of them at once, with no such read.
        </p>

        {blockedBy && <div className="node-ports-panel__blocked">Waiting for {blockedBy} to finish.</div>}

        {/* tool.run was rejected before the sidecar emitted a single event, so
            nothing was ever started - stated, rather than left as a button
            that spins forever waiting for a tool.finished that isn't coming. */}
        {mine && launchError && <div className="node-ports-panel__launch-error">{launchError}</div>}

        {mine && (runId || lines.length > 0) && (
          <div className="node-ports-panel__console">
            <ToolConsole lines={lines} className="tool-console--compact" />
            {degraded && (
              <span className="node-ports-panel__degraded">
                Run request errored - still watching. DevKit can&apos;t cancel a running tool.
              </span>
            )}
            <div className="node-ports-panel__console-footer">
              {exitCode !== null && !runId && (
                <span className={exitCode === 0 ? "node-ports-panel__exit-ok" : "node-ports-panel__exit-err"}>
                  exit {exitCode}
                </span>
              )}
              {runId && (
                <Button size="sm" variant="ghost" onClick={stopWatchingWidgetRun}>
                  Stop watching
                </Button>
              )}
            </div>
          </div>
        )}
      </div>

      {reservedPorts.length > 0 && (
        <div
          className="node-ports-panel__reserved"
          title="These common dev ports are reserved by Windows (Hyper-V/winnat dynamic port exclusions) and will refuse to bind even though nothing is currently listening on them."
        >
          <Badge tone="warning">Reserved</Badge>
          <span className="node-ports-panel__reserved-list">{reservedPorts.join(", ")}</span>
        </div>
      )}

      {otherPorts.length > 0 && (
        <div className="node-ports-panel__other">
          <div className="node-ports-panel__other-header">Other dev ports</div>
          {otherPorts.map((o) => (
            <div key={o.Port} className="node-ports-panel__other-row">
              <PortChip port={o.Port} muted />
              <span className="node-ports-panel__other-name">{o.ProcessName || "unknown"}</span>
              <span className="node-ports-panel__other-pid">PID {o.Pid}</span>
            </div>
          ))}
        </div>
      )}
    </GlassPanel>
  );
}

function ProcessRow({ proc, onKill }: { proc: NodeProcessInfo; onKill: (proc: NodeProcessInfo) => void }) {
  const [open, setOpen] = useState(false);
  const detailsId = useId();
  const ports = asArray(proc.Ports);
  const summary = shortenCommandLine(proc.CommandLine);
  const idle = describeIdle(proc.IdleMinutes);

  const meta = [`PID ${proc.Pid}`, `${proc.MemoryMB} MB`];
  const age = formatAge(proc.AgeMinutes);
  if (age) meta.push(`up ${age}`);
  meta.push(idle.short);

  function toggle() {
    playSound("click");
    setOpen((v) => !v);
  }

  return (
    <div className={clsx("node-row", proc.IsStale && "node-row--stale")}>
      {/* The disclosure button is the accessible control; clicking anywhere
          else in the summary is a convenience shortcut for the same thing,
          skipped when the click landed on one of the row's own buttons. */}
      <div
        className="node-row__summary"
        onClick={(e) => {
          if ((e.target as HTMLElement).closest("button")) return;
          toggle();
        }}
      >
        <div className="node-row__head">
          <button
            type="button"
            className="node-row__disclose"
            aria-expanded={open}
            aria-controls={detailsId}
            title={open ? "Hide details" : "Show details"}
            onClick={toggle}
          >
            <svg
              className={clsx("node-row__chevron", open && "node-row__chevron--open")}
              width="10"
              height="10"
              viewBox="0 0 10 10"
              aria-hidden="true"
            >
              <path d="M3 1 L7 5 L3 9" stroke="currentColor" strokeWidth="1.5" fill="none" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </button>
          <span className="node-row__name">{proc.Name}</span>
          <div className="node-row__ports">
            {ports.length === 0 ? (
              <span className="node-row__no-port">no port</span>
            ) : (
              ports.map((port) => <PortChip key={port} port={port} />)
            )}
          </div>
          {proc.IsStale && (
            <span className="node-row__stale-pill" title={proc.StaleReason ?? "Idle long enough to look abandoned."}>
              stale
            </span>
          )}
          <button
            type="button"
            className={clsx("node-row__kill", proc.IsStale && "node-row__kill--safe")}
            title={
              proc.IsStale && proc.StaleReason
                ? `Close ${proc.Name} (${proc.Pid}) - ${proc.StaleReason}`
                : `Kill ${proc.Name} (${proc.Pid})`
            }
            onClick={() => onKill(proc)}
          >
            &#10005;
          </button>
        </div>
        <div className="node-row__meta">{meta.join(" \u00b7 ")}</div>
        <div className="node-row__cmd" title={proc.CommandLine ?? undefined}>
          {summary || "command line unavailable"}
        </div>
      </div>

      <div id={detailsId} className={clsx("node-row__details", open && "node-row__details--open")}>
        <div className="node-row__details-inner">
          <dl className="node-row__facts">
            <dt>Command</dt>
            <dd className="node-row__cmd-full">
              {proc.CommandLine ?? "unavailable \u2014 Windows would not let DevKit read it"}
            </dd>
            <dt>Ports</dt>
            <dd>
              {ports.length === 0 ? (
                <span className="node-row__dim">nothing listening</span>
              ) : (
                <div className="node-row__ports node-row__ports--wrap">
                  {ports.map((port) => (
                    <PortChip key={port} port={port} />
                  ))}
                </div>
              )}
            </dd>
            <dt>CPU</dt>
            <dd>
              {proc.CpuPercent == null ? <span className="node-row__dim">measuring&hellip;</span> : `${proc.CpuPercent}% now`}
              {" \u00b7 "}
              {proc.CpuSeconds}s total
            </dd>
            <dt>Started</dt>
            <dd>{age ? `${age} ago` : <span className="node-row__dim">unknown</span>}</dd>
            <dt>Last active</dt>
            <dd>{idle.long}</dd>
          </dl>

          {proc.IsStale ? (
            <div className="node-row__verdict">
              <div className="node-row__verdict-text">
                Looks safe to close: {proc.StaleReason}.
              </div>
              <Button size="sm" variant="danger" onClick={() => onKill(proc)}>
                Close it
              </Button>
            </div>
          ) : (
            <div className="node-row__verdict node-row__verdict--caution">
              <div className="node-row__verdict-text">{describeRisk(proc)}</div>
              <Button size="sm" variant="ghost" onClick={() => onKill(proc)}>
                Kill anyway
              </Button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function PortChip({ port, muted }: { port: number; muted?: boolean }) {
  return (
    <button
      type="button"
      className={muted ? "node-ports-panel__chip node-ports-panel__chip--muted" : "node-ports-panel__chip"}
      title={`Open http://localhost:${port}`}
      onClick={() => {
        // best-effort - no in-app fallback if the OS can't hand off to a browser (matches GitHubPanel's openItem)
        openUrl(`http://localhost:${port}`).catch(() => {});
      }}
    >
      {port}
    </button>
  );
}

/**
 * Stale rows first, then heaviest first. The five-row window is the whole
 * point of this panel, and a process the user could safely reclaim memory
 * from is exactly the one that must not be hidden below the fold - a stale
 * process is by definition small-ish and old, so plain memory order buries
 * it. Ties fall back to the backend's own memory-descending order.
 */
function sortForDisplay(rows: NodeProcessInfo[]): NodeProcessInfo[] {
  return [...rows].sort((a, b) => Number(b.IsStale) - Number(a.IsStale) || b.MemoryMB - a.MemoryMB);
}

/**
 * The leading `"C:\Program Files\nodejs\node.exe"` is identical on every row
 * and the script path that follows is usually an absolute path deep inside
 * node_modules, so a raw command line in a 380px sidebar ellipsizes away
 * precisely the part that distinguishes two `node` processes. This keeps the
 * argv tail and trims the script path to its last two segments -
 * "vite/bin/vite.js --host". The untouched line is still in the tooltip and
 * the expanded details.
 */
function shortenCommandLine(cmd: string | null): string {
  if (!cmd) return "";
  const trimmed = cmd.trim();
  if (!trimmed) return "";
  const rest = stripLeadingExecutable(trimmed);
  if (!rest) return compactPathToken(trimmed);
  const space = rest.indexOf(" ");
  if (space === -1) return compactPathToken(rest);
  return `${compactPathToken(rest.slice(0, space))} ${rest.slice(space + 1)}`;
}

/** Drops the (possibly quoted, possibly space-containing) executable token. */
function stripLeadingExecutable(cmd: string): string {
  if (cmd.startsWith('"')) {
    const close = cmd.indexOf('"', 1);
    return close === -1 ? "" : cmd.slice(close + 1).trim();
  }
  const space = cmd.indexOf(" ");
  return space === -1 ? "" : cmd.slice(space + 1).trim();
}

/** "D:\p\node_modules\vite\bin\vite.js" -> "vite/bin/vite.js"; leaves flags alone. */
function compactPathToken(token: string): string {
  const bare = token.replace(/"/g, "");
  if (!/[\\/]/.test(bare)) return bare;
  const parts = bare.split(/[\\/]/).filter((p) => p && p !== ".");
  if (parts.length <= 2) return parts.join("/");
  return parts.slice(-2).join("/");
}

/**
 * IdleMinutes is a lower bound the sidecar derives across polls, never a
 * reading, so the wording has to stay a lower bound too. null means the
 * tracker has not seen this pid twice yet; 0 means there is no evidence of
 * idleness (CPU just moved, or we have watched it for under a minute).
 */
function describeIdle(minutes: number | null): { short: string; long: string } {
  if (minutes === null || minutes === undefined || Number.isNaN(minutes)) {
    return { short: "idle n/a", long: "not measured yet - DevKit needs two polls to tell" };
  }
  if (minutes <= 0) return { short: "active", long: "active - CPU moved on the last poll" };
  const span = formatAge(minutes);
  return { short: `idle ${span}`, long: `no measurable CPU in the last ${span}` };
}

/** The cautious half of the kill affordance: why this row is NOT flagged safe. */
function describeRisk(proc: NodeProcessInfo): string {
  const ports = asArray(proc.Ports);
  if (ports.length > 0) {
    return `Still listening on ${ports.length > 1 ? "ports" : "port"} ${ports.join(", ")} - something may be connected to it.`;
  }
  if (proc.IdleMinutes === null) return "DevKit hasn't watched this one long enough to judge.";
  if (proc.IdleMinutes <= 0) return "This process used CPU on the last poll - it's doing something right now.";
  return `Idle ${formatAge(proc.IdleMinutes)}, but not long enough (or not identifiable enough) to call it abandoned.`;
}

/** Formats a minutes-ago duration like the old widget: "3m", "1h 12m". Null/undefined -> "" (nothing shown). */
function formatAge(minutes: number | null): string {
  if (minutes === null || minutes === undefined || Number.isNaN(minutes)) return "";
  if (minutes < 60) return `${minutes}m`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}
