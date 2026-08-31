import { useEffect, useRef, useState } from "react";
import { useSettingsStore } from "../../../stores/useSettingsStore";
import { useProjectStore } from "../../../stores/useProjectStore";
import { useRunHistoryStore, type RunHistoryEntry } from "../../../stores/useRunHistoryStore";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useConfirmDestructive } from "../../../hooks/useConfirmDestructive";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Button } from "../../../components/primitives/Button";
import { Badge } from "../../../components/primitives/Badge";
import { Expander } from "../../../components/primitives/Expander";
import { RunHistoryList } from "../../../components/history/RunHistoryList";
import { ToolConsole } from "../../../components/ToolConsole";
import { BoltIcon } from "./icons";
import { startWidgetToolRun, stopWatchingWidgetRun, useWidgetToolRun } from "./widgetToolRun";
import type { EnvDrift } from "../../../lib/types";
import "./QuickActionsPanel.css";

/**
 * The panel is two actions now, so they are described rather than merely
 * labelled - with one button per row there is room to say what it does, and
 * a one-click end-of-day wipe is exactly the kind of thing that should not
 * rely on the owner remembering what the word on it means.
 */
const DOCTOR = {
  label: "Doctor",
  caption: "Full environment check - reads only, changes nothing.",
  folder: "diagnostics",
  script: "DevKit-Doctor.ps1",
  args: [] as string[],
};

/**
 * ASSUMPTION, to be confirmed against the close-out tool's own manifest:
 * tools/workflow/Close-OutSession.ps1, no required parameters, `-DryRun`
 * for the preview (the repo-wide convention - Docker-Cleanup, Git-Cleanup,
 * Copy-EnvTemplate and the rest all spell it that way) and a `-Force` that
 * the sidecar appends itself when `confirmed` is passed.
 *
 * Nothing here hardcodes `-Force` into `args`, and that is deliberate: a
 * `-Force` passed to a script that does not declare one is a hard
 * parameter-binding error under `pwsh -File`, which is precisely how the
 * old Clear NPM Cache button managed to fail every single time it was
 * pressed. Sending `confirmed: true` instead lets the sidecar decide from
 * the script's own AST, so this button works whether or not the tool ends
 * up declaring the switch.
 */
const CLOSE_OUT = {
  label: "Close-Out",
  caption: "End the day's session - stops the dev processes and frees the ports they held.",
  folder: "workflow",
  script: "Close-OutSession.ps1",
  args: [] as string[],
  previewArgs: ["-DryRun"],
};

/**
 * Deep Close-Out is the SAME script, not a second tool: the two everyday
 * opt-ins (-IncludeRecycleBin, -IncludePackageCache) ride along as plain
 * args, and the active project (when one is linked) is appended at click
 * time as -ProjectPath so its regenerable framework caches go too. The
 * manifest's own Deep entry (tools/workflow/_module.psd1, item 8) passes
 * the same two switches but deliberately leaves the project out - a
 * catalog item cannot know which project is active; this panel can.
 */
const CLOSE_OUT_DEEP = {
  label: "Close-Out (deep)",
  args: ["-IncludeRecycleBin", "-IncludePackageCache"] as string[],
};

/* ------------------------------------------------------------------ */
/* collapsed/expanded preference                                       */
/* ------------------------------------------------------------------ */

/**
 * Whether the actions section is expanded, remembered across remounts.
 *
 * localStorage rather than a settings key on purpose: every DevKitPreferences
 * key also needs a default in the PowerShell Get-DevKitSettings backfill and
 * rides the cross-window settings broadcast, which is a lot of machinery for
 * a per-view disclosure toggle that nothing else in the app reads. The run
 * history sitting right below this panel already persists the same way.
 *
 * Absent key means expanded, so nobody's panel silently folds up on upgrade.
 */
const OPEN_STORAGE_KEY = "devkit.quickActions.actionsOpen.v1";

/** Even reaching for `window.localStorage` throws when site data is blocked. */
function readOpenPreference(): boolean {
  try {
    return window.localStorage?.getItem(OPEN_STORAGE_KEY) !== "0";
  } catch {
    return true;
  }
}

function writeOpenPreference(open: boolean): void {
  try {
    window.localStorage?.setItem(OPEN_STORAGE_KEY, open ? "1" : "0");
  } catch {
    // Site data blocked - the section just comes back expanded next mount.
  }
}

/**
 * Quick Actions panel: two deliberate, full-width primary actions - Doctor
 * and Close-Out - plus the streamed inline console, the env-drift banner,
 * and the widget's window onto tool run history. Everything that acts on a
 * node process or a port now lives in the Node & Ports panel, next to the
 * data it acts on.
 *
 * Both actions stream their output into an inline console (ToolConsole,
 * shared with the Control Center's ToolRunDialog) instead of firing and
 * forgetting. The in-flight guard is shared with Node & Ports via
 * widgetToolRun - see that module for why one guard covers both panels.
 * All settings UI (animations, confirm destructive, update checks, widget
 * dock) lives in the Settings dialog opened from the title bar - the
 * settings store is only read here for the env-drift silence list.
 *
 * The buttons and the console live in a collapsible section so the panel can
 * be folded down to two header rows in a narrow dock. What stays OUTSIDE the
 * collapse is deliberate: the env-drift warning (an alert nobody should be
 * able to hide by accident) and the run status in the section header, so a
 * run in flight is visible whether the section is open or shut.
 */
export function QuickActionsPanel() {
  const { settings, refresh, update } = useSettingsStore();
  const active = useProjectStore((s) => s.active);
  const linked = useProjectStore((s) => s.linked);
  const confirmDestructive = useConfirmDestructive();
  const historyCount = useRunHistoryStore((s) => s.entries.length);

  const run = useWidgetToolRun();
  const { runId, label: runningLabel, surface, lines, exitCode, degraded, launchError } = run;
  /** This panel's own transcript - a Node & Ports run belongs on that panel. */
  const mine = surface === "quick-actions";
  /** Something is running, but it isn't ours: say so rather than just going grey. */
  const blockedBy = runningLabel && !mine ? runningLabel : null;

  const sectionRef = useRef<HTMLDivElement | null>(null);
  const [sectionOpen] = useState(readOpenPreference);

  /**
   * Expander owns its open state and exposes no onToggle, and it is a shared
   * primitive several other surfaces render, so it is not ours to widen.
   * Watching its trigger's aria-expanded is the least invasive way to persist
   * the choice - that attribute is the primitive's own public state, so this
   * stays correct for pointer, keyboard, and anything Expander grows later.
   *
   * Scoped to the trigger inside this wrapper only. The Run history expander
   * is a sibling with an aria-expanded of its own and must not be recorded
   * against this key.
   */
  useEffect(() => {
    const trigger = sectionRef.current?.querySelector(".devkit-expander__trigger");
    if (!trigger) return;
    const observer = new MutationObserver(() => {
      writeOpenPreference(trigger.getAttribute("aria-expanded") === "true");
    });
    observer.observe(trigger, { attributeFilter: ["aria-expanded"] });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const envDriftParams = active ? { path: active.path } : undefined;
  const { data: envDrift, failed: driftFailed } = usePolledRpc<EnvDrift | null>(
    "env.drift",
    envDriftParams,
    15000,
    !!active,
  );
  const silenced = settings?.preferences.envDriftSilencedProjects ?? [];
  const showDriftBanner = !!active && !!envDrift && envDrift.Missing.length > 0 && !silenced.includes(active.id);

  function runDoctor() {
    if (runId) return;
    void startWidgetToolRun({
      surface: "quick-actions",
      folder: DOCTOR.folder,
      script: DOCTOR.script,
      label: DOCTOR.label,
      args: DOCTOR.args,
    });
  }

  /**
   * The preview is the whole reason a one-click wipe is clickable at all, so
   * it takes no confirm gate and - crucially - never sends `confirmed`, which
   * is what keeps the sidecar from appending -Force to a run that is supposed
   * to change nothing.
   */
  function previewCloseOut() {
    if (runId) return;
    void startWidgetToolRun({
      surface: "quick-actions",
      folder: CLOSE_OUT.folder,
      script: CLOSE_OUT.script,
      label: `${CLOSE_OUT.label} (preview)`,
      args: CLOSE_OUT.previewArgs,
    });
  }

  function runCloseOut() {
    if (runId) return;
    confirmDestructive(
      {
        title: "Close out the day's session?",
        description: (
          <>
            Runs <code>{`${CLOSE_OUT.folder}/${CLOSE_OUT.script}`}</code> with every prompt pre-answered: it ends the
            dev processes this session started and frees the ports they were holding. Anything unsaved in those
            processes is lost, DevKit cannot cancel a tool once it starts, and none of it can be undone.
            <br />
            Not sure? Cancel and hit <strong>Preview</strong> first - same tool, dry run, nothing touched.
          </>
        ),
        confirmLabel: "Close out",
        danger: true,
      },
      () =>
        startWidgetToolRun({
          surface: "quick-actions",
          folder: CLOSE_OUT.folder,
          script: CLOSE_OUT.script,
          label: CLOSE_OUT.label,
          args: CLOSE_OUT.args,
          caution: true,
          // The user just came through the caution dialog, which is the only
          // thing that earns -Force. See widgetToolRun's WidgetRunSpec.
          confirmed: true,
        }),
    );
  }

  /**
   * Same gate as runCloseOut - the extras (a PERMANENT Recycle Bin empty, a
   * slower next install while the package cache refills, the active
   * project's framework caches) are exactly the kind of thing a one-click
   * button must say out loud before it does them.
   */
  function runDeepCloseOut() {
    if (runId) return;
    // Resolved BEFORE the dialog opens so the copy and the run agree on
    // whether a project is going along.
    const args = active ? [...CLOSE_OUT_DEEP.args, "-ProjectPath", active.path] : CLOSE_OUT_DEEP.args;
    confirmDestructive(
      {
        title: "Deep close out the day's session?",
        description: (
          <>
            Runs <code>{`${CLOSE_OUT.folder}/${CLOSE_OUT.script}`}</code> like the button above, plus: empties the{" "}
            <strong>Recycle Bin (permanent)</strong> and cleans the package manager&apos;s global cache (the next
            install in any project will be slower)
            {active
              ? ", and clears the active project's framework caches (.next, .turbo, node_modules/.cache, node_modules/.vite - never node_modules itself, never dist)"
              : ""}
            . Anything unsaved in the stopped processes is lost, and none of it can be undone.
          </>
        ),
        confirmLabel: "Deep close out",
        danger: true,
      },
      () =>
        startWidgetToolRun({
          surface: "quick-actions",
          folder: CLOSE_OUT.folder,
          script: CLOSE_OUT.script,
          label: CLOSE_OUT_DEEP.label,
          args,
          caution: true,
          confirmed: true,
        }),
    );
  }

  /** Replays a recorded run. RunHistoryList has already applied the caution gate. */
  function runFromHistory(entry: RunHistoryEntry) {
    void startWidgetToolRun({
      surface: "quick-actions",
      folder: entry.folder,
      script: entry.script,
      label: entry.label,
      args: entry.args,
      caution: entry.caution,
      // A caution entry has just been re-confirmed by RunHistoryList's own
      // gate, so the replay is entitled to the same -Force the original run
      // got - which matters because that -Force lives in the sidecar, not in
      // the recorded args, and a replay without it would sit at a prompt no
      // one can answer.
      confirmed: entry.caution,
    });
  }

  async function silenceDrift() {
    if (!active || silenced.includes(active.id)) return;
    await update({ envDriftSilencedProjects: [...silenced, active.id] });
  }

  /**
   * The one thing that has to survive collapsing: whether a tool is running.
   * Expander renders actionSlot in its header, which is on screen in both
   * states, so this doubles as the collapsed-state summary. Idle with no
   * history renders nothing - with two buttons on screen, a badge counting
   * them to "2" was pure noise.
   */
  const statusSlot = runningLabel ? (
    <Badge tone={mine ? "accent" : "neutral"} className="quick-actions-panel__running">
      <span className="quick-actions-panel__running-dot" aria-hidden="true" />
      <span className="quick-actions-panel__running-label">{runningLabel}</span>
    </Badge>
  ) : mine && exitCode !== null ? (
    <Badge tone={exitCode === 0 ? "success" : "danger"}>exit {exitCode}</Badge>
  ) : null;

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

      {/* env.drift never succeeded and the last attempt failed: saying nothing
          would read as "no drift", which is the exact lie usePolledRpc's
          `failed` flag exists to stop panels telling. */}
      {!!active && driftFailed && <div className="quick-actions-panel__drift-unknown">Couldn&apos;t check .env drift.</div>}

      <div className="quick-actions-panel__section" ref={sectionRef}>
        <Expander title="Actions" actionSlot={<span role="status">{statusSlot}</span>} defaultOpen={sectionOpen}>
          <div className="quick-actions-panel__section-body">
            <div className="quick-actions-panel__actions">
              <Button
                variant="primary"
                className="quick-actions-panel__big"
                disabled={!!runId}
                loading={mine && runningLabel === DOCTOR.label}
                onClick={runDoctor}
                title="Runs DevKit-Doctor.ps1 - checks every tool, runtime, and config it can see. Reads only, changes nothing."
              >
                <span className="quick-actions-panel__big-text">
                  <span className="quick-actions-panel__big-label">{DOCTOR.label}</span>
                  <span className="quick-actions-panel__big-caption">{DOCTOR.caption}</span>
                </span>
              </Button>

              <div className="quick-actions-panel__close-out">
                <Button
                  variant="danger"
                  className="quick-actions-panel__big"
                  disabled={!!runId}
                  loading={mine && runningLabel === CLOSE_OUT.label}
                  onClick={runCloseOut}
                  title="Runs Close-OutSession.ps1 - stops dev processes, frees their ports, clears temp/junk, and trims memory. Always asks for confirmation first."
                >
                  <span className="quick-actions-panel__big-text">
                    <span className="quick-actions-panel__big-label">{CLOSE_OUT.label}</span>
                    <span className="quick-actions-panel__big-caption">{CLOSE_OUT.caption}</span>
                  </span>
                </Button>
                <div className="quick-actions-panel__close-out-options">
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={!!runId}
                    loading={mine && runningLabel === CLOSE_OUT_DEEP.label}
                    onClick={runDeepCloseOut}
                    title="Same clean, plus the Recycle Bin, the package manager cache, and the active project's framework caches"
                  >
                    Deep
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    disabled={!!runId}
                    loading={mine && runningLabel === `${CLOSE_OUT.label} (preview)`}
                    onClick={previewCloseOut}
                    title="Dry run - lists what Close-Out would do without doing any of it"
                  >
                    Preview first
                  </Button>
                </div>
              </div>
            </div>

            {/* Both buttons are grey because the single sidecar tool lane is
                busy with someone else's run - which is not the same thing as
                "this panel is broken". */}
            {blockedBy && <div className="quick-actions-panel__blocked">Waiting for {blockedBy} to finish.</div>}

            {mine && launchError && (
              <div className="quick-actions-panel__launch-error">
                {launchError}
                <span className="quick-actions-panel__launch-hint">
                  Nothing ran - the sidecar rejected the request before starting anything. If the script is missing,
                  it belongs in the tools folder under the name above.
                </span>
              </div>
            )}

            {mine && (runId || lines.length > 0) && (
              <div className="quick-actions-panel__console">
                <ToolConsole lines={lines} className="tool-console--compact" />
                {degraded && (
                  <span className="quick-actions-panel__degraded">
                    Run request errored - still watching. DevKit can&apos;t cancel a running tool.
                  </span>
                )}
                <div className="quick-actions-panel__console-footer">
                  {exitCode !== null && !runId && (
                    <span className={exitCode === 0 ? "quick-actions-panel__exit-ok" : "quick-actions-panel__exit-err"}>exit {exitCode}</span>
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
        </Expander>
      </div>

      <div className="quick-actions-panel__history">
        <Expander
          title="Run history"
          actionSlot={<Badge tone={historyCount > 0 ? "accent" : "neutral"}>{historyCount}</Badge>}
          lazyMount
        >
          <div className="quick-actions-panel__history-body">
            <RunHistoryList compact maxRows={20} busy={!!runId} onRunAgain={runFromHistory} />
          </div>
        </Expander>
      </div>

      {/* None is now a thing the owner can deliberately pick, so an absent
          project is no longer automatically a nag. Both actions here are
          machine-wide - it's the OTHER panels that need a scope - so this
          states the situation rather than implying something is wrong. */}
      {!active && (
        <div className="panel-empty" style={{ marginTop: "var(--space-1)" }}>
          {linked.length > 0
            ? "Project: None - these actions run machine-wide. Pick a project for per-project tools."
            : "No projects linked yet - these actions run machine-wide regardless."}
        </div>
      )}
    </GlassPanel>
  );
}
