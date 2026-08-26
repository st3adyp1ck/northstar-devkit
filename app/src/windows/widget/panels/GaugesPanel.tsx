import { useEffect, useMemo, useRef, useState } from "react";
import clsx from "clsx";
import { AnimatePresence, motion } from "framer-motion";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import { asArray } from "../../../lib/arrays";
import { Gauge } from "../../../components/Gauge";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Button } from "../../../components/primitives/Button";
import { Badge } from "../../../components/primitives/Badge";
import type {
  SystemMetrics,
  TopCpuProcessRow,
  TopMemoryResult,
  GpuProcessUsage,
  FreeMemoryResult,
  DriveInfo,
} from "../../../lib/types";
import { EASE_STANDARD, motionDuration } from "./motion";
import "./GaugesPanel.css";

type GaugeKind = "cpu" | "mem" | "gpu" | "disk" | null;

/** 30 samples x the 2s poll below = roughly the last minute of readings. */
const HISTORY_CAPACITY = 30;

/** One poll's worth of the three metrics that move fast enough to trend. */
interface MetricSample {
  cpu: number | null;
  mem: number | null;
  gpu: number | null;
}

/**
 * Reference panel implementation - CPU/Mem/GPU/Disk gauges polled every 2s
 * (matching the old widget's cycle), with a click-through flyout listing
 * top processes and a guarded kill button. Every other widget panel should
 * follow this file's shape: self-contained, no required props, own polling
 * via usePolledRpc, own loading/error/n-a states.
 *
 * Note the three states it distinguishes, because they used to collapse
 * into one lie: `pending` is "no readings YET", `failed` is "we asked and
 * couldn't get an answer" (previously rendered as four innocent "n/a"
 * gauges - a dead sidecar looked exactly like a machine with no sensors),
 * and `stale` is "these numbers are real but no longer live".
 */
export function GaugesPanel() {
  const {
    data: metrics,
    dataUpdatedAt,
    pending,
    failed,
    stale,
    errorMessage,
    refetch,
  } = usePolledRpc<SystemMetrics>("metrics.system", undefined, 2000);
  const [openGauge, setOpenGauge] = useState<GaugeKind>(null);
  const [history, setHistory] = useState<MetricSample[]>([]);
  const [retrying, setRetrying] = useState(false);
  const lastSampleAt = useRef(0);

  // One entry per SUCCESSFUL poll, keyed off dataUpdatedAt rather than the
  // `metrics` object: react-query's structural sharing hands back the very
  // same reference when a reading is deeply unchanged, so watching the
  // object would silently drop every flat stretch and distort the trace.
  // A failed poll appends nothing at all - the line stops growing instead
  // of inventing a zero.
  useEffect(() => {
    if (!metrics || !dataUpdatedAt || dataUpdatedAt === lastSampleAt.current) return;
    lastSampleAt.current = dataUpdatedAt;
    setHistory((prev) => {
      const next = prev.concat({
        cpu: metrics.CpuPercent ?? null,
        mem: metrics.MemoryPercent ?? null,
        gpu: metrics.GpuPercent ?? null,
      });
      return next.length > HISTORY_CAPACITY ? next.slice(next.length - HISTORY_CAPACITY) : next;
    });
  }, [metrics, dataUpdatedAt]);

  const cpuHistory = useMemo(() => history.map((s) => s.cpu), [history]);
  const memHistory = useMemo(() => history.map((s) => s.mem), [history]);
  const gpuHistory = useMemo(() => history.map((s) => s.gpu), [history]);

  const diskFree = metrics?.DiskFreeBytes ?? null;
  const diskTotal = metrics?.DiskTotalBytes ?? null;
  const diskPercent = diskFree !== null && diskTotal ? Math.round((1 - diskFree / diskTotal) * 100) : null;

  async function retry() {
    setRetrying(true);
    try {
      await refetch();
    } finally {
      setRetrying(false);
    }
  }

  // Nothing ever arrived and the last attempt failed: say so. Four "n/a"
  // dials here would describe a perfectly healthy, sensorless machine.
  if (failed) {
    return (
      <GlassPanel className="gauges-panel">
        <div className="panel-header panel-header--minimal">
          <h2 className="panel-header__title">System</h2>
        </div>
        <div className="gauges-panel__offline">
          <div className="gauges-panel__offline-title">
            No sensor readings &mdash; the DevKit sidecar isn&apos;t answering.
          </div>
          {errorMessage && <div className="gauges-panel__offline-detail">{errorMessage}</div>}
          <div className="gauges-panel__offline-actions">
            <Button size="sm" variant="ghost" loading={retrying} onClick={() => void retry()}>
              Retry
            </Button>
          </div>
        </div>
      </GlassPanel>
    );
  }

  return (
    <GlassPanel className="gauges-panel">
      <div className="panel-header panel-header--minimal">
        <h2 className="panel-header__title">System</h2>
        {pending && <span className="panel-header__hint">reading sensors…</span>}
        {stale && <span className="panel-header__hint gauges-panel__stale">last known — sidecar not answering</span>}
      </div>
      <div className={clsx("gauges-panel__row", pending && "gauges-panel__row--loading")}>
        <Gauge
          label="CPU"
          percent={metrics?.CpuPercent ?? null}
          sub={metrics?.CpuTempC != null ? `${metrics.CpuTempC}°C` : "n/a"}
          tone="sapphire"
          onClick={() => setOpenGauge("cpu")}
          history={cpuHistory}
          historyCapacity={HISTORY_CAPACITY}
        />
        <Gauge
          label="Memory"
          percent={metrics?.MemoryPercent ?? null}
          sub={metrics ? `${metrics.MemoryUsedGB}/${metrics.MemoryTotalGB} GB` : undefined}
          tone="cyan"
          onClick={() => setOpenGauge("mem")}
          history={memHistory}
          historyCapacity={HISTORY_CAPACITY}
        />
        <Gauge
          label="GPU"
          percent={metrics?.GpuPercent ?? null}
          sub={metrics?.GpuTempC != null ? `${metrics.GpuTempC}°C` : "n/a"}
          tone="amber"
          onClick={() => setOpenGauge("gpu")}
          history={gpuHistory}
          historyCapacity={HISTORY_CAPACITY}
        />
        {/* No trace for Disk Free on purpose: it barely moves over a
            minute, so a sparkline there would be a flat line pretending to
            be information. */}
        <Gauge
          label="Disk Free"
          percent={diskPercent}
          sub={diskFree !== null ? `${(diskFree / 1e9).toFixed(0)} GB free` : undefined}
          tone="ember"
          onClick={() => setOpenGauge("disk")}
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
            {openGauge === "disk" ? (
              <DriveFlyout drives={asArray(metrics?.Drives)} onClose={() => setOpenGauge(null)} />
            ) : (
              <ProcessFlyout kind={openGauge} onClose={() => setOpenGauge(null)} />
            )}
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

/**
 * Badge tone/label per Get-DevKitProcessClassification value (verified in
 * core/DevKit-WidgetCore.ps1: only 'System' | 'Safe' | 'Caution' exist).
 * Anything unexpected falls back to Caution - "think before killing".
 */
const CLASSIFICATION_BADGES: Record<string, { tone: "neutral" | "success" | "warning"; label: string }> = {
  System: { tone: "neutral", label: "System" },
  Safe: { tone: "success", label: "Safe" },
  Caution: { tone: "warning", label: "Caution" },
};

function ProcessFlyout({ kind, onClose }: { kind: Exclude<GaugeKind, null | "disk">; onClose: () => void }) {
  const method = kind === "mem" ? "process.topMemory" : kind === "gpu" ? "metrics.gpuProcesses" : "process.topCpu";
  const { data, refetch, pending, failed, errorMessage } = usePolledRpc<
    TopCpuProcessRow[] | TopMemoryResult | GpuProcessUsage
  >(method, { count: 12 }, 3000);
  const [actionError, setActionError] = useState<string | null>(null);
  const [freeing, setFreeing] = useState(false);
  const [freeNote, setFreeNote] = useState<string | null>(null);
  const freeNoteTimer = useRef<number | null>(null);
  const confirmDestructive = useConfirmDestructive();

  // Don't leave the 6s note-dismiss timer firing setState on an unmounted flyout.
  useEffect(() => {
    return () => {
      if (freeNoteTimer.current !== null) window.clearTimeout(freeNoteTimer.current);
    };
  }, []);

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
    setFreeNote(null);
    if (freeNoteTimer.current !== null) window.clearTimeout(freeNoteTimer.current);
    setFreeing(true);
    try {
      const result = await rpcCall<FreeMemoryResult>("process.freeMemory");
      setFreeNote(`Freed ${Math.round(result.FreedMB)} MB across ${result.TrimmedProcesses} processes`);
      freeNoteTimer.current = window.setTimeout(() => {
        setFreeNote(null);
        freeNoteTimer.current = null;
      }, 6000);
      refetch();
    } catch (err) {
      setActionError(err instanceof RpcClientError ? err.message : "Could not free memory.");
    } finally {
      setFreeing(false);
    }
  }

  return (
    <div className="gauges-panel__flyout">
      <div className="gauges-panel__flyout-header">
        <span>{kind === "cpu" ? "Top CPU" : kind === "mem" ? "Top Memory" : "Top GPU"} Processes</span>
        <div className="gauges-panel__flyout-actions">
          {kind === "mem" && (
            <Button size="sm" variant="ghost" loading={freeing} onClick={() => void freeMemory()}>
              Free Memory
            </Button>
          )}
          <Button size="sm" variant="ghost" onClick={onClose}>
            Close
          </Button>
        </div>
      </div>
      {actionError && <div className="gauges-panel__hint">{actionError}</div>}
      {freeNote && <div className="gauges-panel__hint gauges-panel__hint--ok">{freeNote}</div>}
      {/* An empty list means "nothing running"; a failed poll must never be
          allowed to look like that. */}
      {failed && (
        <div className="gauges-panel__hint">
          Couldn&apos;t read the process list.{errorMessage ? ` ${errorMessage}` : ""}
        </div>
      )}
      {pending && !failed && rows.length === 0 && <div className="panel-empty">Reading processes…</div>}
      <div className="gauges-panel__flyout-list">
        {rows.map((row) => {
          const badge = CLASSIFICATION_BADGES[row.Classification] ?? CLASSIFICATION_BADGES.Caution;
          return (
            <div key={row.Pid} className="gauges-panel__flyout-row">
              <span className="gauges-panel__flyout-name">{row.Name}</span>
              <span className="gauges-panel__flyout-pct">{row.pctLabel}</span>
              <Badge tone={badge.tone} className="gauges-panel__class-badge">
                {badge.label}
              </Badge>
              {row.Classification !== "System" ? (
                <button
                  type="button"
                  className="gauges-panel__kill"
                  title={`Kill ${row.Name} (${row.Pid})`}
                  onClick={() => kill(row.Pid, row.Name)}
                >
                  &#10005;
                </button>
              ) : (
                <span className="gauges-panel__kill-spacer" aria-hidden="true" />
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

/**
 * Disk drill-down: every drive from metrics.system's Drives array, with a
 * used-fraction bar. No RPC of its own - the parent already polls
 * metrics.system every 2s and hands the drives down.
 */
function DriveFlyout({ drives, onClose }: { drives: DriveInfo[]; onClose: () => void }) {
  return (
    <div className="gauges-panel__flyout">
      <div className="gauges-panel__flyout-header">
        <span>Drives</span>
        <div className="gauges-panel__flyout-actions">
          <Button size="sm" variant="ghost" onClick={onClose}>
            Close
          </Button>
        </div>
      </div>
      {drives.length === 0 && <div className="panel-empty">No drive data.</div>}
      <div className="gauges-panel__drive-list">
        {drives.map((drive) => {
          const usedFrac =
            drive.TotalBytes > 0 ? Math.min(1, Math.max(0, 1 - drive.FreeBytes / drive.TotalBytes)) : 0;
          const usedPct = usedFrac * 100;
          return (
            <div key={drive.Name} className="gauges-panel__drive">
              <div className="gauges-panel__drive-top">
                <span className="gauges-panel__drive-name">{drive.Name}</span>
                <span className="gauges-panel__drive-free">
                  {(drive.FreeBytes / 1e9).toFixed(0)} GB free of {(drive.TotalBytes / 1e9).toFixed(0)} GB
                </span>
              </div>
              <div
                className="gauges-panel__drive-bar"
                role="progressbar"
                aria-label={`${drive.Name} used space`}
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={Math.round(usedPct)}
              >
                <div
                  className={clsx(
                    "gauges-panel__drive-fill",
                    usedPct > 95
                      ? "gauges-panel__drive-fill--danger"
                      : usedPct > 85
                        ? "gauges-panel__drive-fill--warning"
                        : null,
                  )}
                  style={{ width: `${usedPct}%` }}
                />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
