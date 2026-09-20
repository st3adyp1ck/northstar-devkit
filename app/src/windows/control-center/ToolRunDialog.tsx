import { useCallback, useEffect, useRef, useState } from "react";
import { motion, type Transition } from "framer-motion";
import { open } from "@tauri-apps/plugin-dialog";
import type { UnlistenFn } from "@tauri-apps/api/event";
import clsx from "clsx";
import { rpcCall, onToolRun, onDevKitEvent, parseRpcError } from "../../lib/ipc";
import { useProjectStore } from "../../stores/useProjectStore";
import { useRunHistoryStore, type RunHistoryEntry } from "../../stores/useRunHistoryStore";
import { useConfirmDestructive } from "../../hooks/useConfirmDestructive";
import { useAnimationsEnabled } from "../../hooks/useApplyAppearance";
import { playSound } from "../../lib/sounds";
import { Button } from "../../components/primitives/Button";
import { GlassPanel } from "../../components/primitives/GlassPanel";
import { Badge } from "../../components/primitives/Badge";
import { Expander } from "../../components/primitives/Expander";
import { RunHistoryList } from "../../components/history/RunHistoryList";
import type { CatalogItem, CatalogModule, DirChildrenResult } from "../../lib/types";
import "./ToolRunDialog.css";

interface ToolRunDialogProps {
  module: CatalogModule;
  item: CatalogItem;
  /** Mounted as the widget's embedded tray pane (no picker of its own) vs the standalone window. */
  embedded?: boolean;
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

/**
 * How long streamed console lines may pile up in the buffer before a flush.
 * tool.output events arrive one line at a time and a chatty tool can emit
 * ~1,800/s; committing each line as its own setLines gave the dialog one
 * full re-render per line. Coalescing to a ~100ms window caps that at ~10
 * re-renders/s while the run is live; tool.finished and every dialog state
 * change (stop, close) flush immediately so nothing is ever left pending.
 */
const STREAM_FLUSH_MS = 100;

/**
 * Runs this dialog stopped watching while still live - Close mid-run,
 * "Stop watching", or a new run replacing a degraded one. The history row
 * keeps its runId and stays "running", and this single watcher finalizes it
 * when tool.finished eventually lands - without it no mounted surface was
 * listening, so the row spun forever and nothing anywhere could stop the
 * run still holding the sidecar's tool lane. Rows handed off this way are
 * stoppable from Run history (see stopRunFromHistory).
 *
 * Bounded, because a run whose tool.finished never arrives (a sidecar
 * restart under it) would otherwise linger for the webview's whole life:
 * entries age out after a day and the count is capped, oldest dropped
 * first (insertion order == handoff order).
 */
const BACKGROUND_RUN_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const BACKGROUND_RUN_MAX_COUNT = 50;
const backgroundRuns = new Map<string, number>();
let backgroundWatcher: Promise<UnlistenFn> | null = null;

function watchInBackground(runId: string): void {
  const now = Date.now();
  backgroundRuns.set(runId, now);
  for (const [id, at] of backgroundRuns) {
    if (now - at > BACKGROUND_RUN_MAX_AGE_MS) backgroundRuns.delete(id);
  }
  while (backgroundRuns.size > BACKGROUND_RUN_MAX_COUNT) {
    const oldest = backgroundRuns.keys().next().value;
    if (oldest === undefined) break;
    backgroundRuns.delete(oldest);
  }
  backgroundWatcher ??= onDevKitEvent((evt) => {
    const id = evt.runId;
    if (!id || !backgroundRuns.has(id)) return;
    const store = useRunHistoryStore.getState();
    if (evt.event === "tool.output" && typeof evt.line === "string") {
      store.appendLine(id, evt.stream === "stderr" ? "stderr" : "stdout", evt.line);
    } else if (evt.event === "tool.finished") {
      backgroundRuns.delete(id);
      store.finishRun(id, Number(evt.exitCode ?? -1), evt.cancelled === true);
    }
  });
}

/**
 * WinForms OpenFileDialog filter string ("DevKit backups (*.json)|*.json|All
 * files (*.*)|*.*") -> tauri plugin-dialog filters. Alternating
 * description|pattern pairs; extensions are derived from the *.ext
 * patterns. "*"/"*.*" ("all files") map to NO filter rather than a literal
 * "*" extension - the plugin's DialogFilter documents only real extensions,
 * so a star would be passed through ambiguously; dropping the pair (or the
 * whole list) leaves open() unfiltered, which IS "all files". Odd or empty
 * strings degrade the same way rather than producing a half-built dialog.
 */
function parseWinFormsFilter(filter: string): { name: string; extensions: string[] }[] | undefined {
  const parts = filter
    .split("|")
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  const filters: { name: string; extensions: string[] }[] = [];
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const extensions = parts[i + 1]
      .split(";")
      .map((p) => p.trim().replace(/^\*\./, ""))
      .filter((p) => /^[A-Za-z0-9_-]+$/.test(p));
    if (extensions.length > 0) filters.push({ name: parts[i], extensions });
  }
  return filters.length > 0 ? filters : undefined;
}

/**
 * Best-effort existence check for a requiresFile path, through the
 * files.children RPC - the webview has no filesystem access of its own.
 * true/false when the parent directory lists; null when it can't (missing
 * parent, access denied, sidecar error), meaning "can't say": a can't-say
 * never blocks the run, since the tool itself re-validates the path and
 * reports its own error.
 */
async function fileExistsOnDisk(path: string): Promise<boolean | null> {
  const sep = Math.max(path.lastIndexOf("\\"), path.lastIndexOf("/"));
  const parent = sep > 0 ? path.slice(0, sep) : ".";
  const name = (sep >= 0 ? path.slice(sep + 1) : path).toLowerCase();
  if (!name) return null;
  try {
    const result = await rpcCall<DirChildrenResult>("files.children", { path: parent });
    if (result.Error) return null;
    return result.Children.some((c) => !c.IsDirectory && c.Name.toLowerCase() === name);
  } catch {
    return null;
  }
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
export function ToolRunDialog({ module, item, embedded = false, onClose }: ToolRunDialogProps) {
  const active = useProjectStore((s) => s.active);
  const [values, setValues] = useState<Record<string, string>>({});
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [lines, setLines] = useState<{ stream: string; line: string }[]>([]);
  const [running, setRunning] = useState(false);
  const [exitCode, setExitCode] = useState<number | null>(null);
  /** The tool.run RPC failed but the run may still be alive - see executeRun. */
  const [degraded, setDegraded] = useState(false);
  /** The run never started (hard tool.run rejection, e.g. the tool lane is busy). */
  const [launchError, setLaunchError] = useState<{ message: string; laneBusy: boolean } | null>(null);
  /** A tool.stop is in flight for the active run. */
  const [stopping, setStopping] = useState(false);
  /** The run that just ended was cancelled from here, so it reads as cancelled rather than failed. */
  const [cancelled, setCancelled] = useState(false);
  /** Bumped to reopen the Run history expander (the lane-busy state offers it). */
  const [historyNonce, setHistoryNonce] = useState(0);
  const consoleRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);
  const unlistenRef = useRef<(() => void) | null>(null);
  /** runId of the run this dialog is currently watching, if any. */
  const activeRunRef = useRef<string | null>(null);
  /**
   * runId this dialog has asked the sidecar to kill. tool.finished carries
   * the sidecar's own `cancelled` flag (forwarded by onToolRun), which is
   * the authoritative answer; this ref is the local cross-check for a stop
   * requested from HERE, so a -1 is never misread as a crash.
   */
  const stopRequestedRef = useRef<string | null>(null);
  /** True once tool.started arrived for the active run - the only proof it actually launched. */
  const startedRef = useRef(false);
  /**
   * Streamed lines waiting for the next coalesced flush (see
   * STREAM_FLUSH_MS). Ref, not state: nothing reads it during render.
   */
  const lineBufferRef = useRef<{ stream: string; line: string }[]>([]);
  const flushTimerRef = useRef<number | null>(null);
  const animationsEnabled = useAnimationsEnabled();
  const confirmDestructive = useConfirmDestructive();
  const historyCount = useRunHistoryStore((s) => s.entries.length);
  const startRun = useRunHistoryStore((s) => s.startRun);
  const appendLine = useRunHistoryStore((s) => s.appendLine);
  const finishRun = useRunHistoryStore((s) => s.finishRun);

  /**
   * Commits buffered console lines in one setLines (see STREAM_FLUSH_MS).
   * MAX_CONSOLE_LINES is applied here, same cap as before, just batched.
   */
  const flushLines = useCallback(() => {
    if (flushTimerRef.current !== null) {
      window.clearTimeout(flushTimerRef.current);
      flushTimerRef.current = null;
    }
    const pending = lineBufferRef.current;
    if (pending.length === 0) return;
    lineBufferRef.current = [];
    setLines((prev) => {
      const next = [...prev, ...pending];
      return next.length > MAX_CONSOLE_LINES ? next.slice(-MAX_CONSOLE_LINES) : next;
    });
  }, []);

  function bufferLine(stream: string, line: string) {
    lineBufferRef.current.push({ stream, line });
    if (flushTimerRef.current === null) {
      flushTimerRef.current = window.setTimeout(flushLines, STREAM_FLUSH_MS);
    }
  }

  /**
   * Empties the pending buffer into the run's HISTORY entry instead of the
   * on-screen console - used when handing a still-live run to the background
   * watcher, where lines must keep accumulating in the transcript even
   * though nobody is rendering them any more.
   */
  function drainBufferToStore(runId: string) {
    const pending = lineBufferRef.current;
    lineBufferRef.current = [];
    if (flushTimerRef.current !== null) {
      window.clearTimeout(flushTimerRef.current);
      flushTimerRef.current = null;
    }
    for (const l of pending) appendLine(runId, l.stream, l.line);
  }

  useEffect(() => {
    consoleRef.current?.scrollTo({ top: consoleRef.current.scrollHeight });
  }, [lines]);

  // Initial focus lands on the dialog panel so keyboard users tab from
  // inside it (not from whatever sits under the overlay), and screen readers
  // get role/aria-modal below.
  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  /*
   * Escape closes THIS dialog before any surrounding chrome reacts. The
   * widget's flyout listens on window too but deliberately bails while a
   * dialog overlay is in the DOM (see useWidgetFlyout's
   * DIALOG_OVERLAY_SELECTOR), so the layering is: dialog first, tray second.
   * preventDefault + stopPropagation keep that one-level-at-a-time order for
   * any listener registered before this one. A modal rendered ABOVE this
   * dialog (the caution confirm, settings, the error center...) owns Escape
   * while it is up: this listener registered first (the dialog mounted
   * before the confirm did), and same-target window listeners fire in
   * registration order - so without this check one Escape would close the
   * dialog underneath and orphan the confirm. Escape typed into the
   * embedded terminal or a real textarea belongs to whatever is
   * running/editing there and is left alone.
   */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      if (
        document.querySelector(
          ".confirm-dialog__overlay, .update-dialog__overlay, .settings-dialog__overlay, .error-center__overlay, .project-manager__overlay",
        )
      ) {
        return;
      }
      const t = e.target;
      if (t instanceof Element && (t.closest(".terminal-view") || t.closest("textarea, [contenteditable='true']"))) return;
      e.preventDefault();
      e.stopPropagation();
      onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Unsubscribe from any in-flight run's events if the dialog closes
  // mid-run (e.g. the user hits Close while output is still streaming).
  // Closing is deliberately NOT cancelling - that is what "Stop run" is for -
  // so the run keeps going in the sidecar and its history row stays live
  // and stoppable; the module-level background watcher (see
  // watchInBackground) finalizes it when tool.finished lands.
  useEffect(() => {
    return () => {
      if (flushTimerRef.current !== null) {
        window.clearTimeout(flushTimerRef.current);
        flushTimerRef.current = null;
      }
      const runId = activeRunRef.current;
      unlistenRef.current?.();
      unlistenRef.current = null;
      activeRunRef.current = null;
      if (runId) {
        drainBufferToStore(runId);
        watchInBackground(runId);
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /**
   * Mirrors Read-DevKitTypedValue's exact validation contract (see
   * tools/lib/DevKit-Common.ps1): Int requires a plain non-negative integer
   * string within [Min, Max] (both $null-checked, so a bound of 0 is real);
   * String just requires non-blank; YesNo is never invalid. A blank or
   * failed-validation value is treated identically to the PowerShell side
   * (Read-DevKitTypedValue returns $null for both) - Optional prompts skip
   * the arg silently, non-Optional prompts block the run with the same
   * InvalidMessage/fallback text Invoke-DevKitTool would show. Values are
   * deliberately NOT trimmed: Read-DevKitTypedValue preserves whitespace, so
   * whatever survives validation here must reach the script byte for byte.
   * A requiresFile entry adds its path as -<ParamName> <path> (the same
   * splat Build-DevKitToolCall builds), validated non-empty and confirmed to
   * exist where the check can run.
   */
  async function validate(): Promise<{ ok: true; args: string[] } | { ok: false; errors: Record<string, string> }> {
    const args: string[] = [];
    const errors: Record<string, string> = {};

    if (item.requiresProject && active) {
      args.push(item.projectArgName ? `-${item.projectArgName}` : "-Path", active.path);
    }

    for (const prompt of item.prompts ?? []) {
      const raw = values[prompt.Name] ?? "";

      if (prompt.Type === "YesNo") {
        if (raw === "y") args.push(`-${prompt.Name}`);
        continue;
      }

      let valid = /\S/.test(raw);
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

    if (item.requiresFile) {
      const paramName = item.requiresFile.ParamName;
      const raw = values[paramName] ?? "";
      if (!/\S/.test(raw)) {
        errors[paramName] = `${item.requiresFile.TypePrompt} - a file is required.`;
      } else if ((await fileExistsOnDisk(raw)) === false) {
        errors[paramName] = `File not found: ${raw}`;
      } else {
        args.push(`-${paramName}`, raw);
      }
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
    // Hand it to the background watcher - its history row stays live and
    // stoppable - before this dialog takes over the console.
    unlistenRef.current?.();
    unlistenRef.current = null;
    const previous = activeRunRef.current;
    if (previous) {
      drainBufferToStore(previous);
      watchInBackground(previous);
    }

    setLines(intro ? [{ stream: "stdout", line: intro }] : []);
    setExitCode(null);
    setDegraded(false);
    setLaunchError(null);
    setStopping(false);
    setCancelled(false);
    startedRef.current = false;
    stopRequestedRef.current = null;
    setRunning(true);

    const runId = crypto.randomUUID();
    activeRunRef.current = runId;
    startRun(runId, { folder: target.folder, script: target.script, label: target.label, args, caution: target.caution });

    try {
      const unlisten = await onToolRun(runId, {
        onStarted: () => {
          startedRef.current = true;
        },
        onOutput: (stream, line) => {
          // Cap the on-screen console. A runaway tool can emit thousands of
          // lines per second (a menu script looping on an unreadable stdin
          // managed ~1,800/s), and this array is rendered unvirtualized -
          // uncapped it means a React re-render and a new DOM node per line
          // until the window dies. The lines are coalesced before they reach
          // state (see STREAM_FLUSH_MS); the cap itself is applied in
          // flushLines. useRunHistoryStore already bounds what it retains;
          // this bounds what is displayed.
          bufferLine(stream, line);
          appendLine(runId, stream, line);
        },
        onFinished: (code, evtCancelled) => {
          if (activeRunRef.current !== runId) return;
          flushLines();
          const wasCancelled = evtCancelled || stopRequestedRef.current === runId;
          setExitCode(code);
          setRunning(false);
          setDegraded(false);
          setStopping(false);
          setCancelled(wasCancelled);
          unlisten();
          unlistenRef.current = null;
          activeRunRef.current = null;
          finishRun(runId, code, wasCancelled);
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
      const rejection = parseRpcError(err);

      // The sidecar refuses to launch while its single tool lane is still
      // busy with another run. Nothing started, nothing will, and there is
      // nothing to watch - fail fast with the distinct state (plus a direct
      // link to the history rows, where the other run can be stopped).
      if (rejection.kind === "toolLaneBusy" || rejection.message.startsWith("Another DevKit tool is already running")) {
        unlistenRef.current?.();
        unlistenRef.current = null;
        activeRunRef.current = null;
        flushLines();
        setRunning(false);
        setStopping(false);
        setExitCode(-1);
        appendLine(runId, "stderr", rejection.message);
        finishRun(runId, -1);
        setLaunchError({ message: rejection.message, laneBusy: true });
        playSound("error");
        return;
      }

      // No tool.started ever arrived, so the run never launched - the
      // rejection IS the outcome. Reset to a failed state instead of
      // "still watching" forever.
      if (!startedRef.current) {
        unlistenRef.current?.();
        unlistenRef.current = null;
        activeRunRef.current = null;
        flushLines();
        const message = `Could not start this run: ${rejection.message}`;
        setLines((prev) => [...prev, { stream: "stderr", line: message }]);
        appendLine(runId, "stderr", message);
        setExitCode(-1);
        setRunning(false);
        finishRun(runId, -1);
        setLaunchError({ message, laneBusy: false });
        playSound("error");
        return;
      }

      // tool.started DID arrive: the RPC itself errored mid-flight (a
      // sidecar hiccup) while the tool carries on. Downgrade to `degraded`
      // - a warning line plus a "Stop watching" escape hatch - and keep the
      // subscription up until the run genuinely ends or the dialog unmounts.
      const message = `RPC error: ${rejection.raw} - the tool may still be running; still watching for it to finish.`;
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
   * what actually cancels. The run keeps its live history row (kept current
   * by the background watcher), so it stays visible as running and can be
   * stopped from there even after this dialog lets go of it.
   */
  function stopWatching() {
    const runId = activeRunRef.current;
    unlistenRef.current?.();
    unlistenRef.current = null;
    activeRunRef.current = null;
    stopRequestedRef.current = null;
    flushLines();
    if (runId) {
      const message =
        "Stopped watching this run. It may still be executing - its Run history row below stays live and can stop it.";
      setLines((prev) => [...prev, { stream: "stderr", line: message }]);
      appendLine(runId, "stderr", message);
      watchInBackground(runId);
    }
    setRunning(false);
    setDegraded(false);
    setStopping(false);
  }

  /**
   * Stop requested from a Run history row. The run this dialog is watching
   * goes through stopRun (its sound and cancelled-badge semantics); any
   * other live row - one handed to the background watcher, or launched
   * earlier and still holding the tool lane - is stopped by runId straight
   * through tool.stop, and the background watcher finalizes the row when
   * tool.finished lands.
   */
  function stopRunFromHistory(entry: RunHistoryEntry): Promise<void> {
    if (entry.id === activeRunRef.current) {
      void stopRun();
      return Promise.resolve();
    }
    playSound("thud");
    return rpcCall<ToolStopResult>("tool.stop", { runId: entry.id })
      .then((result) => {
        const line = result?.message ?? "Stop requested.";
        useRunHistoryStore.getState().appendLine(entry.id, "stdout", line);
      })
      .catch((err) => {
        useRunHistoryStore.getState().appendLine(entry.id, "stderr", `Could not stop this run: ${String(err)}`);
      });
  }

  /** Native file picker for a requiresFile field; the typed path remains for manual entry. */
  async function browseForFile() {
    const spec = item.requiresFile;
    if (!spec) return;
    try {
      const selected = await open({ multiple: false, filters: parseWinFormsFilter(spec.Filter) });
      if (typeof selected === "string" && selected) {
        setValues((v) => ({ ...v, [spec.ParamName]: selected }));
        clearFieldError(spec.ParamName);
      }
    } catch {
      // Cancelled, or the dialog plugin isn't permitted in this build - the
      // text field below still works.
    }
  }

  function clearFieldError(name: string) {
    setFieldErrors((prev) => {
      if (!(name in prev)) return prev;
      const next = { ...prev };
      delete next[name];
      return next;
    });
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
    const result = await validate();
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
  const appliedStaticArgs = item.staticArgs
    ? Object.entries(item.staticArgs).filter(([, v]) => v !== false && v !== null)
    : [];

  const overlayTransition: Transition = animationsEnabled ? { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] } : { duration: 0 };
  const panelTransition: Transition = animationsEnabled
    ? { type: "spring", stiffness: 420, damping: 32, mass: 0.9 }
    : { duration: 0 };

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
        initial={animationsEnabled ? { opacity: 0, scale: 0.94, y: 16 } : false}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={animationsEnabled ? { opacity: 0, scale: 0.96, y: 8 } : { opacity: 0 }}
        transition={panelTransition}
      >
        <GlassPanel strong className="tool-run-dialog">
          <div
            ref={panelRef}
            role="dialog"
            aria-modal="true"
            aria-label={item.label}
            tabIndex={-1}
            className="tool-run-dialog__panel"
            onClick={(e) => e.stopPropagation()}
          >
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
              <div className="tool-run-dialog__warning">
                {embedded
                  ? "Select a project in the widget first - this tool requires one."
                  : "Select a project in the title bar first - this tool requires one."}
              </div>
            )}

            {(item.prompts ?? []).length > 0 && (
              <div className="tool-run-dialog__form">
                {(item.prompts ?? []).map((p) => (
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
                          clearFieldError(p.Name);
                        }}
                      />
                    )}
                    {fieldErrors[p.Name] && (
                      <span className="tool-run-dialog__script" style={{ color: "var(--signal-red)" }}>
                        {fieldErrors[p.Name]}
                      </span>
                    )}
                  </label>
                ))}
              </div>
            )}

            {item.requiresFile && (
              <div className="tool-run-dialog__form">
                <label className="tool-run-dialog__field">
                  <span>{item.requiresFile.TypePrompt}</span>
                  <div className="tool-run-dialog__file-row">
                    <input
                      type="text"
                      aria-invalid={item.requiresFile.ParamName in fieldErrors}
                      placeholder={item.requiresFile.Description}
                      value={values[item.requiresFile.ParamName] ?? ""}
                      onChange={(e) => {
                        const paramName = item.requiresFile!.ParamName;
                        setValues((v) => ({ ...v, [paramName]: e.target.value }));
                        clearFieldError(paramName);
                      }}
                    />
                    <Button size="sm" variant="subtle" disabled={running} onClick={() => void browseForFile()}>
                      Browse&hellip;
                    </Button>
                  </div>
                  {fieldErrors[item.requiresFile.ParamName] && (
                    <span className="tool-run-dialog__script" style={{ color: "var(--signal-red)" }}>
                      {fieldErrors[item.requiresFile.ParamName]}
                    </span>
                  )}
                </label>
              </div>
            )}

            {appliedStaticArgs.length > 0 && (
              <div className="tool-run-dialog__static-args" title="Arguments this menu entry always passes">
                <span className="tool-run-dialog__static-args-label">Also applied by this menu entry:</span>
                {appliedStaticArgs.map(([key, val]) => (
                  <code key={key} className="tool-run-dialog__arg-chip">
                    {val === true ? `-${key}` : `-${key} ${String(val)}`}
                  </code>
                ))}
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

            {launchError && (
              <div
                className={clsx(
                  "tool-run-dialog__launch-error",
                  launchError.laneBusy && "tool-run-dialog__launch-error--lane-busy",
                )}
              >
                <span>{launchError.message}</span>
                <div className="tool-run-dialog__launch-error-actions">
                  {launchError.laneBusy && (
                    <Button size="sm" variant="subtle" onClick={() => setHistoryNonce((n) => n + 1)}>
                      Show run history
                    </Button>
                  )}
                  <Button size="sm" variant="ghost" onClick={() => setLaunchError(null)}>
                    Dismiss
                  </Button>
                </div>
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
                key={historyNonce}
                title="Run history"
                defaultOpen={historyNonce > 0}
                actionSlot={<Badge tone={historyCount > 0 ? "accent" : "neutral"}>{historyCount}</Badge>}
                lazyMount
              >
                <div className="tool-run-dialog__history-body">
                  <RunHistoryList onRunAgain={runFromHistory} onStopRun={stopRunFromHistory} busy={running} />
                </div>
              </Expander>
            </div>
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}
