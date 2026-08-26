import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import clsx from "clsx";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { useSettingsStore } from "../../../stores/useSettingsStore";
import { Badge } from "../../../components/primitives/Badge";
import { Button } from "../../../components/primitives/Button";
import { asArray } from "../../../lib/arrays";
import { rpcCall, RpcClientError } from "../../../lib/ipc";
import { playSound } from "../../../lib/sounds";
import type { GitActionResult, GitDirtyFile, GitOverview } from "../../../lib/types";
import { IssueList, PullRequestList, useGitHubLists } from "./GitHubPanel";
import { GitDetail } from "./git/GitDetail";
import { GitTabs, panelId, tabId, type GitTabDef } from "./git/GitTabs";
import { PrGraph } from "./git/PrGraph";
import { useOnScreen } from "./git/paneVisibility";
import { plural, prettyRemote, splitPath } from "./git/format";
import { activeAccentHex } from "./git/prLaneColors";
import { buildPrLanes } from "./git/prLanes";
import type { GitHubIssueRow, GitHubPrRow, GitSelection } from "./git/model";
import { BranchIcon } from "./icons";
import "./git/GitSections.css";
import "./GitPanel.css";

type GitActionKind = "fetch" | "pull" | "push";
type GitTabId = "graph" | "prs" | "issues";

const TAB_PREFIX = "git";

/**
 * ONE poll for the whole pane, at 6s, with the graph always included.
 *
 * This used to be two overlapping queries: a 4s badge poll
 * (includeGraph:false, 150-200ms) plus a 6s graph poll (includeGraph:true,
 * 250-420ms). The graph result is a strict SUPERSET of the badge result -
 * same branch, same ahead/behind, same dirty and stash counts - so the cheap
 * one was buying nothing the expensive one wasn't already fetching two
 * seconds later. Per minute that was 15 x ~175ms + 10 x ~335ms = ~6.0s of
 * git-lane time; one 6s poll is ~3.4s, a 44% cut, and the graph's own
 * freshness is unchanged. The badges go from 4s to 6s stale in the worst
 * case, which is well inside the time it takes to look at them.
 *
 * And it stops entirely when the tray is shut (see git/paneVisibility.ts) or
 * no project is active - previously the graph poll ran forever once the
 * section had been expanded, because the flyout keeps its panes mounted.
 */
const OVERVIEW_POLL_MS = 6000;

/** Porcelain XY status -> what it means and which tone says so. */
function dirtyKind(status: string): { code: string; label: string; tone: string } {
  const raw = (status || "").trim();
  const head = raw[0] ?? "?";
  if (raw === "??") return { code: "?", label: "untracked", tone: "new" };
  if (raw.includes("U") || raw === "AA" || raw === "DD") return { code: "!", label: "conflicted", tone: "conflict" };
  switch (head) {
    case "A":
      return { code: "A", label: "added", tone: "add" };
    case "D":
      return { code: "D", label: "deleted", tone: "del" };
    case "R":
      return { code: "R", label: "renamed", tone: "move" };
    case "C":
      return { code: "C", label: "copied", tone: "move" };
    default:
      return { code: "M", label: "modified", tone: "mod" };
  }
}

/**
 * The Git flyout: everything about this repo on one surface.
 *
 * The repo header - branch, ahead/behind, working tree, Fetch/Pull/Push - is
 * PERSISTENT, because it is the context for all three views underneath it.
 * The three views are real tabs rather than the stacked sections this
 * replaced: a graph, a PR list and an issue list competing for one scroller
 * meant each got roughly a third of the pane and none of them was usable,
 * and the graph is the one that most wants the height.
 *
 * Both gh polls and the git.overview poll live HERE, above the tablist, so
 * switching tabs never refetches anything and the counts on the tabs you are
 * not looking at stay true.
 */
export function GitPanel() {
  const rootRef = useRef<HTMLDivElement>(null);
  const onScreen = useOnScreen(rootRef);
  const active = useProjectStore((s) => s.active);
  const path = active?.path ?? null;

  const [selection, setSelection] = useState<GitSelection | null>(null);
  const [tab, setTab] = useState<GitTabId>("graph");
  /**
   * The PR whose lane is lit, wherever the pointer happens to be - a legend
   * chip, a commit row on its ribbon, or a row in the PR tab. Held here
   * rather than inside the graph so the link survives a tab switch: light a
   * PR in the list, move to Graph, and its ribbon is already the lit one.
   */
  const [hoveredPr, setHoveredPr] = useState<number | null>(null);
  const [actionInFlight, setActionInFlight] = useState<GitActionKind | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [statusIsError, setStatusIsError] = useState(false);
  const [showDirty, setShowDirty] = useState(false);

  const overview = usePolledRpc<GitOverview>(
    "git.overview",
    path ? { path, includeGraph: true } : undefined,
    OVERVIEW_POLL_MS,
    !!path && onScreen,
  );
  const { refetch } = overview;
  const data = overview.data;

  // Everything below distinguishes "we know it isn't a repo" from "we don't
  // know yet" from "we couldn't ask" - the three states this pane used to
  // render identically as a permanent "Checking repository…".
  const isRepo = data?.IsRepo === true;
  const knownNotRepo = data !== undefined && data.IsRepo === false;
  const notRepoReason = knownNotRepo ? data.Error ?? "Not a git repository." : null;
  const dirtyFiles = asArray<GitDirtyFile>(data?.DirtyFiles);
  const graph = data?.Graph ?? null;

  const lists = useGitHubLists(path, onScreen && !notRepoReason);
  const { prs, issues, prRows, issueRows } = lists;

  // Lane hues rotate off the LIVE accent so they stay distinguishable in all
  // ten themes; read from settings rather than the DOM - see prLaneColors.ts.
  const appTheme = useSettingsStore((s) => s.settings?.preferences.appTheme);
  const accentColor = useSettingsStore((s) => s.settings?.preferences.accentColor);
  const accentHex = useMemo(() => activeAccentHex(appTheme, accentColor), [appTheme, accentColor]);

  const prLanes = useMemo(() => buildPrLanes(graph, prRows, accentHex), [graph, prRows, accentHex]);
  /**
   * A PR carries its lane color into the PR list only if the Graph tab has
   * SOMETHING of it - a ribbon along its commits, an arc into its base, or
   * at least a legend chip standing for one. A PR with neither end in the
   * log gets no color, and its row shows an empty channel instead: the list
   * must not imply a lane the graph cannot show.
   */
  const drawnLaneColors = useMemo(
    () =>
      new Map(
        prLanes
          .filter((lane) => lane.path.length > 0 || lane.baseLane !== null)
          .map((lane) => [lane.number, lane.color]),
      ),
    [prLanes],
  );
  const laneColor = useCallback((number: number) => drawnLaneColors.get(number), [drawnLaneColors]);

  // A detail is about a commit/PR/issue in ONE repo. Switching projects (or
  // to the "None" option) must not leave the previous repo's row open
  // underneath the new one's sections. The chosen TAB deliberately survives:
  // it is a preference about this pane, not a fact about that repo.
  useEffect(() => {
    setSelection(null);
    setShowDirty(false);
    setHoveredPr(null);
  }, [path]);

  useEffect(() => {
    if (!statusMessage) return;
    const timer = setTimeout(() => setStatusMessage(null), 6000);
    return () => clearTimeout(timer);
  }, [statusMessage]);

  // The detail view holds the row object it was opened with, because these
  // RPCs return whole items and there is no per-item lookup to re-read one.
  // So when a poll brings back a changed version of the row that is CURRENTLY
  // open, hand it forward - otherwise a PR's review decision or an issue's
  // comment count would freeze at whatever it was when it was clicked.
  // react-query's structural sharing returns the identical object when
  // nothing changed, so this settles after one pass instead of looping.
  useEffect(() => {
    if (!selection || selection.kind === "commit") return;
    const rows: (GitHubPrRow | GitHubIssueRow)[] = selection.kind === "pr" ? prRows : issueRows;
    const fresh = rows.find((row) => row.number === selection.item.number);
    if (!fresh || fresh === selection.item) return;
    setSelection(
      selection.kind === "pr"
        ? { kind: "pr", item: fresh as GitHubPrRow }
        : { kind: "issue", item: fresh as GitHubIssueRow },
    );
  }, [prRows, issueRows, selection]);

  const clearSelection = useCallback(() => setSelection(null), []);
  const selectPr = useCallback((pr: GitHubPrRow) => {
    setSelection({ kind: "pr", item: pr });
    playSound("click");
  }, []);
  const selectCommit = useCallback((node: { hash: string; shortHash: string; subject: string }) => {
    playSound("click");
    setSelection((current) =>
      current?.kind === "commit" && current.hash === node.hash
        ? null
        : { kind: "commit", hash: node.hash, shortHash: node.shortHash, subject: node.subject },
    );
  }, []);

  /**
   * Clicking a PR anywhere LATCHES its lane lit - that is the "clicking one
   * highlights the other" half, and it has to outlive the pointer or the
   * link would vanish on the way to the other tab. Hovering wins while it
   * lasts, so pointing at a second PR still previews it.
   */
  const highlightPr = hoveredPr ?? (selection?.kind === "pr" ? selection.item.number : null);

  const prNote = useMemo(
    () => prOverlayNote(prs.pending, prs.failed, prs.data?.CliInstalled, prs.errorMessage),
    [prs.pending, prs.failed, prs.data?.CliInstalled, prs.errorMessage],
  );

  async function runAction(action: GitActionKind) {
    if (!path || actionInFlight) return;
    setActionInFlight(action);
    setStatusMessage(null);
    try {
      const result = await rpcCall<GitActionResult>("git.action", { path, action });
      setStatusMessage(result.LastLine || `git ${action} finished.`);
      setStatusIsError(!result.Success);
      playSound(result.Success ? "success" : "error");
      refetch();
    } catch (err) {
      setStatusMessage(err instanceof RpcClientError ? err.message : `git ${action} failed.`);
      setStatusIsError(true);
      playSound("error");
    } finally {
      setActionInFlight(null);
    }
  }

  if (!active) {
    return (
      <div ref={rootRef} className="git-pane git-pane--placeholder">
        <div className="git-pane__placeholder">
          <BranchIcon className="git-pane__placeholder-icon" width={20} height={20} />
          <p className="git-pane__placeholder-title">No project selected</p>
          <p className="git-pane__placeholder-body">
            Pick a project in the title bar and its branch state, commit graph, pull requests and issues appear here.
          </p>
        </div>
      </div>
    );
  }

  const commitCount = graph ? asArray(graph.Nodes).length : null;
  const tabs: GitTabDef<GitTabId>[] = [
    {
      id: "graph",
      label: "Graph",
      badge: commitCount === null ? null : String(commitCount),
    },
    {
      id: "prs",
      label: "Pull requests",
      // No badge at all until the call has answered: a "0" on a tab whose
      // query is still in flight (or just failed) claims an empty list.
      badge: prs.data ? `${prRows.length}${prs.data.Truncated ? "+" : ""}` : null,
      tone: prs.failed ? "error" : prRows.length > 0 ? "live" : undefined,
    },
    {
      id: "issues",
      label: "Issues",
      badge: issues.data ? `${issueRows.length}${issues.data.Truncated ? "+" : ""}` : null,
      tone: issues.failed ? "error" : issueRows.length > 0 ? "live" : undefined,
    },
  ];

  return (
    <div ref={rootRef} className="git-pane">
      {/* ---------- repository: persistent context for all three tabs ---------- */}
      <section className="git-pane__header">
        <div className="git-section__head">
          <h3 className="git-section__title">Repository</h3>
          <div className="git-section__aside">
            {overview.stale && (
              <span className="git-section__stale" title={overview.errorMessage ?? undefined}>
                last known
              </span>
            )}
            {data?.RemoteUrl && (
              <span className="git-section__hint" title={data.RemoteUrl}>
                {prettyRemote(data.RemoteUrl)}
              </span>
            )}
          </div>
        </div>

        {overview.pending && (
          <div className="git-state__skeleton">
            <div className="panel-skeleton-row" />
            <div className="panel-skeleton-row" />
          </div>
        )}

        {overview.failed && (
          <div className="git-state git-state--error">
            <span>
              Could not reach the DevKit sidecar, so this repo's state is unknown.
              {overview.errorMessage && <span className="git-state__detail">{overview.errorMessage}</span>}
            </span>
          </div>
        )}

        {knownNotRepo && (
          <div className="git-state git-state--warn">
            <span>
              {notRepoReason}
              <span className="git-state__detail">{active.path}</span>
            </span>
          </div>
        )}

        {isRepo && data && (
          <>
            <div className="git-pane__repo">
              <span className="git-pane__branch-wrap" title={data.Branch}>
                <BranchIcon className="git-pane__branch-icon" />
                <strong className="git-pane__branch">{data.Branch}</strong>
              </span>
              <span className="git-pane__badges">
                {!!data.Ahead && <Badge tone="accent">↑{data.Ahead}</Badge>}
                {!!data.Behind && <Badge tone="warning">↓{data.Behind}</Badge>}
                {data.StashCount > 0 && (
                  <Badge tone="neutral">
                    {data.StashCount} {plural(data.StashCount, "stash", "stashes")}
                  </Badge>
                )}
                {data.Ahead === null && data.Behind === null && (
                  <span className="git-section__hint">no upstream</span>
                )}
              </span>
              <div className="git-pane__actions">
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

            {dirtyFiles.length > 0 ? (
              <div className="git-pane__dirty">
                <button
                  type="button"
                  className="git-pane__dirty-toggle"
                  aria-expanded={showDirty}
                  onClick={() => setShowDirty((v) => !v)}
                >
                  <span className={clsx("git-pane__chevron", showDirty && "git-pane__chevron--open")} aria-hidden="true">
                    ▸
                  </span>
                  <span className="git-pane__dirty-count">{data.DirtyCount}</span>
                  <span>uncommitted {plural(data.DirtyCount, "change")}</span>
                </button>
                {showDirty && (
                  <ul className="git-pane__dirty-list">
                    {dirtyFiles.map((file) => {
                      const kind = dirtyKind(file.Status);
                      const { dir, name } = splitPath(file.Path);
                      return (
                        <li key={`${file.Status}-${file.Path}`} className="git-pane__dirty-row" title={`${kind.label}: ${file.Path}`}>
                          <span className={clsx("git-pane__dirty-code", `git-pane__dirty-code--${kind.tone}`)}>
                            {kind.code}
                          </span>
                          <span className="git-pane__dirty-path">
                            {dir && <span className="git-pane__dirty-dir">{dir}</span>}
                            <span className="git-pane__dirty-name">{name}</span>
                          </span>
                        </li>
                      );
                    })}
                  </ul>
                )}
              </div>
            ) : (
              <div className="git-pane__clean">Working tree clean.</div>
            )}

            {statusMessage && (
              <div className={clsx("git-pane__status", statusIsError && "git-pane__status--error")}>
                {statusMessage}
              </div>
            )}
          </>
        )}
      </section>

      <GitTabs tabs={tabs} active={tab} onChange={setTab} idPrefix={TAB_PREFIX} label="Git views" />

      {/* Only the selected panel is mounted: all three read data that already
          lives above this component, so mounting costs a render, never a
          fetch - and keeping two hidden scrollers alive buys nothing. */}
      <div
        className="git-pane__panel"
        role="tabpanel"
        id={panelId(TAB_PREFIX, tab)}
        aria-labelledby={tabId(TAB_PREFIX, tab)}
        tabIndex={0}
      >
        {tab === "graph" && (
          <GraphTab
            overview={overview}
            graph={graph}
            graphSkipped={data?.GraphSkipped === true}
            knownNotRepo={knownNotRepo}
            notRepoReason={notRepoReason}
            lanes={prLanes}
            prNote={prNote}
            selection={selection}
            onSelectCommit={selectCommit}
            onSelectPr={selectPr}
            highlightPr={highlightPr}
            onHighlightPr={setHoveredPr}
          />
        )}

        {tab === "prs" && (
          <PullRequestList
            query={prs}
            rows={prRows}
            path={path}
            notRepoReason={notRepoReason}
            selection={selection}
            onSelect={setSelection}
            laneColor={laneColor}
            highlightPr={highlightPr}
            onHighlightPr={setHoveredPr}
          />
        )}

        {tab === "issues" && (
          <IssueList
            query={issues}
            rows={issueRows}
            path={path}
            notRepoReason={notRepoReason}
            selection={selection}
            onSelect={setSelection}
          />
        )}
      </div>

      <GitDetail path={path} selection={selection} onClose={clearSelection} keyboardActive={onScreen} />
    </div>
  );
}

/**
 * What the Graph tab says when the PR overlay is missing for a reason other
 * than "there are no open PRs". Silence is only correct for the last case -
 * a graph with no ribbons because github.prs FAILED would read as a repo
 * with nothing in flight.
 */
function prOverlayNote(
  pending: boolean,
  failed: boolean,
  cliInstalled: boolean | undefined,
  errorMessage: string | null,
): ReactNode | null {
  if (pending) return <div className="git-state">Looking for open pull requests to draw…</div>;
  if (failed) {
    return (
      <div className="git-state git-state--error">
        <span>
          Pull requests could not be loaded, so none are drawn here.
          {errorMessage && <span className="git-state__detail">{errorMessage}</span>}
        </span>
      </div>
    );
  }
  if (cliInstalled === false) {
    return <div className="git-state">GitHub CLI not found - pull requests aren't drawn on this graph.</div>;
  }
  return null;
}

function GraphTab({
  overview,
  graph,
  graphSkipped,
  knownNotRepo,
  notRepoReason,
  lanes,
  prNote,
  selection,
  onSelectCommit,
  onSelectPr,
  highlightPr,
  onHighlightPr,
}: {
  overview: { pending: boolean; failed: boolean };
  graph: GitOverview["Graph"];
  graphSkipped: boolean;
  knownNotRepo: boolean;
  notRepoReason: string | null;
  lanes: ReturnType<typeof buildPrLanes>;
  prNote: ReactNode | null;
  selection: GitSelection | null;
  onSelectCommit: (node: { hash: string; shortHash: string; subject: string }) => void;
  onSelectPr: (pr: GitHubPrRow) => void;
  highlightPr: number | null;
  onHighlightPr: (number: number | null) => void;
}) {
  if (knownNotRepo) {
    return (
      <div className="git-state git-state--warn">
        <span>{notRepoReason}</span>
      </div>
    );
  }
  if (overview.pending) {
    return (
      <div className="git-state__skeleton">
        <div className="panel-skeleton-row" />
        <div className="panel-skeleton-row" />
        <div className="panel-skeleton-row" />
      </div>
    );
  }
  if (overview.failed) {
    return <div className="git-state">The commit graph needs the sidecar - it will draw itself once it answers.</div>;
  }
  if (graphSkipped) {
    // Only reachable if something ever calls this pane's query with
    // includeGraph:false again; kept honest rather than silent.
    return <div className="git-state">Commit graph was not collected on this refresh.</div>;
  }
  if (!graph || asArray(graph.Nodes).length === 0) {
    return <div className="git-state">No commits yet.</div>;
  }
  return (
    <PrGraph
      graph={graph}
      lanes={lanes}
      selectedHash={selection?.kind === "commit" ? selection.hash : null}
      onSelectCommit={onSelectCommit}
      onSelectPr={onSelectPr}
      highlightPr={highlightPr}
      onHighlightPr={onHighlightPr}
      prNote={prNote ?? undefined}
    />
  );
}
