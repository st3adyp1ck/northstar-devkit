import { useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { PulseIcon } from "./icons";
import type { NodeSnapshot } from "../../../lib/types";
import "./NodePortsPanel.css";

/**
 * Node process + listening-port table for the widget. Backed by
 * metrics.node (Get-DevKitNodeSnapshot in gui/DevKit-WidgetCore.ps1),
 * polled every 3s. Self-contained: fetches its own data, handles its own
 * empty state, never crashes on a missing field.
 */
export function NodePortsPanel() {
  const { data, isLoading, refetch } = usePolledRpc<NodeSnapshot>("metrics.node", undefined, 3000);
  const processes = data?.Processes ?? [];
  const otherPorts = data?.OtherPorts ?? [];
  const reservedPorts = data?.ReservedPorts ?? [];
  const stillLoading = isLoading && !data;
  const [killError, setKillError] = useState<string | null>(null);
  const confirmDestructive = useConfirmDestructive();

  function kill(pid: number, name: string) {
    confirmDestructive(
      {
        title: "Kill process?",
        description: (
          <>
            Stop <strong>{name}</strong> (PID {pid})? This can't be undone.
          </>
        ),
        confirmLabel: "Kill",
        danger: true,
      },
      async () => {
        setKillError(null);
        try {
          await rpcCall("process.kill", { pid });
          refetch();
        } catch (err) {
          setKillError(err instanceof RpcClientError ? err.message : `Could not stop ${name} (pid ${pid}).`);
        }
      },
    );
  }

  return (
    <GlassPanel className="node-ports-panel">
      <div className="panel-header">
        <span className="panel-header__icon">
          <PulseIcon />
        </span>
        <h2 className="panel-header__title">Node & Ports</h2>
        <div className="panel-header__actions">
          <Badge tone={processes.length ? "accent" : "neutral"}>{processes.length} running</Badge>
        </div>
      </div>

      {killError && <div className="panel-empty panel-empty--danger">{killError}</div>}

      {stillLoading ? (
        <div className="node-ports-panel__skeleton">
          <div className="panel-skeleton-row" />
          <div className="panel-skeleton-row" />
        </div>
      ) : processes.length === 0 ? (
        <div className="panel-empty">No Node.js processes running.</div>
      ) : (
        <div className="node-ports-panel__list">
          {processes.map((p) => (
            <ProcessRow key={p.Pid} pid={p.Pid} name={p.Name} memoryMB={p.MemoryMB} ageMinutes={p.AgeMinutes} ports={p.Ports} onKill={kill} />
          ))}
        </div>
      )}

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

function ProcessRow({
  pid,
  name,
  memoryMB,
  ageMinutes,
  ports,
  onKill,
}: {
  pid: number;
  name: string;
  memoryMB: number;
  ageMinutes: number | null;
  ports: number[];
  onKill: (pid: number, name: string) => void;
}) {
  const meta = [`PID ${pid}`, `${memoryMB} MB`];
  const age = formatAge(ageMinutes);
  if (age) meta.push(age);

  return (
    <div className="node-ports-panel__row">
      <div className="node-ports-panel__row-main">
        <span className="node-ports-panel__name">{name}</span>
        <span className="node-ports-panel__meta">{meta.join(" · ")}</span>
      </div>
      <div className="node-ports-panel__row-side">
        <div className="node-ports-panel__ports">
          {ports.length === 0 ? (
            <span className="node-ports-panel__no-port">no port</span>
          ) : (
            ports.map((port) => <PortChip key={port} port={port} />)
          )}
        </div>
        <button
          type="button"
          className="node-ports-panel__kill"
          title={`Kill ${name} (${pid})`}
          onClick={() => onKill(pid, name)}
        >
          &#10005;
        </button>
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

/** Formats a minutes-ago duration like the old widget: "3m", "1h 12m". Null/undefined -> "" (nothing shown). */
function formatAge(minutes: number | null): string {
  if (minutes === null || minutes === undefined || Number.isNaN(minutes)) return "";
  if (minutes < 60) return `${minutes}m`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}
