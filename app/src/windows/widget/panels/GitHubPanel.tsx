import type { ReactNode } from "react";
import { useState } from "react";
import clsx from "clsx";
import { openUrl } from "@tauri-apps/plugin-opener";
import { usePolledRpc } from "../../../hooks/usePolledRpc";
import { useProjectStore } from "../../../stores/useProjectStore";
import { GlassPanel } from "../../../components/primitives/GlassPanel";
import { Badge } from "../../../components/primitives/Badge";
import type { GitHubListResult, GitHubPullRequest, GitHubIssue } from "../../../lib/types";
import "./GitHubPanel.css";

type Tab = "prs" | "issues";

/**
 * gh CLI's own `--json` output is what these two RPC methods return
 * untouched (Get-DevKitGitHubPullRequests / Get-DevKitGitHubIssues in
 * gui/DevKit-WidgetCore.ps1 pass '--json number,title,author,url,...'
 * straight through ConvertFrom-Json - no PascalCase transform). lib/types.ts's
 * GitHubPullRequest already matches, but GitHubIssue is missing `author`
 * even though the PS source requests it in the same shape as the PR's
 * (`{login: string}`) - extended locally below rather than editing the
 * shared types file out of scope for this pass.
 */
interface GitHubPrRow extends GitHubPullRequest {
  isDraft?: boolean;
}

interface GitHubIssueRow extends GitHubIssue {
  author?: { login: string };
}

function openItem(url: string) {
  openUrl(url).catch(() => {
    // best-effort - no in-app fallback if the OS can't hand off to a browser
  });
}

export function GitHubPanel() {
  const active = useProjectStore((s) => s.active);
  const [tab, setTab] = useState<Tab>("prs");
  const params = active ? { path: active.path } : undefined;
  const { data: prData } = usePolledRpc<GitHubListResult<GitHubPrRow>>("github.prs", params, 15000, !!active);
  const { data: issueData } = usePolledRpc<GitHubListResult<GitHubIssueRow>>(
    "github.issues",
    params,
    15000,
    !!active,
  );

  if (!active) return null;

  const prCount = prData?.PullRequests?.length ?? 0;
  const issueCount = issueData?.Issues?.length ?? 0;

  return (
    <GlassPanel className="github-panel">
      <div className="panel-tabs">
        <button
          type="button"
          className={clsx("panel-tab", tab === "prs" && "panel-tab--active")}
          onClick={() => setTab("prs")}
        >
          Pull Requests
          <Badge tone={tab === "prs" ? "accent" : "neutral"}>{prCount}</Badge>
        </button>
        <button
          type="button"
          className={clsx("panel-tab", tab === "issues" && "panel-tab--active")}
          onClick={() => setTab("issues")}
        >
          Issues
          <Badge tone={tab === "issues" ? "accent" : "neutral"}>{issueCount}</Badge>
        </button>
      </div>

      {tab === "prs" ? (
        <GitHubList
          data={prData}
          items={prData?.PullRequests ?? []}
          emptyLabel="No open pull requests."
          renderRow={(pr) => <PrRow key={pr.number} pr={pr} />}
        />
      ) : (
        <GitHubList
          data={issueData}
          items={issueData?.Issues ?? []}
          emptyLabel="No open issues."
          renderRow={(issue) => <IssueRow key={issue.number} issue={issue} />}
        />
      )}
    </GlassPanel>
  );
}

function GitHubList<T extends { number: number }>({
  data,
  items,
  emptyLabel,
  renderRow,
}: {
  data: GitHubListResult<T> | undefined;
  items: T[];
  emptyLabel: string;
  renderRow: (item: T) => ReactNode;
}) {
  if (!data) {
    return <div className="panel-empty">Loading…</div>;
  }
  if (!data.CliInstalled) {
    return (
      <div className="panel-empty">
        GitHub CLI (gh) not found - install it to see PRs and issues here.
      </div>
    );
  }
  if (!data.IsRepo) {
    return <div className="panel-empty">{data.ErrorMessage ?? "Not a GitHub repository."}</div>;
  }
  if (items.length === 0) {
    return <div className="panel-empty">{data.ErrorMessage ?? emptyLabel}</div>;
  }
  return (
    <>
      <div className="github-panel__list">{items.map(renderRow)}</div>
      {data.Truncated && <div className="github-panel__truncated">Showing first {items.length}.</div>}
    </>
  );
}

function PrRow({ pr }: { pr: GitHubPrRow }) {
  const author = pr.author?.login;
  return (
    <button type="button" className="github-panel__row" onClick={() => openItem(pr.url)} title={pr.title}>
      <span className="github-panel__number">#{pr.number}</span>
      <span className="github-panel__title">{pr.title}</span>
      {pr.isDraft && (
        <Badge tone="neutral" className="github-panel__flag">
          Draft
        </Badge>
      )}
      {author && <span className="github-panel__author">{author}</span>}
    </button>
  );
}

function IssueRow({ issue }: { issue: GitHubIssueRow }) {
  const author = issue.author?.login;
  const commentCount = issue.comments?.length ?? 0;
  return (
    <button type="button" className="github-panel__row" onClick={() => openItem(issue.url)} title={issue.title}>
      <span className="github-panel__number">#{issue.number}</span>
      <span className="github-panel__title">{issue.title}</span>
      {commentCount > 0 && (
        <Badge tone="neutral" className="github-panel__flag">
          {commentCount} comment{commentCount === 1 ? "" : "s"}
        </Badge>
      )}
      {author && <span className="github-panel__author">{author}</span>}
    </button>
  );
}
