import { useMemo, type CSSProperties, type ReactNode } from "react";
import clsx from "clsx";
import { usePolledRpc, type PolledRpcResult } from "../../../hooks/usePolledRpc";
import { asArray } from "../../../lib/arrays";
import { playSound } from "../../../lib/sounds";
import type { GitHubListResult } from "../../../lib/types";
import { LabelChips } from "./git/LabelChip";
import { relativeTime } from "./git/format";
import type { GitHubIssueRow, GitHubPrRow, GitSelection } from "./git/model";
import "./git/GitSections.css";
import "./GitHubPanel.css";

/**
 * Pull requests and issues for the Git tray.
 *
 * These used to render as two stacked sections under the commit graph, each
 * fighting the others for the pane's height; they are now the bodies of two
 * of the tray's three tabs (GitPanel owns the tablist). What did NOT change
 * is where the polls live: `useGitHubLists` is called ONCE, above the tabs,
 * so switching tabs cannot trigger a fetch - the data for all three tabs is
 * already in hand before the reader clicks anything, and the count badges on
 * the unselected tabs stay true.
 *
 * 20s, not the old 15s: each of these is a `gh` process spawn plus a network
 * round trip (623ms measured for github.prs - see Invoke-DevKitRpc.ps1's own
 * note), so two of them at 15s was ~8% duty on the work lane for data that
 * changes on a human timescale. And `enabled` is off entirely whenever the
 * tray is shut, there is no project, or the overview has already PROVED this
 * isn't a git repo - three cases where the spawn could only ever fail.
 */
const GITHUB_POLL_MS = 20000;

export interface GitHubLists {
  prs: PolledRpcResult<GitHubListResult<GitHubPrRow>>;
  issues: PolledRpcResult<GitHubListResult<GitHubIssueRow>>;
  prRows: GitHubPrRow[];
  issueRows: GitHubIssueRow[];
}

/**
 * Both gh-backed lists as one unit, so the caller can render either, both, or
 * neither without changing what is being polled.
 *
 * `live` is the caller's whole health picture folded into one flag - tray
 * open AND a project selected AND not already known to be a non-repo.
 */
export function useGitHubLists(path: string | null, live: boolean): GitHubLists {
  const params = path ? { path } : undefined;
  const enabled = live && !!path;
  const prs = usePolledRpc<GitHubListResult<GitHubPrRow>>("github.prs", params, GITHUB_POLL_MS, enabled);
  const issues = usePolledRpc<GitHubListResult<GitHubIssueRow>>("github.issues", params, GITHUB_POLL_MS, enabled);
  // Memoised because asArray allocates: the PR rows feed buildPrLanes, whose
  // whole point is to run only when the data actually changed. react-query's
  // structural sharing already hands back the identical payload across an
  // unchanged poll, so this keeps that stability all the way to the graph.
  const prRows = useMemo(() => asArray(prs.data?.PullRequests), [prs.data?.PullRequests]);
  const issueRows = useMemo(() => asArray(issues.data?.Issues), [issues.data?.Issues]);
  return { prs, issues, prRows, issueRows };
}

/**
 * The six outcomes a gh-backed list has to keep apart, in the order they're
 * checked. The bug this replaces: both panels read only {data, isLoading},
 * so a FAILED call rendered the same empty list as a repo with genuinely no
 * open PRs. "no project", "not a repo", "still loading", "sidecar down",
 * "gh isn't installed", "not a GitHub repo" and "nothing open" now each say
 * so.
 *
 * Returns null when there is nothing to report and the caller should render
 * its list - so the caller can also ASK, which is how the tab badges know
 * whether their count is a real zero or an unknown.
 */
export function listStateMessage<T>(
  query: PolledRpcResult<GitHubListResult<T>>,
  count: number,
  path: string | null,
  notRepoReason: string | null,
  emptyLabel: string,
): ReactNode | null {
  const data = query.data;
  if (!path) return <div className="git-state">No project selected.</div>;
  if (notRepoReason) return <div className="git-state">{notRepoReason}</div>;
  if (query.pending) {
    return (
      <div className="git-state__skeleton">
        <div className="panel-skeleton-row" />
        <div className="panel-skeleton-row" />
        <div className="panel-skeleton-row" />
      </div>
    );
  }
  if (query.failed) {
    return (
      <div className="git-state git-state--error">
        <span>
          Could not reach the DevKit sidecar.
          {query.errorMessage && <span className="git-state__detail">{query.errorMessage}</span>}
        </span>
      </div>
    );
  }
  if (data && !data.CliInstalled) {
    return (
      <div className="git-state git-state--warn">
        <span>
          GitHub CLI not found.
          <span className="git-state__detail">Install `gh` and sign in to see pull requests and issues here.</span>
        </span>
      </div>
    );
  }
  if (data && !data.IsRepo) {
    return (
      <div className="git-state git-state--warn">
        <span>{data.ErrorMessage ?? "Not a GitHub repository."}</span>
      </div>
    );
  }
  if (count === 0) {
    // A populated ErrorMessage with IsRepo true is gh reporting a real
    // problem (auth, rate limit) - never silently show it as "nothing here".
    return data?.ErrorMessage ? (
      <div className="git-state git-state--warn">
        <span>{data.ErrorMessage}</span>
      </div>
    ) : (
      <div className="git-state">{emptyLabel}</div>
    );
  }
  return null;
}

/** Thin strip over a list carrying the two things that qualify what's under it. */
function ListStatus<T>({ query, count }: { query: PolledRpcResult<GitHubListResult<T>>; count: number }) {
  const truncated = query.data?.Truncated ?? false;
  if (!query.stale && !truncated) return null;
  return (
    <div className="gh-status">
      {query.stale && (
        <span className="git-section__stale" title={query.errorMessage ?? undefined}>
          last known
        </span>
      )}
      {truncated && <span className="git-section__hint">first {count} shown</span>}
    </div>
  );
}

interface ListProps {
  path: string | null;
  notRepoReason: string | null;
  selection: GitSelection | null;
  onSelect: (selection: GitSelection) => void;
}

interface PrListProps extends ListProps {
  query: PolledRpcResult<GitHubListResult<GitHubPrRow>>;
  rows: GitHubPrRow[];
  /** Lane color for a PR that is drawn on the graph, so a row and its ribbon read as one object. */
  laneColor: (number: number) => string | undefined;
  highlightPr: number | null;
  onHighlightPr: (number: number | null) => void;
}

export function PullRequestList({
  query,
  rows,
  path,
  notRepoReason,
  selection,
  onSelect,
  laneColor,
  highlightPr,
  onHighlightPr,
}: PrListProps) {
  const state = listStateMessage(query, rows.length, path, notRepoReason, "No open pull requests.");
  return (
    <div className="gh-pane">
      <ListStatus query={query} count={rows.length} />
      {state ?? (
        <div className="gh-list">
          {rows.map((pr) => (
            <PrRow
              key={pr.number}
              pr={pr}
              color={laneColor(pr.number)}
              selected={selection?.kind === "pr" && selection.item.number === pr.number}
              lit={highlightPr === pr.number}
              onSelect={onSelect}
              onHighlight={onHighlightPr}
            />
          ))}
        </div>
      )}
    </div>
  );
}

interface IssueListProps extends ListProps {
  query: PolledRpcResult<GitHubListResult<GitHubIssueRow>>;
  rows: GitHubIssueRow[];
}

export function IssueList({ query, rows, path, notRepoReason, selection, onSelect }: IssueListProps) {
  const state = listStateMessage(query, rows.length, path, notRepoReason, "No open issues.");
  return (
    <div className="gh-pane">
      <ListStatus query={query} count={rows.length} />
      {state ?? (
        <div className="gh-list">
          {rows.map((issue) => (
            <IssueRow
              key={issue.number}
              issue={issue}
              selected={selection?.kind === "issue" && selection.item.number === issue.number}
              onSelect={onSelect}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function StateDot({ tone, title }: { tone: "open" | "draft"; title: string }) {
  return <span className={clsx("gh-row__dot", `gh-row__dot--${tone}`)} title={title} aria-hidden="true" />;
}

function PrRow({
  pr,
  color,
  selected,
  lit,
  onSelect,
  onHighlight,
}: {
  pr: GitHubPrRow;
  color: string | undefined;
  selected: boolean;
  lit: boolean;
  onSelect: (selection: GitSelection) => void;
  onHighlight: (number: number | null) => void;
}) {
  const labels = asArray(pr.labels);
  const updated = relativeTime(pr.updatedAt);
  const draft = pr.isDraft === true;
  const review = pr.reviewDecision;

  return (
    <button
      type="button"
      className={clsx("gh-row", "gh-row--pr", selected && "gh-row--selected", lit && "gh-row--lit")}
      style={color ? ({ "--pr-color": color } as CSSProperties) : undefined}
      aria-pressed={selected}
      title={pr.title}
      onMouseEnter={() => onHighlight(pr.number)}
      onMouseLeave={() => onHighlight(null)}
      onFocus={() => onHighlight(pr.number)}
      onBlur={() => onHighlight(null)}
      onClick={() => {
        onSelect({ kind: "pr", item: pr });
        playSound("click");
      }}
    >
      {/* The PR's own lane color, when it has one on the graph. Absent means
          exactly that: this PR could not be drawn there. */}
      <span className={clsx("gh-row__wire", !color && "gh-row__wire--none")} aria-hidden="true" />
      <StateDot tone={draft ? "draft" : "open"} title={draft ? "Draft" : "Open"} />
      <span className="gh-row__num">#{pr.number}</span>
      <span className="gh-row__main">
        <span className="gh-row__title">{pr.title}</span>
        <span className="gh-row__sub">
          {pr.headRefName && pr.baseRefName && (
            <span className="gh-row__branches">
              {pr.headRefName} <span aria-hidden="true">→</span> {pr.baseRefName}
            </span>
          )}
          <LabelChips labels={labels} max={3} />
        </span>
      </span>
      <span className="gh-row__meta">
        {review === "CHANGES_REQUESTED" && (
          <span className="gh-row__review gh-row__review--block" title="Changes requested">
            ✗
          </span>
        )}
        {review === "APPROVED" && (
          <span className="gh-row__review gh-row__review--ok" title="Approved">
            ✓
          </span>
        )}
        {pr.author?.login && <span className="gh-row__author">{pr.author.login}</span>}
        {updated && <span className="gh-row__when">{updated}</span>}
      </span>
    </button>
  );
}

function IssueRow({
  issue,
  selected,
  onSelect,
}: {
  issue: GitHubIssueRow;
  selected: boolean;
  onSelect: (selection: GitSelection) => void;
}) {
  const labels = asArray(issue.labels);
  const comments = asArray(issue.comments).length;
  const updated = relativeTime(issue.updatedAt);

  return (
    <button
      type="button"
      className={clsx("gh-row", selected && "gh-row--selected")}
      aria-pressed={selected}
      title={issue.title}
      onClick={() => {
        onSelect({ kind: "issue", item: issue });
        playSound("click");
      }}
    >
      <StateDot tone="open" title="Open" />
      <span className="gh-row__num">#{issue.number}</span>
      <span className="gh-row__main">
        <span className="gh-row__title">{issue.title}</span>
        {labels.length > 0 && (
          <span className="gh-row__sub">
            <LabelChips labels={labels} max={3} />
          </span>
        )}
      </span>
      <span className="gh-row__meta">
        {comments > 0 && (
          <span className="gh-row__comments" title={`${comments} comments`}>
            ￭ {comments}
          </span>
        )}
        {issue.author?.login && <span className="gh-row__author">{issue.author.login}</span>}
        {updated && <span className="gh-row__when">{updated}</span>}
      </span>
    </button>
  );
}
