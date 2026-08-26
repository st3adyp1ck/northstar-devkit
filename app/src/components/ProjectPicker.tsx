import { useState } from "react";
import { createPortal } from "react-dom";
import { AnimatePresence } from "framer-motion";
import { open } from "@tauri-apps/plugin-dialog";
import clsx from "clsx";
import { useProjectStore } from "../stores/useProjectStore";
import {
  ensureProjectsLoaded,
  notifyProjectsChanged,
  useEnsureProjects,
  useProjectManagerStore,
} from "./projects/ensureProjects";
import { ProjectManagerDialog } from "./projects/ProjectManagerDialog";
import "./ProjectPicker.css";

function ManageIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <line x1="9" y1="6" x2="20" y2="6" />
      <line x1="9" y1="12" x2="20" y2="12" />
      <line x1="9" y1="18" x2="20" y2="18" />
      <circle cx="4.5" cy="6" r="1.4" />
      <circle cx="4.5" cy="12" r="1.4" />
      <circle cx="4.5" cy="18" r="1.4" />
    </svg>
  );
}

export interface ProjectPickerProps {
  /** Extra class on the picker root, for hosts that need their own sizing. */
  className?: string;
  /** Set false to drop the Manage button (the dialog can still be opened from the palette). */
  showManage?: boolean;
}

/**
 * The app's project affordance: pick the active project, link a new folder,
 * or open the manager. Every prop is optional, so the widget's `<ProjectPicker />`
 * still renders exactly what it always did.
 *
 * Mounted in BOTH windows' TitleBars now. It used to live only in the
 * widget, and because each Tauri window is a separate webview with its own
 * zustand stores, that left the Control Center's project store empty
 * forever - which permanently disabled Run for every `requiresProject`
 * tool in the catalog. Loading now goes through ensureProjectsLoaded()
 * rather than this component's mount effect, so no single component is
 * load-bearing for the store having data (see projects/ensureProjects.ts).
 *
 * The empty-string option is "None" - no project scope, so cleanup and
 * other machine-wide tools run without one. It reuses "" rather than a
 * sentinel id because `active?.id ?? ""` already maps a null active project
 * onto it and linked-project ids are GUIDs, which "" can never collide with.
 */
export function ProjectPicker({ className, showManage = true }: ProjectPickerProps = {}) {
  const { active, linked, setActive, clearActive, addProject } = useProjectStore();
  const managerOpen = useProjectManagerStore((s) => s.open);
  const openManager = useProjectManagerStore((s) => s.openManager);
  const closeManager = useProjectManagerStore((s) => s.closeManager);
  const [error, setError] = useState<string | null>(null);

  useEnsureProjects();

  async function browse() {
    setError(null);
    try {
      const dir = await open({ directory: true, multiple: false });
      if (typeof dir === "string") {
        await addProject(dir);
        notifyProjectsChanged();
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function choose(id: string) {
    setError(null);
    try {
      if (id) await setActive(id);
      else await clearActive();
      notifyProjectsChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  const hasProjects = linked.length > 0;
  // The registry stores one nullable activeProjectId, so "deliberately
  // unscoped" and "never picked one" are the same row on disk - and mean the
  // same thing to every tool. Both render as None; only having nothing linked
  // at all is a genuinely different state, and it gets its own look.
  const isNone = hasProjects && !active;

  return (
    <div className={clsx("devkit-project-picker", className)}>
      <div className="devkit-project-picker__select-wrap">
        <select
          className={clsx(
            "devkit-project-picker__select",
            active?.Missing && "devkit-project-picker__select--missing",
            isNone && "devkit-project-picker__select--none",
            !hasProjects && "devkit-project-picker__select--empty",
          )}
          aria-label="Active project"
          title={
            active
              ? active.path
              : hasProjects
                ? "None - no project scope. System and maintenance tools run machine-wide."
                : "No linked projects yet - use + to link a folder."
          }
          value={active?.id ?? ""}
          onChange={(e) => void choose(e.target.value)}
        >
          {hasProjects ? (
            <option value="">None - system tools only</option>
          ) : (
            <option value="" disabled>
              No linked projects
            </option>
          )}
          {linked.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
              {p.Missing ? " (missing)" : ""}
            </option>
          ))}
        </select>
      </div>
      <button type="button" className="devkit-project-picker__browse" onClick={browse} title="Link a project folder">
        +
      </button>
      {showManage && (
        <button
          type="button"
          className="devkit-project-picker__browse"
          aria-label="Manage linked projects"
          title="Manage linked projects"
          onClick={() => {
            void ensureProjectsLoaded(true);
            openManager();
          }}
        >
          <ManageIcon />
        </button>
      )}
      {error && (
        <span className="devkit-project-picker__error" role="status" title={error}>
          {error}
        </span>
      )}
      {/* Portalled to <body> so the dialog's fixed overlay can never be
          clipped or re-anchored by the TitleBar flex row it's rendered
          from (a transformed/blurred ancestor would become its containing
          block otherwise). */}
      {createPortal(
        <AnimatePresence>{managerOpen && <ProjectManagerDialog onClose={closeManager} />}</AnimatePresence>,
        document.body,
      )}
    </div>
  );
}
