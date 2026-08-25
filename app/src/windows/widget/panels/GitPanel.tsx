import { useEffect, useState } from "react";
import clsx from "clsx";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import { Button } from "../../../components/primitives/Button";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import type { GitActionResult, GitOverview } from "../../../lib/types";
import { GitGraph } from "./GitGraph";
import { BranchIcon } from "./icons";
import "./GitPanel.css";

type GitActionKind = "fetch" | "pull" | "push";

/**
 * Branch/ahead/behind/dirty/stash badges plus fetch/pull/push, and (in the
 * collapsible "Commits" section) the flagship gradient-lane commit graph.
 * The badge row polls the lightweight overview (includeGraph:false) every
 * 4s; the graph polls its own heavier overview (includeGraph:true, a git
 * log spawn + parse) every 6s and ONLY while the section is expanded - both
 * queries are fully disabled (no RPC round trip at all, not even a cheap
 * one) whenever there's no active project or, for the graph, the section
 * is collapsed, per Get-DevKitRepoOverview's own comment on why
 * IncludeGraph exists.
 */
export function GitPanel() {
  const active = useProjectStore((s) => s.active);
  const path = active?.path;

  const [expanded, setExpanded] = useState(true);
  const [actionInFlight, setActionInFlight] = useState<GitActionKind | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [statusIsError, setStatusIsError] = useState(false);

  const { data, refetch: refetchOverview } = usePolledRpc<GitOverview>(
    "git.overview",
    path ? { path, includeGraph: false } : undefined,
    4000,
    !!path,
  );

  const { data: graphOverview, refetch: refetchGraph } = usePolledRpc<GitOverview>(
    "git.overview",
    path && expanded ? { path, includeGraph: true } : undefined,
    6000,
    !!path && expanded,
  );

  useEffect(() => {
    if (!statusMessage) return;
    const t = setTimeout(() => setStatusMessage(null), 5000);
    return () => clearTimeout(t);
  }, [statusMessage]);

  async function runAction(action: GitActionKind) {
    if (!path || actionInFlight) return;
    setActionInFlight(action);
    setStatusMessage(null);
    try {
      const result = await rpcCall<GitActionResult>("git.action", { path, action });
      setStatusMessage(result.LastLine || `git ${action} finished.`);
      setStatusIsError(!result.Success);
      refetchOverview();
      if (expanded) refetchGraph();
    } catch (err) {
      setStatusMessage(err instanceof RpcClientError ? err.message : `git ${action} failed.`);
      setStatusIsError(true);
    } finally {
      setActionInFlight(null);
    }
  }

  if (!active) {
    return (
      <GlassPanel>
        <div className="panel-empty">No project selected.</div>
      </GlassPanel>
    );
  }

  if (!data) {
    return (
      <GlassPanel>
        <div className="panel-empty">Checking repository&hellip;</div>
      </GlassPanel>
    );
  }

  if (!data.IsRepo) {
    return (
      <GlassPanel>
        <div className="panel-empty">{data.Error ?? "Not a git repository."}</div>
      </GlassPanel>
    );
  }

  return (
    <GlassPanel className="git-panel">
      <div className="git-panel__header">
        <div className="git-panel__badges">
          <span className="git-panel__branch-wrap">
            <BranchIcon className="git-panel__branch-icon" />
            <strong className="git-panel__branch" title={data.Branch}>
              {data.Branch}
            </strong>
          </span>
          {!!data.Ahead && <Badge tone="accent">↑{data.Ahead}</Badge>}
          {!!data.Behind && <Badge tone="warning">↓{data.Behind}</Badge>}
          {data.DirtyCount > 0 && <Badge tone="danger">{data.DirtyCount} dirty</Badge>}
          {data.StashCount > 0 && <Badge tone="neutral">{data.StashCount} stash</Badge>}
        </div>
        <div className="git-panel__actions">
          <Button
            size="sm"
            variant="ghost"
            disabled={actionInFlight !== null}
            loading={actionInFlight === "fetch"}
            onClick={() => runAction("fetch")}
          >
            Fetch
          </Button>
          <Button
            size="sm"
            variant="ghost"
            disabled={actionInFlight !== null}
            loading={actionInFlight === "pull"}
            onClick={() => runAction("pull")}
          >
            Pull
          </Button>
          <Button
            size="sm"
            variant="ghost"
            disabled={actionInFlight !== null}
            loading={actionInFlight === "push"}
            onClick={() => runAction("push")}
          >
            Push
          </Button>
        </div>
      </div>

      {statusMessage && (
        <div className={clsx("git-panel__status", statusIsError && "git-panel__status--error")}>
          {statusMessage}
        </div>
      )}

      <button type="button" className="git-panel__commits-toggle" onClick={() => setExpanded((v) => !v)}>
        <span>Commits</span>
        <span className={clsx("git-panel__chevron", expanded && "git-panel__chevron--open")}>&#9656;</span>
      </button>

      {expanded && <GitCommitsSection path={path!} overview={graphOverview} />}
    </GlassPanel>
  );
}

function GitCommitsSection({ path, overview }: { path: string; overview: GitOverview | undefined }) {
  if (!overview) {
    return <div className="git-panel__graph-hint">Loading commit graph&hellip;</div>;
  }
  if (overview.Error) {
    return <div className="git-panel__graph-hint">{overview.Error}</div>;
  }
  if (overview.GraphSkipped) {
    return <div className="git-panel__graph-hint">Commit graph not loaded yet.</div>;
  }
  if (!overview.Graph || overview.Graph.Nodes.length === 0) {
    return <div className="git-panel__graph-hint">No commits yet.</div>;
  }
  return <GitGraph graph={overview.Graph} path={path} />;
}
