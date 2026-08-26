import { useState } from "react";
import clsx from "clsx";
import { AnimatePresence, motion } from "framer-motion";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import { asArray } from "../../../lib/arrays";
import { Gauge } from "../../../components/Gauge";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Button } from "../../../components/primitives/Button";
import type {
  SystemMetrics,
  TopCpuProcessRow,
  TopMemoryResult,
  GpuProcessUsage,
} from "../../../lib/types";
import { EASE_STANDARD, motionDuration } from "./motion";
import "./GaugesPanel.css";

type GaugeKind = "cpu" | "mem" | "gpu" | null;

/**
 * Reference panel implementation - CPU/Mem/GPU/Disk gauges polled every 2s
 * (matching the old widget's cycle), with a click-through flyout listing
 * top processes and a guarded kill button. Every other widget panel should
 * follow this file's shape: self-contained, no required props, own polling
 * via usePolledRpc, own loading/error/n-a states.
 */
export function GaugesPanel() {
  const { data: metrics, isLoading } = usePolledRpc<SystemMetrics>("metrics.system", undefined, 2000);
  const [openGauge, setOpenGauge] = useState<GaugeKind>(null);

  const diskFree = metrics?.DiskFreeBytes ?? null;
  const diskTotal = metrics?.DiskTotalBytes ?? null;
  const diskPercent = diskFree !== null && diskTotal ? Math.round((1 - diskFree / diskTotal) * 100) : null;
  const stillLoading = isLoading && !metrics;

  return (
    <GlassPanel className="gauges-panel">
      <div className="panel-header panel-header--minimal">
        <h2 className="panel-header__title">System</h2>
        {stillLoading && <span className="panel-header__hint">reading sensors…</span>}
      </div>
      <div className={clsx("gauges-panel__row", stillLoading && "gauges-panel__row--loading")}>
        <Gauge
          label="CPU"
          percent={metrics?.CpuPercent ?? null}
          sub={metrics?.CpuTempC != null ? `${metrics.CpuTempC}°C` : "n/a"}
          tone="sapphire"
          onClick={() => setOpenGauge("cpu")}
        />
        <Gauge
          label="Memory"
          percent={metrics?.MemoryPercent ?? null}
          sub={metrics ? `${metrics.MemoryUsedGB}/${metrics.MemoryTotalGB} GB` : undefined}
          tone="cyan"
          onClick={() => setOpenGauge("mem")}
        />
        <Gauge
          label="GPU"
          percent={metrics?.GpuPercent ?? null}
          sub={metrics?.GpuTempC != null ? `${metrics.GpuTempC}°C` : "n/a"}
          tone="amber"
          onClick={() => setOpenGauge("gpu")}
        />
        <Gauge
          label="Disk Free"
          percent={diskPercent}
          sub={diskFree !== null ? `${(diskFree / 1e9).toFixed(0)} GB free` : undefined}
          tone="ember"
        />
      </div>
      {metrics?.RebootPending && (
        <div className="gauges-panel__hint">A restart is pending on this machine.</div>
      )}
      <AnimatePresence initial={false}>
        {openGauge && (
          <motion.div
            key={openGauge}
            className="gauges-panel__flyout-wrap"
            initial={{ opacity: 0, height: 0 }}
            animate={{ opacity: 1, height: "auto" }}
            exit={{ opacity: 0, height: 0 }}
            transition={{ duration: motionDuration("--duration-slow", 360), ease: EASE_STANDARD }}
          >
            <ProcessFlyout kind={openGauge} onClose={() => setOpenGauge(null)} />
          </motion.div>
        )}
      </AnimatePresence>
    </GlassPanel>
  );
}

/**
 * Common shape the three underlying RPCs get normalized into for
 * rendering. The three methods below don't share a response shape
 * (process.topMemory and metrics.gpuProcesses are wrapper objects with a
 * `.Processes` array plus extra summary fields, process.topCpu is a bare
 * array, and the "percent" field is named differently in each) - see
 * lib/types.ts's TopCpuProcessRow/TopMemoryResult/GpuProcessUsage comment
 * for the verified-live shapes this must not drift from again.
 */
interface FlyoutRow {
  Pid: number;
  Name: string;
  Classification: string;
  pctLabel: string;
}

function ProcessFlyout({ kind, onClose }: { kind: Exclude<GaugeKind, null>; onClose: () => void }) {
  const method = kind === "mem" ? "process.topMemory" : kind === "gpu" ? "metrics.gpuProcesses" : "process.topCpu";
  const { data, refetch } = usePolledRpc<TopCpuProcessRow[] | TopMemoryResult | GpuProcessUsage>(
    method,
    { count: 12 },
    3000,
  );
  const [actionError, setActionError] = useState<string | null>(null);
  const confirmDestructive = useConfirmDestructive();

  let rows: FlyoutRow[] = [];
  if (data) {
    if (kind === "mem") {
      rows = (data as TopMemoryResult).Processes.map((p) => ({
        Pid: p.Pid,
        Name: p.Name,
        Classification: p.Classification,
        pctLabel: `${p.MemoryMB} MB`,
      }));
    } else if (kind === "gpu") {
      rows = (data as GpuProcessUsage).Processes.map((p) => ({
        Pid: p.Pid,
        Name: p.Name,
        Classification: p.Classification,
        pctLabel: `${p.GpuPercent}%`,
      }));
    } else {
      // process.topCpu is a top-level array - normalize the PS single-element-unroll shape (see lib/arrays.ts).
      rows = asArray(data as TopCpuProcessRow[] | TopCpuProcessRow).map((p) => ({
        Pid: p.Pid,
        Name: p.Name,
        Classification: p.Classification,
        pctLabel: `${p.CpuPercent}%`,
      }));
    }
  }

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
        setActionError(null);
        try {
          await rpcCall("process.kill", { pid });
          refetch();
        } catch (err) {
          setActionError(err instanceof RpcClientError ? err.message : `Could not stop ${name} (pid ${pid}).`);
        }
      },
    );
  }

  async function freeMemory() {
    setActionError(null);
    try {
      await rpcCall("process.freeMemory");
      refetch();
    } catch (err) {
      setActionError(err instanceof RpcClientError ? err.message : "Could not free memory.");
    }
  }

  return (
    <div className="gauges-panel__flyout">
      <div className="gauges-panel__flyout-header">
        <span>{kind === "cpu" ? "Top CPU" : kind === "mem" ? "Top Memory" : "Top GPU"} Processes</span>
        <div className="gauges-panel__flyout-actions">
          {kind === "mem" && (
            <Button size="sm" variant="ghost" onClick={freeMemory}>
              Free Memory
            </Button>
          )}
          <Button size="sm" variant="ghost" onClick={onClose}>
            Close
          </Button>
        </div>
      </div>
      {actionError && <div className="gauges-panel__hint">{actionError}</div>}
      <div className="gauges-panel__flyout-list">
        {rows.map((row) => (
          <div key={row.Pid} className="gauges-panel__flyout-row">
            <span className="gauges-panel__flyout-name">{row.Name}</span>
            <span className="gauges-panel__flyout-pct">{row.pctLabel}</span>
            {row.Classification !== "System" && (
              <button
                type="button"
                className="gauges-panel__kill"
                title={`Kill ${row.Name} (${row.Pid})`}
                onClick={() => kill(row.Pid, row.Name)}
              >
                &#10005;
              </button>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
