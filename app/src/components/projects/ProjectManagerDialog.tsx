import { useEffect, useMemo, useRef, useState } from "react";
import { motion, useReducedMotion, type Transition } from "framer-motion";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import clsx from "clsx";
import { rpcCall } from "../../lib/ipc";
import { asArray } from "../../lib/arrays";
import { playSound } from "../../lib/sounds";
import { useProjectStore } from "../../stores/useProjectStore";
import { useConfirmDestructive } from "../../hooks/useConfirmDestructive";
import { ensureProjectsLoaded, notifyProjectsChanged } from "./ensureProjects";
import { Button } from "../primitives/Button";
import { Badge } from "../primitives/Badge";
import { GlassPanel } from "../primitives/GlassPanel";
import type { LinkedProject } from "../../lib/types";
import "./ProjectManagerDialog.css";

function PinIcon({ filled }: { filled: boolean }) {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill={filled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M12 17v5" />
      <path d="M9 10.76V4h6v6.76a2 2 0 0 0 .58 1.4L17 13.6V17H7v-3.4l1.42-1.44A2 2 0 0 0 9 10.76Z" />
    </svg>
  );
}

function describeError(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

interface ProjectManagerDialogProps {
  onClose: () => void;
}

/**
 * The missing half of the linked-projects feature. The sidecar has always
 * implemented projects.remove / projects.rename / projects.setPinned /
 * projects.repair (see core/RpcMethods.ps1) and nothing in the app called
 * any of them, so a project linked to the wrong folder - or one whose
 * folder moved - was permanent and un-fixable from the UI.
 *
 * Same overlay/GlassPanel/spring family as ConfirmDialog and ToolRunDialog,
 * one z-layer BELOW ConfirmDialog (see the CSS) so the Remove confirm
 * prompt lands on top of this rather than behind it.
 *
 * Every mutation RPC here returns the whole updated registry, so each one
 * normalizes with asArray for instant local feedback and then refreshes the
 * shared project store - the store re-reads projects.getActive too, which
 * matters because removing or repairing a project can change which one is
 * active (Remove-DevKitLinkedProject clears activeProjectId when it removes
 * the active entry).
 */
export function ProjectManagerDialog({ onClose }: ProjectManagerDialogProps) {
  const linked = useProjectStore((s) => s.linked);
  const active = useProjectStore((s) => s.active);
  const refresh = useProjectStore((s) => s.refresh);
  const confirmDestructive = useConfirmDestructive();
  const reducedMotion = useReducedMotion();

  const [rows, setRows] = useState<LinkedProject[]>(linked);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");
  const renameRef = useRef<HTMLInputElement>(null);

  // Opening the manager is exactly the moment to re-read the registry: the
  // Missing flags are computed server-side from Test-Path, so a folder that
  // vanished since the window opened only shows up on a fresh call.
  useEffect(() => {
    void ensureProjectsLoaded(true);
  }, []);

  useEffect(() => {
    setRows(linked);
  }, [linked]);

  useEffect(() => {
    if (renamingId) renameRef.current?.focus();
  }, [renamingId]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key !== "Escape") return;
      // A rename in progress owns Escape (the input's own handler cancels it
      // and stops propagation before this ever sees it). The Unlink confirm
      // renders ABOVE this dialog and has no Escape of its own, so closing
      // here would strand it over a vanished list - let it be dismissed on
      // its own terms first.
      if (document.querySelector(".confirm-dialog__overlay")) return;
      onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const sorted = useMemo(
    () => [...rows].sort((a, b) => Number(b.pinned) - Number(a.pinned) || a.name.localeCompare(b.name)),
    [rows],
  );

  /**
   * Runs one registry mutation. `fn` must resolve to the updated project
   * list the sidecar returns; anything else (a bare object from a
   * single-entry registry, a null from an emptied one) is normalized by
   * asArray before it reaches state.
   */
  async function mutate(id: string, label: string, fn: () => Promise<unknown>): Promise<void> {
    setBusyId(id);
    setError(null);
    try {
      const result = await fn();
      setRows(asArray(result as LinkedProject[] | LinkedProject | null));
      await refresh();
      notifyProjectsChanged();
    } catch (err) {
      playSound("error");
      setError(`${label} failed: ${describeError(err)}`);
    } finally {
      setBusyId(null);
    }
  }

  function togglePin(project: LinkedProject) {
    void mutate(project.id, "Pin", () =>
      rpcCall<LinkedProject[]>("projects.setPinned", { id: project.id, pinned: !project.pinned }),
    );
  }

  function startRename(project: LinkedProject) {
    setRenamingId(project.id);
    setRenameValue(project.name);
  }

  function commitRename(project: LinkedProject) {
    const name = renameValue.trim();
    setRenamingId(null);
    if (!name || name === project.name) return;
    void mutate(project.id, "Rename", () => rpcCall<LinkedProject[]>("projects.rename", { id: project.id, name }));
  }

  async function repair(project: LinkedProject) {
    setError(null);
    let picked: string | string[] | null;
    try {
      picked = await openDialog({
        directory: true,
        multiple: false,
        title: `Locate "${project.name}"`,
      });
    } catch (err) {
      playSound("error");
      setError(`Couldn't open the folder picker: ${describeError(err)}`);
      return;
    }
    if (typeof picked !== "string") return; // cancelled
    await mutate(project.id, "Repair", () =>
      rpcCall<LinkedProject[]>("projects.repair", { id: project.id, newPath: picked as string }),
    );
  }

  function remove(project: LinkedProject) {
    confirmDestructive(
      {
        title: "Unlink project?",
        description: (
          <>
            Remove <strong>{project.name}</strong> from DevKit's linked projects? The folder itself is left alone -
            only the link, its tags, and its usage history go away.
          </>
        ),
        confirmLabel: "Unlink",
        danger: true,
      },
      () => mutate(project.id, "Unlink", () => rpcCall<LinkedProject[]>("projects.remove", { id: project.id })),
    );
  }

  const overlayTransition: Transition = reducedMotion ? { duration: 0 } : { duration: 0.18, ease: [0.2, 0.8, 0.2, 1] };
  const panelTransition: Transition = reducedMotion
    ? { duration: 0 }
    : { type: "spring", stiffness: 420, damping: 32, mass: 0.9 };

  return (
    <motion.div
      className="project-manager__overlay devkit-no-drag"
      onClick={onClose}
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={overlayTransition}
      role="presentation"
    >
      <motion.div
        className="project-manager__positioner"
        initial={reducedMotion ? false : { opacity: 0, scale: 0.94, y: 16 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: 0.96, y: 8 }}
        transition={panelTransition}
      >
        <GlassPanel strong className="project-manager" padded={false}>
          <div
            className="project-manager__inner"
            role="dialog"
            aria-modal="true"
            aria-label="Linked projects"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="project-manager__header">
              <div>
                <div className="project-manager__title">Linked Projects</div>
                <div className="project-manager__subtitle">
                  {sorted.length === 1 ? "1 project" : `${sorted.length} projects`} linked to DevKit
                </div>
              </div>
              <Button size="sm" variant="ghost" onClick={onClose}>
                Close
              </Button>
            </div>

            {error && <div className="project-manager__error">{error}</div>}

            {sorted.length === 0 ? (
              <div className="project-manager__empty">
                No projects linked yet. Use the <strong>+</strong> button next to the project picker to link a folder.
              </div>
            ) : (
              <ul className="project-manager__list">
                {sorted.map((project) => {
                  const busy = busyId === project.id;
                  const isActive = active?.id === project.id;
                  return (
                    <li
                      key={project.id}
                      className={clsx(
                        "project-manager__row",
                        project.Missing && "project-manager__row--missing",
                        isActive && "project-manager__row--active",
                      )}
                    >
                      <button
                        type="button"
                        className={clsx("project-manager__pin", project.pinned && "project-manager__pin--on")}
                        aria-pressed={project.pinned}
                        title={project.pinned ? "Unpin" : "Pin"}
                        disabled={busy}
                        onClick={() => togglePin(project)}
                      >
                        <PinIcon filled={project.pinned} />
                      </button>

                      <div className="project-manager__body">
                        <div className="project-manager__name-row">
                          {renamingId === project.id ? (
                            <input
                              ref={renameRef}
                              className="project-manager__rename-input"
                              value={renameValue}
                              aria-label={`Rename ${project.name}`}
                              onChange={(e) => setRenameValue(e.target.value)}
                              onBlur={() => commitRename(project)}
                              onKeyDown={(e) => {
                                if (e.key === "Enter") {
                                  e.preventDefault();
                                  commitRename(project);
                                } else if (e.key === "Escape") {
                                  // Cancel the rename without also closing
                                  // the dialog behind it.
                                  e.stopPropagation();
                                  setRenamingId(null);
                                }
                              }}
                            />
                          ) : (
                            <button
                              type="button"
                              className="project-manager__name"
                              title="Click to rename"
                              disabled={busy}
                              onClick={() => startRename(project)}
                            >
                              {project.name}
                            </button>
                          )}
                          {isActive && <Badge tone="accent">Active</Badge>}
                          {project.Missing && <Badge tone="danger">Missing</Badge>}
                          {asArray(project.tags).map((tag) => (
                            <Badge key={tag} tone="neutral">
                              {tag}
                            </Badge>
                          ))}
                        </div>
                        <div className="project-manager__path" title={project.path}>
                          {project.path}
                        </div>
                      </div>

                      <div className="project-manager__actions">
                        {project.Missing && (
                          <Button size="sm" variant="primary" loading={busy} onClick={() => void repair(project)}>
                            Locate...
                          </Button>
                        )}
                        <Button size="sm" variant="ghost" disabled={busy} onClick={() => startRename(project)}>
                          Rename
                        </Button>
                        <Button size="sm" variant="danger" disabled={busy} onClick={() => remove(project)}>
                          Unlink
                        </Button>
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </GlassPanel>
      </motion.div>
    </motion.div>
  );
}
