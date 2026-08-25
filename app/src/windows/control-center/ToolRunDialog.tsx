import { useEffect, useRef, useState } from "react";
import { motion, type Transition } from "framer-motion";
import { rpcCall, onToolRun } from "../../lib/ipc";
import { useProjectStore } from "../../stores/useProjectStore";
import { useConfirmDestructive } from "../../hooks/useConfirmDestructive";
import { Button } from "../../components/primitives/Button";
import { GlassPanel } from "../../components/primitives/GlassPanel";
import { Badge } from "../../components/primitives/Badge";
import type { CatalogItem, CatalogModule } from "../../lib/types";
import "./ToolRunDialog.css";

interface ToolRunDialogProps {
  module: CatalogModule;
  item: CatalogItem;
  onClose: () => void;
}

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
  const consoleRef = useRef<HTMLDivElement>(null);
  const unlistenRef = useRef<(() => void) | null>(null);
  const reducedMotion = usePrefersReducedMotion();
  const confirmDestructive = useConfirmDestructive();

  useEffect(() => {
    consoleRef.current?.scrollTo({ top: consoleRef.current.scrollHeight });
  }, [lines]);

  // Unsubscribe from any in-flight run's events if the dialog closes
  // mid-run (e.g. the user hits Close while output is still streaming) -
  // without this, the tool.output listener for that runId outlives the
  // dialog and just accumulates with every run.
  useEffect(() => {
    return () => {
      unlistenRef.current?.();
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

  async function executeRun(args: string[]) {
    setLines([]);
    setExitCode(null);
    setRunning(true);
    const runId = crypto.randomUUID();
    try {
      const unlisten = await onToolRun(runId, {
        onOutput: (stream, line) => setLines((prev) => [...prev, { stream, line }]),
        onFinished: (code) => {
          setExitCode(code);
          setRunning(false);
          unlisten();
          unlistenRef.current = null;
        },
      });
      unlistenRef.current = unlisten;
      await rpcCall("tool.run", { folder: module.folder, script: item.script, args, runId });
    } catch (err) {
      setLines((prev) => [...prev, { stream: "stderr", line: String(err) }]);
      setRunning(false);
      unlistenRef.current?.();
      unlistenRef.current = null;
    }
  }

  async function run() {
    const result = validate();
    if (!result.ok) {
      setFieldErrors(result.errors);
      return;
    }
    setFieldErrors({});

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
        () => executeRun(result.args),
      );
    } else {
      await executeRun(result.args);
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
              {exitCode !== null && (
                <Badge tone={exitCode === 0 ? "success" : "danger"}>exit {exitCode}</Badge>
              )}
            </div>

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
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}
