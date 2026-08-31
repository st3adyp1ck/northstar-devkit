/**
 * Shapes the Git flyout works in, on top of lib/types.ts.
 *
 * The gh CLI's own `--json` output is what github.prs / github.issues return
 * untouched (Get-DevKitGitHubPullRequests / Get-DevKitGitHubIssues in
 * core/DevKit-WidgetCore.ps1 pass the field list straight through
 * ConvertFrom-Json - no PascalCase transform), so these stay camelCase.
 * lib/types.ts's GitHubPullRequest / GitHubIssue cover the fields every
 * consumer needs; the extras below are the ones the PS side actually
 * requests but that the shared file has not been widened to name yet -
 * declared here rather than editing lib/types.ts, which is out of scope for
 * this pass.
 */
import type { GitHubIssue, GitHubPullRequest } from "../../../../lib/types";

/** gh returns `color` as SIX HEX DIGITS WITHOUT a leading '#', e.g. "d73a4a". */
export interface GitHubLabel {
  id?: string;
  name: string;
  description?: string | null;
  color?: string;
}

export interface GitHubPrRow extends GitHubPullRequest {
  isDraft?: boolean;
  headRefName?: string;
  /** Hash of the PR's head commit - the exact, rename-proof anchor resolveHeadNode prefers over the branch name. */
  headRefOid?: string;
  baseRefName?: string;
  updatedAt?: string;
  /** "APPROVED" | "CHANGES_REQUESTED" | "REVIEW_REQUIRED" | "" (gh sends an empty string, not null, when unreviewed). */
  reviewDecision?: string;
  labels?: GitHubLabel[];
}

export interface GitHubIssueRow extends GitHubIssue {
  author?: { login: string };
  labels?: GitHubLabel[];
  body?: string;
  updatedAt?: string;
}

/**
 * What the detail view is currently showing. PR/issue rows are carried by
 * value because github.prs/github.issues return the WHOLE object per row -
 * there is no per-item RPC to re-fetch one, so the poll's own payload is the
 * only source. Commits carry just the hash: git.commitDetails is a separate
 * call (the graph's rows only hold subject-level metadata).
 */
export type GitSelection =
  | { kind: "commit"; hash: string; shortHash: string; subject: string }
  | { kind: "pr"; item: GitHubPrRow }
  | { kind: "issue"; item: GitHubIssueRow };

export function selectionKey(selection: GitSelection): string {
  if (selection.kind === "commit") return `commit:${selection.hash}`;
  return `${selection.kind}:${selection.item.number}`;
}

/**
 * "https://github.com/owner/repo" from an item URL, for turning `#123` and
 * `@mention` inside a body into real links. Returns null for anything that
 * isn't a github.com item URL rather than guessing.
 */
export function repoBaseFromItemUrl(url: string | undefined): string | null {
  if (!url) return null;
  const match = /^(https:\/\/github\.com\/[^/]+\/[^/]+)\//.exec(url);
  return match ? match[1] : null;
}
