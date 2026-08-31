import { useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { rpcCall } from "../../../lib/ipc";
import { asArray } from "../../../lib/arrays";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { FolderIcon } from "./icons";
import type { DirChild, DirChildrenResult } from "../../../lib/types";
import { useOnScreen } from "./git/paneVisibility";
import "./FilesPanel.css";

/**
 * Lazy-expanding directory tree, one level per "files.children" call (see
 * Get-DevKitDirChildren in core/DevKit-WidgetCore.ps1 - deliberately
 * non-recursive). The root level is polled like the other panels; every
 * folder expanded below it is fetched once on first expand and cached in
 * local state so collapsing/re-expanding never re-fetches. A level that
 * FAILED is not cached that way - see handleToggle.
 *
 * Known gaps left for a later pass: no new-file/new-folder actions, no
 * open-in-editor on double click (both were noted on the old stub but are
 * outside this pass's scope).
 */

const CODE_EXT = new Set([
  "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts", "py", "ps1", "psm1", "psd1",
  "rs", "go", "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hpp", "cs", "rb",
  "php", "sh", "bash", "bat", "cmd", "sql", "lua", "swift", "vue", "svelte", "html",
  "htm", "css", "scss", "less", "graphql", "r", "m", "scala", "dart", "ex", "exs",
  "clj", "hs", "fs", "fsx",
]);

const CONFIG_EXT = new Set([
  "json", "jsonc", "yaml", "yml", "toml", "ini", "env", "xml", "conf", "config",
  "cfg", "props", "lock", "plist",
]);

const CONFIG_NAMES = new Set([
  "dockerfile", "makefile", ".gitignore", ".gitattributes", ".editorconfig",
  ".npmrc", ".env", ".prettierrc", ".eslintrc",
]);

/** Folder / code file / config file / generic file - a deliberately small icon set, not a full type map. */
function fileIcon(name: string): string {
  const lower = name.toLowerCase();
  if (CONFIG_NAMES.has(lower)) return "⚙️"; // gear
  const dot = name.lastIndexOf(".");
  if (dot > 0) {
    const ext = lower.slice(dot + 1);
    if (CODE_EXT.has(ext)) return "📜"; // scroll
    if (CONFIG_EXT.has(ext)) return "⚙️"; // gear
  }
  return "📄"; // page
}

interface TreeController {
  childrenByPath: Record<string, DirChild[]>;
  errorByPath: Record<string, string>;
  expandedPaths: Record<string, boolean>;
  loadingPaths: Record<string, boolean>;
  onToggle: (node: DirChild) => void;
}

function TreeNode({ node, depth, ctl }: { node: DirChild; depth: number; ctl: TreeController }) {
  const isExpanded = !!ctl.expandedPaths[node.FullName];
  const isLoading = !!ctl.loadingPaths[node.FullName];
  const error = ctl.errorByPath[node.FullName];
  const kids = ctl.childrenByPath[node.FullName];

  return (
    <div>
      <div
        className={clsx("files-panel__row", node.IsDirectory && "files-panel__row--dir")}
        onClick={() => node.IsDirectory && ctl.onToggle(node)}
        style={{ paddingLeft: 6 + depth * 14 }}
        title={node.FullName}
      >
        <span className="files-panel__caret">{node.IsDirectory ? (isExpanded ? "▾" : "▸") : ""}</span>
        <span className="files-panel__icon">{node.IsDirectory ? (isExpanded ? "📂" : "📁") : fileIcon(node.Name)}</span>
        <span className="files-panel__name">{node.Name}</span>
        {isLoading && <span className="files-panel__loading-inline">...</span>}
      </div>
      {isExpanded && error && (
        <div className="files-panel__row-note files-panel__row-note--danger" style={{ paddingLeft: 6 + (depth + 1) * 14 }}>
          {error}
        </div>
      )}
      {isExpanded &&
        !error &&
        (kids ?? []).map((child) => <TreeNode key={child.FullName} node={child} depth={depth + 1} ctl={ctl} />)}
      {isExpanded && !error && kids && kids.length === 0 && (
        <div className="files-panel__row-note" style={{ paddingLeft: 6 + (depth + 1) * 14 }}>
          Empty
        </div>
      )}
    </div>
  );
}

export function FilesPanel() {
  const active = useProjectStore((s) => s.active);
  // Same shut-tray gating as GitPanel/NotesOnDeckPanel: the tray keeps this
  // pane mounted while hidden, and mounted must not mean a 15s directory
  // scan nobody can see.
  const rootRef = useRef<HTMLDivElement>(null);
  const onScreen = useOnScreen(rootRef);
  const {
    data: root,
    pending: rootPending,
    failed: rootFailed,
    stale: rootStale,
    errorMessage: rootRpcError,
  } = usePolledRpc<DirChildrenResult>("files.children", active ? { path: active.path } : undefined, 15000, !!active && onScreen);

  const [childrenByPath, setChildrenByPath] = useState<Record<string, DirChild[]>>({});
  const [errorByPath, setErrorByPath] = useState<Record<string, string>>({});
  const [expandedPaths, setExpandedPaths] = useState<Record<string, boolean>>({});
  const [loadingPaths, setLoadingPaths] = useState<Record<string, boolean>>({});

  // A different project (or unlinking) invalidates every cached path below the old root.
  useEffect(() => {
    setChildrenByPath({});
    setErrorByPath({});
    setExpandedPaths({});
    setLoadingPaths({});
  }, [active?.path]);

  async function handleToggle(node: DirChild) {
    const path = node.FullName;
    if (expandedPaths[path]) {
      setExpandedPaths((prev) => ({ ...prev, [path]: false }));
      // Successful reads stay cached, but a failed one is forgotten on
      // collapse: unlike the polled root, a child level is fetched exactly
      // once, so a cached error would outlive the sidecar outage that
      // caused it and this folder would claim to be unreadable forever.
      setErrorByPath((prev) => {
        if (!(path in prev)) return prev;
        const next = { ...prev };
        delete next[path];
        return next;
      });
      return;
    }
    setExpandedPaths((prev) => ({ ...prev, [path]: true }));
    if (childrenByPath[path] || errorByPath[path]) return; // already cached

    setLoadingPaths((prev) => ({ ...prev, [path]: true }));
    try {
      const result = await rpcCall<DirChildrenResult>("files.children", { path });
      if (result.Error) {
        setErrorByPath((prev) => ({ ...prev, [path]: result.Error as string }));
      } else {
        setChildrenByPath((prev) => ({ ...prev, [path]: result.Children }));
      }
    } catch (err) {
      setErrorByPath((prev) => ({ ...prev, [path]: err instanceof Error ? err.message : String(err) }));
    } finally {
      setLoadingPaths((prev) => ({ ...prev, [path]: false }));
    }
  }

  if (!active) return null;

  const ctl: TreeController = { childrenByPath, errorByPath, expandedPaths, loadingPaths, onToggle: handleToggle };
  // Wire-shape guard: a folder holding exactly one entry can arrive as a
  // bare object instead of a 1-element list (lib/arrays.ts). `root` itself
  // stays the "did an answer arrive at all" test, since a normalized [] is
  // indistinguishable from never having asked.
  const rootChildren = asArray(root?.Children);

  return (
    <GlassPanel>
      <div ref={rootRef} className="panel-header">
        <span className="panel-header__icon">
          <FolderIcon />
        </span>
        <h2 className="panel-header__title">Files</h2>
        {rootStale && <span className="panel-header__hint files-panel__stale">last known — sidecar not answering</span>}
        {root && !root.Error && (
          <div className="panel-header__actions">
            <Badge tone="neutral">{rootChildren.length}</Badge>
          </div>
        )}
      </div>
      {rootPending && (
        <div className="files-panel__skeleton">
          <div className="panel-skeleton-row" />
          <div className="panel-skeleton-row" />
          <div className="panel-skeleton-row" />
        </div>
      )}
      {/* Two different failures, deliberately worded apart: `root.Error` is
          the sidecar telling us it couldn't read the directory (denied,
          gone), while `rootFailed` is the sidecar not answering at all.
          Neither may fall through to the blank body this panel used to
          render, which read as a project with no files in it. */}
      {rootFailed && (
        <div className="panel-empty panel-empty--danger" role="alert">
          Couldn&apos;t read this folder{rootRpcError ? ` - ${rootRpcError}` : "."}
        </div>
      )}
      {root?.Error && <div className="panel-empty panel-empty--danger">{root.Error}</div>}
      {root && !root.Error && rootChildren.length === 0 && <div className="panel-empty">Empty folder.</div>}
      {root && !root.Error && rootChildren.length > 0 && (
        <div className="files-panel__tree">
          {rootChildren.map((child) => (
            <TreeNode key={child.FullName} node={child} depth={0} ctl={ctl} />
          ))}
        </div>
      )}
    </GlassPanel>
  );
}
