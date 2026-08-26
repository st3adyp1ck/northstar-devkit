import { useEffect, useRef, useState } from "react";
import { motion, type Transition } from "framer-motion";
import { rpcCall, onToolRun } from "../../lib/ipc";
import { useProjectStore } from "../../stores/useProjectStore";
import { useRunHistoryStore, type RunHistoryEntry } from "../../stores/useRunHistoryStore";
import { useConfirmDestructive } from "../../hooks/useConfirmDestructive";
import { playSound } from "../../lib/sounds";
import { Button } from "../../components/primitives/Button";
import { GlassPanel } from "../../components/primitives/GlassPanel";
import { Badge } from "../../components/primitives/Badge";
import { Expander } from "../../components/primitives/Expander";
import { RunHistoryList } from "../../components/history/RunHistoryList";
import type { CatalogItem, CatalogModule } from "../../lib/types";
import "./ToolRunDialog.css";

interface ToolRunDialogProps {
  module: CatalogModule;
  item: CatalogItem;
  onClose: () => void;
}

/**
 * What is actually being launched. Normally this dialog's own module/item,
 * but "Run again" from history replays a recorded run - which may be a
 * different tool entirely - through the same execution path.
 */
interface RunTarget {
  folder: string;
  script: string;
  label: string;
  caution: boolean;
}

/**
 * What the sidecar answers a tool.stop with - see New-DevKitToolStopResult
 * in core/RpcMethods.ps1, which is also where `message` is worded.
 *
 * `notFound` and `alreadyExited` are ordinary outcomes of the
 * click-versus-finish race, not failures: the sidecar returns them as a
 * SUCCESSFUL result precisely so this dialog can report them as a fact
 * rather than as an error.
 */
interface ToolStopResult {
  runId: string;
  stopped: boolean;
  reason: "stopped" | "notFound" | "alreadyExited" | "failed";
  processId: number;
  killedProcessIds: number[];
  killedCount: number;
  /** False when the kill landed but the run still has not reported completion - something is holding its stdout pipe. */
  laneReleased: boolean;
  message: string;
}

/**
 * Hard cap on lines kept in the live console. The list is rendered
 * unvirtualized (ToolConsole maps straight over it), so an uncapped array
 * means one React re-render and one DOM node per emitted line - fine for a
 * normal tool, fatal for a runaway one. The recorded history has its own,
 * separate caps in useRunHistoryStore.
 */
const MAX_CONSOLE_LINES = 2000;

/** Same OS reduced-motion check the Control Center grid/nav use - see ControlCenterApp.tsx for the longer rationale. */
function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(
    () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
  useEffect(() => {
    const mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    const onChange = () => setReduced(mql.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);
  return reduced;
}

/**
 * Dynamic form generated from the catalog item's `prompts` (typed inputs
 * with real Min/Max/Optional validation, mirroring
 * Read-DevKitTypedValue's contract) plus `staticArgs` applied last, then
 * streams the run's stdout/stderr live via the sidecar's tool.output
 * events. This is the headless execution path the plan called for -
 * "most tools run headlessly with streamed output instead of bouncing you
 * to a terminal."
 */
export function ToolRunDialog({ module, item, onClose }: ToolRunDialogProps) {
  const active = useProjectStore((s) => s.active);
  const [values, setValues] = useState<Record<string, string>>({});
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [lines, setLines] = useState<{ stream: string; line: string }[]>([]);
  const [running, setRunning] = useState(false);
  const [exitCode, setExitCode] = useState<number | null>(null);
  /** The tool.run RPC failed but the run may still be alive - see executeRun. */
  const [degraded, setDegraded] = useState(false);
  /** A tool.stop is in flight for the active run. */
  const [stopping, setStopping] = useState(false);
  /** The run that just ended was cancelled from here, so it reads as cancelled rather than failed. */
  const [cancelled, setCancelled] = useState(false);
  const consoleRef = useRef<HTMLDivElement>(null);
  const unlistenRef = useRef<(() => void) | null>(null);
  /** runId of the run this dialog is currently watching, if any. */
  const activeRunRef = useRef<string | null>(null);
  /**
   * runId this dialog has asked the sidecar to kill. tool.finished carries a
   * `cancelled` flag of its own, but onToolRun (lib/ipc.ts) forwards only the
   * exit code, so this is how the finish handler knows a -1 was a
   * cancellation the user asked for rather than a crash.
   */
  const stopRequestedRef = useRef<string | null>(null);
  const reducedMotion = usePrefersReducedMotion();
  const confirmDestructive = useConfirmDestructive();
  const historyCount = useRunHistoryStore((s) => s.entries.length);
  const startRun = useRunHistoryStore((s) => s.startRun);
  const appendLine = useRunHistoryStore((s) => s.appendLine);
  const finishRun = useRunHistoryStore((s) => s.finishRun);

  useEffect(() => {
    consoleRef.current?.scrollTo({ top: consoleRef.current.scrollHeight });
  }, [lines]);

  // Unsubscribe from any in-flight run's events if the dialog closes
  // mid-run (e.g. the user hits Close while output is still streaming) -
  // without this, the tool.output listener for that runId outlives the
  // dialog and just accumulates with every run. Closing is deliberately NOT
  // cancelling - that is what "Stop run" is for - so the run keeps going in
  // the sidecar and its history entry is marked detached rather than left
  // spinning forever.
  useEffect(() => {
    return () => {
      unlistenRef.current?.();
      unlistenRef.current = null;
      const runId = activeRunRef.current;
      activeRunRef.current = null;
      if (runId) useRunHistoryStore.getState().detachRun(runId);
    };
  }, []);

  /**
   * Mirrors Read-DevKitTypedValue's exact validation contract (see
   * tools/lib/DevKit-Common.ps1): Int requires a plain non-negative integer
   * string within [Min, Max] (both $null-checked, so a bound of 0 is real);
   * String just requires non-blank; YesNo is never invalid. A blank or
   * failed-validation value is treated identically to the PowerShell side
   * (Read-DevKitTypedValue returns $null for both) - Optional prompts skip
   * the arg silently, non-Optional prompts block the run with the same
   * InvalidMessage/fallback text Invoke-DevKitTool would show.
   */
  function validate(): { ok: true; args: string[] } | { ok: false; errors: Record<string, string> } {
    const args: string[] = [];
    const errors: Record<string, string> = {};

    if (item.requiresProject && active) {
      args.push(item.projectArgName ? `-${item.projectArgName}` : "-Path", active.path);
    }

    for (const prompt of item.prompts ?? []) {
      const raw = (values[prompt.Name] ?? "").trim();

      if (prompt.Type === "YesNo") {
        if (raw === "y") args.push(`-${prompt.Name}`);
        continue;
      }

      let valid = raw.length > 0;
      if (valid && prompt.Type === "Int") {
        // Same as PS's '^\d+$' - digits only, no sign, no decimal point.
        if (!/^\d+$/.test(raw)) {
          valid = false;
        } else {
          const val = Number(raw);
          // Same overflow guard as Read-DevKitTypedValue's own [int]::MaxValue
          // check, for a prompt with no explicit Max to catch it first.
          if (!Number.isSafeInteger(val) || val > 2147483647) valid = false;
          else if (prompt.Min != null && val < prompt.Min) valid = false;
          else if (prompt.Max != null && val > prompt.Max) valid = false;
        }
      }

      if (!valid) {
        if (prompt.Optional) continue; // matches Invoke-DevKitTool: blank/invalid + Optional just skips the arg
        errors[prompt.Name] = prompt.InvalidMessage || `Invalid value for ${prompt.Name}.`;
        continue;
      }

      args.push(`-${prompt.Name}`, raw);
    }

    if (Object.keys(errors).length > 0) return { ok: false, errors };

    if (item.staticArgs) {
      for (const [key, val] of Object.entries(item.staticArgs)) {
        if (val === true) args.push(`-${key}`);
        else if (val !== false && val !== null) args.push(`-${key}`, String(val));
      }
    }
    return { ok: true, args };
  }

  /**
   * Launches a run and watches it to completion.
   *
   * The important property here is that the tool.run RPC and the run
   * itself are two different lifetimes. The RPC round-trip can fail - most
   * obviously by timing out - while the tool carries on happily in the
   * sidecar, still emitting tool.output and, eventually, tool.finished.
   * The old code treated any rejection as the end of the run: it flipped
   * running=false and unsubscribed, so a long tool's output stopped dead
   * mid-stream and the run could never be finalized. Now an RPC rejection
   * only downgrades to `degraded` - a warning line plus a "Stop watching"
   * escape hatch - and the subscription stays up until the run genuinely
   * ends or the dialog unmounts.
   *
   * A failure to SUBSCRIBE is different, and is still fatal: without the
   * listener nothing would ever finalize the run, so it is failed here.
   */
  async function executeRun(args: string[], target: RunTarget, intro?: string) {
    // A previous run may still be subscribed (degraded, never finalized).
    // Retire it before taking over the console.
    unlistenRef.current?.();
    unlistenRef.current = null;
    const previous = activeRunRef.current;
    if (previous) useRunHistoryStore.getState().detachRun(previous);

    setLines(intro ? [{ stream: "stdout", line: intro }] : []);
    setExitCode(null);
    setDegraded(false);
    setStopping(false);
    setCancelled(false);
    stopRequestedRef.current = null;
    setRunning(true);

    const runId = crypto.randomUUID();
    activeRunRef.current = runId;
    startRun(runId, { folder: target.folder, script: target.script, label: target.label, args, caution: target.caution });

    try {
      const unlisten = await onToolRun(runId, {
        onOutput: (stream, line) => {
          // Cap the on-screen console. A runaway tool can emit thousands of
          // lines per second (a menu script looping on an unreadable stdin
          // managed ~1,800/s), and this array is rendered unvirtualized -
          // uncapped it means a React re-render and a new DOM node per line
          // until the window dies. useRunHistoryStore already bounds what it
          // retains; this bounds what is displayed.
          setLines((prev) => {
            const next = [...prev, { stream, line }];
            return next.length > MAX_CONSOLE_LINES ? next.slice(-MAX_CONSOLE_LINES) : next;
          });
          appendLine(runId, stream, line);
        },
        onFinished: (code) => {
          if (activeRunRef.current !== runId) return;
          const wasCancelled = stopRequestedRef.current === runId;
          setExitCode(code);
          setRunning(false);
          setDegraded(false);
          setStopping(false);
          setCancelled(wasCancelled);
          unlisten();
          unlistenRef.current = null;
          activeRunRef.current = null;
          finishRun(runId, code);
          // A killed pwsh child exits -1. That is the shape of a
          // cancellation the user asked for, not of a failure, so it must
          // not get the failure sound.
          playSound(wasCancelled ? "thud" : code === 0 ? "success" : "error");
        },
      });
      unlistenRef.current = unlisten;
    } catch (err) {
      const message = `Could not subscribe to run output: ${String(err)}`;
      setLines((prev) => [...prev, { stream: "stderr", line: message }]);
      setExitCode(-1);
      setRunning(false);
      activeRunRef.current = null;
      appendLine(runId, "stderr", message);
      finishRun(runId, -1);
      return;
    }

    try {
      // `confirmed` tells the sidecar the user has ALREADY consented in the
      // app's own caution dialog, so it may append -Force to scripts that
      // declare it (core/RpcMethods.ps1's Add-DevKitForceArgument).
      //
      // This is load-bearing, not an optimization. tool.run always spawns
      // with -NonInteractive, where Confirm-DevKitDestructiveAction cannot
      // read a console prompt and correctly declines - and the 16 catalog
      // scripts that gate on it then exit 0. Without this flag the dialog
      // renders a green "exit 0" success badge and plays the success sound
      // while SFC/DISM/docker prune never ran at all.
      //
      // Safe to send unconditionally-by-caution: BOTH paths into executeRun
      // gate first - run() above confirms on item.caution, and
      // RunHistoryList confirms on entry.caution before runFromHistory - so
      // a true value here always means a human said yes to THIS run.
      await rpcCall("tool.run", {
        folder: target.folder,
        script: target.script,
        args,
        runId,
        confirmed: target.caution,
      });
    } catch (err) {
      // Superseded, or tool.finished already landed while the RPC was
      // still settling - the run's outcome is already known, don't muddy it.
      if (activeRunRef.current !== runId) return;
      const message = `RPC error: ${String(err)} - the tool may still be running; still watching for it to finish.`;
      setLines((prev) => [...prev, { stream: "stderr", line: message }]);
      appendLine(runId, "stderr", message);
      setDegraded(true);
    }
  }

  /**
   * Real cancellation: asks the sidecar to kill the run's whole process tree
   * (tool.stop -> Stop-DevKitToolRun in core/RpcMethods.ps1). This is the
   * button that ENDS a run, as opposed to Close and "Stop watching", which
   * only detach this dialog.
   *
   * It deliberately does not flip running=false itself. The run is over when
   * tool.finished says it is, and that event is what writes the final
   * console line and the badge; declaring victory here would be claiming a
   * kill that might not have landed. Until then the button shows a stopping
   * state.
   */
  async function stopRun() {
    const runId = activeRunRef.current;
    if (!runId || stopping) return;
    playSound("thud");
    setStopping(true);
    stopRequestedRef.current = runId;

    let result: ToolStopResult | null = null;
    try {
      result = await rpcCall<ToolStopResult>("tool.stop", { runId });
    } catch (err) {
      // Superseded, or the run ended while the stop was in flight - either
      // way its own outcome has the last word.
      if (activeRunRef.current !== runId) return;
      const message = `Could not cancel this run: ${String(err)}`;
      setLines((prev) => [...prev, { stream: "stderr", line: message }]);
      appendLine(runId, "stderr", message);
      setStopping(false);
      stopRequestedRef.current = null;
      return;
    }

    if (activeRunRef.current !== runId) return;

    // The run ending a heartbeat before the click is a race, not an error:
    // the sidecar answers it with a successful notFound/alreadyExited whose
    // message is already plain English, so print that verbatim either way.
    const line = result?.message ?? "Stop requested.";
    setLines((prev) => [...prev, { stream: "stdout", line }]);
    appendLine(runId, "stdout", line);

    if (!result?.stopped) {
      // Nothing was killed, so no tool.finished is coming on our account -
      // the run had already ended and its own event is already on its way.
      setStopping(false);
      stopRequestedRef.current = null;
    }
  }

  /**
   * Detaches from a run without ending it - the escape hatch for a run whose
   * completion event will never arrive (the sidecar restarted under it, for
   * instance), so the dialog can't be left disabled forever. "Stop run" is
   * what actually cancels; once detached, this dialog no longer knows the
   * runId and can no longer stop it.
   */
  function stopWatching() {
    const runId = activeRunRef.current;
    unlistenRef.current?.();
    unlistenRef.current = null;
    activeRunRef.current = null;
    stopRequestedRef.current = null;
    if (runId) {
      const message = "Stopped watching this run. It may still be executing, and can no longer be stopped from this dialog.";
      setLines((prev) => [...prev, { stream: "stderr", line: message }]);
      appendLine(runId, "stderr", message);
      useRunHistoryStore.getState().detachRun(runId);
    }
    setRunning(false);
    setDegraded(false);
    setStopping(false);
  }

  /** Replays a recorded run. RunHistoryList has already applied the caution gate. */
  function runFromHistory(entry: RunHistoryEntry) {
    const sameTool = entry.folder === module.folder && entry.script === item.script;
    void executeRun(
      entry.args,
      { folder: entry.folder, script: entry.script, label: entry.label, caution: entry.caution },
      sameTool ? undefined : `- re-running ${entry.folder}/${entry.script} from history`,
    );
  }

  async function run() {
    const result = validate();
    if (!result.ok) {
      setFieldErrors(result.errors);
      return;
    }
    setFieldErrors({});

    const target: RunTarget = {
      folder: module.folder,
      script: item.script,
      label: item.label,
      caution: !!item.caution,
    };

    // item.caution tools (e.g. Docker Nuke, Kill All Node) run through the
    // same confirmDestructive gate as the widget's own destructive
    // actions - see hooks/useConfirmDestructive.ts. Gated here (on Run,
    // after the user has already seen the tool's help text and filled in
    // any prompts) rather than at card-selection time, so the dialog
    // itself is never skipped.
    if (item.caution) {
      confirmDestructive(
        {
          title: `Run ${item.label}?`,
          description: (
            <>
              This runs <strong>{item.label}</strong> ({module.folder}/{item.script}), flagged as a caution tool - it
              may make changes that can't be undone.
            </>
          ),
          confirmLabel: "Run",
          danger: true,
        },
        () => executeRun(result.args, target),
      );
    } else {
      await executeRun(result.args, target);
    }
  }

  const needsProjectButMissing = item.requiresProject && !active;
  const hasFieldErrors = Object.keys(fieldErrors).length > 0;

  const overlayTransition: Transition = reducedMotion ? { duration: 0 } : { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] };
  const panelTransition: Transition = reducedMotion
    ? { duration: 0 }
    : { type: "spring", stiffness: 420, damping: 32, mass: 0.9 };

  return (
    <motion.div
      className="tool-run-dialog__overlay"
      onClick={onClose}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={overlayTransition}
    >
      <motion.div
        initial={reducedMotion ? false : { opacity: 0, scale: 0.94, y: 16 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: 0.96, y: 8 }}
        transition={panelTransition}
      >
        <GlassPanel strong className="tool-run-dialog">
          <div onClick={(e) => e.stopPropagation()}>
            <div className="tool-run-dialog__header">
              <div>
                <div className="tool-run-dialog__title">{item.label}</div>
                <div className="tool-run-dialog__meta">
                  {item.caution && <Badge tone="danger">Caution</Badge>}
                  {item.requiresProject && <Badge tone="accent">Project</Badge>}
                  <span className="tool-run-dialog__script">{module.folder}/{item.script}</span>
                </div>
              </div>
              <Button size="sm" variant="ghost" onClick={onClose}>
                Close
              </Button>
            </div>

            <p className="tool-run-dialog__help">{item.help}</p>

            {needsProjectButMissing && (
              <div className="tool-run-dialog__warning">Select a project in the widget first - this tool requires one.</div>
            )}

            {(item.prompts ?? []).length > 0 && (
              <div className="tool-run-dialog__form">
                {(item.prompts ?? []).map((p) => {
                  function clearFieldError() {
                    setFieldErrors((prev) => {
                      if (!(p.Name in prev)) return prev;
                      const next = { ...prev };
                      delete next[p.Name];
                      return next;
                    });
                  }
                  return (
                    <label key={p.Name} className="tool-run-dialog__field">
                      <span>{p.Prompt}</span>
                      {p.Type === "YesNo" ? (
                        <select
                          value={values[p.Name] ?? "n"}
                          onChange={(e) => setValues((v) => ({ ...v, [p.Name]: e.target.value }))}
                        >
                          <option value="n">No</option>
                          <option value="y">Yes</option>
                        </select>
                      ) : (
                        <input
                          type={p.Type === "Int" ? "number" : "text"}
                          min={p.Min}
                          max={p.Max}
                          aria-invalid={p.Name in fieldErrors}
                          value={values[p.Name] ?? ""}
                          onChange={(e) => {
                            setValues((v) => ({ ...v, [p.Name]: e.target.value }));
                            clearFieldError();
                          }}
                        />
                      )}
                      {fieldErrors[p.Name] && (
                        <span className="tool-run-dialog__script" style={{ color: "var(--signal-red)" }}>
                          {fieldErrors[p.Name]}
                        </span>
                      )}
                    </label>
                  );
                })}
              </div>
            )}

            {hasFieldErrors && (
              <div className="tool-run-dialog__warning">Fix the highlighted field{Object.keys(fieldErrors).length === 1 ? "" : "s"} before running.</div>
            )}

            <div className="tool-run-dialog__actions">
              <Button variant={item.caution ? "danger" : "primary"} disabled={needsProjectButMissing} loading={running} onClick={run}>
                Run
              </Button>
              {running && (
                <Button size="sm" variant="danger" loading={stopping} onClick={stopRun}>
                  {stopping ? "Stopping" : "Stop run"}
                </Button>
              )}
              {running && (
                <Button size="sm" variant="ghost" onClick={stopWatching}>
                  Stop watching
                </Button>
              )}
              {cancelled ? (
                <Badge tone="warning">cancelled</Badge>
              ) : (
                exitCode !== null && <Badge tone={exitCode === 0 ? "success" : "danger"}>exit {exitCode}</Badge>
              )}
            </div>

            {running && (
              <p className="tool-run-dialog__stop-hint">
                <strong>Stop run</strong> ends the tool and every process it started. <strong>Stop watching</strong> and{" "}
                <strong>Close</strong> only detach this dialog - the tool keeps running.
              </p>
            )}

            {degraded && (
              <div className="tool-run-dialog__watching">
                The run request errored, but the tool may still be executing - output is still being watched for. "Stop run"
                still works: it is answered on a different sidecar lane from the one this run is blocking, and it kills the
                tool's whole process tree.
              </div>
            )}

            {lines.length > 0 && (
              <div className="tool-run-dialog__console" ref={consoleRef}>
                {lines.map((l, i) => (
                  <div
                    key={i}
                    className={l.stream === "stderr" ? "tool-run-dialog__console-line tool-run-dialog__console-err" : "tool-run-dialog__console-line"}
                  >
                    {l.line}
                  </div>
                ))}
              </div>
            )}

            <div className="tool-run-dialog__history">
              <Expander
                title="Run history"
                actionSlot={<Badge tone={historyCount > 0 ? "accent" : "neutral"}>{historyCount}</Badge>}
                lazyMount
              >
                <div className="tool-run-dialog__history-body">
                  <RunHistoryList onRunAgain={runFromHistory} busy={running} />
                </div>
              </Expander>
            </div>
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}
