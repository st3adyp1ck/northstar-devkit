import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import clsx from "clsx";
import { openUrl } from "@tauri-apps/plugin-opener";
import { asArray } from "../../../../lib/arrays";
import { rpcCall, RpcClientError } from "../../../../lib/ipc";
import { playSound } from "../../../../lib/sounds";
import type { GitCommitDetails, GitCommitFile } from "../../../../lib/types";
import { LabelChips } from "./LabelChip";
import { absoluteTime, plural, relativeTime, splitPath } from "./format";
import { RichText } from "./markdownLite";
import { repoBaseFromItemUrl, selectionKey, type GitHubIssueRow, type GitHubPrRow, type GitSelection } from "./model";
import "./GitDetail.css";

/**
 * Modals that own Escape while they are up. Mirrors useWidgetFlyout's own
 * list: those dialogs listen on `window` without stopping propagation, so
 * without this check one Escape would dismiss the dialog AND collapse this
 * detail out from under it.
 */
const DIALOG_OVERLAY_SELECTOR =
  ".settings-dialog__overlay, .confirm-dialog__overlay, .update-dialog__overlay";

function openExternal(url: string) {
  openUrl(url).catch(() => {
    // best-effort - no in-app fallback if the OS can't hand off to a browser
  });
}

type Tone = "open" | "draft" | "merged" | "closed" | "review-ok" | "review-block" | "review-wait" | "neutral";

function Pill({ tone, children, title }: { tone: Tone; children: ReactNode; title?: string }) {
  return (
    <span className={clsx("git-detail__pill", `git-detail__pill--${tone}`)} title={title}>
      {children}
    </span>
  );
}

/**
 * gh is asked for `--state open`, so every row here IS open - but the JSON
 * carries the fields that would say otherwise on a wider query, and reading
 * them costs nothing. Derived rather than assumed, so a future "show closed
 * too" toggle doesn't silently label a merged PR "Open".
 */
function deriveState(item: GitHubPrRow | GitHubIssueRow): { tone: Tone; label: string } {
  const raw = typeof item.state === "string" ? item.state.toUpperCase() : "";
  if (raw === "MERGED" || item.merged === true) return { tone: "merged", label: "Merged" };
  if (raw === "CLOSED" || (typeof item.closedAt === "string" && item.closedAt)) {
    return { tone: "closed", label: "Closed" };
  }
  if ((item as GitHubPrRow).isDraft) return { tone: "draft", label: "Draft" };
  return { tone: "open", label: "Open" };
}

const REVIEW_TONES: Record<string, { tone: Tone; label: string }> = {
  APPROVED: { tone: "review-ok", label: "Approved" },
  CHANGES_REQUESTED: { tone: "review-block", label: "Changes requested" },
  REVIEW_REQUIRED: { tone: "review-wait", label: "Review required" },
};

interface MetaRow {
  label: string;
  value: ReactNode;
  mono?: boolean;
}

/** Labelled grid - the fix for metadata that used to run on as one comma'd line. */
function MetaGrid({ rows }: { rows: MetaRow[] }) {
  const present = rows.filter((row) => row.value !== null && row.value !== undefined && row.value !== "");
  if (present.length === 0) return null;
  return (
    <dl className="git-detail__meta">
      {present.map((row) => (
        <div key={row.label} className="git-detail__meta-row">
          <dt>{row.label}</dt>
          <dd className={row.mono ? "git-detail__mono" : undefined}>{row.value}</dd>
        </div>
      ))}
    </dl>
  );
}

/**
 * Added/deleted as an actual proportional bar, not two numbers. `scale` lets
 * a per-file bar be sized against the biggest file in the commit rather than
 * against itself, so a 400-line file doesn't look the same as a 2-line one.
 */
function DiffBar({ added, deleted, scale }: { added: number; deleted: number; scale?: number }) {
  const total = added + deleted;
  if (total === 0) return <span className="git-detail__bar git-detail__bar--empty" aria-hidden="true" />;
  const fill = scale && scale > 0 ? Math.max(0.08, Math.min(1, total / scale)) : 1;
  const addShare = (added / total) * 100;
  return (
    <span
      className="git-detail__bar"
      style={{ width: `${fill * 100}%` }}
      aria-label={`${added} added, ${deleted} deleted`}
    >
      <span className="git-detail__bar-add" style={{ width: `${addShare}%` }} />
      <span className="git-detail__bar-del" style={{ width: `${100 - addShare}%` }} />
    </span>
  );
}

function FileRow({ file, scale }: { file: GitCommitFile; scale: number }) {
  const { dir, name } = splitPath(file.Path);
  return (
    <li className="git-detail__file" title={file.Path}>
      <span className="git-detail__file-path">
        {dir && <span className="git-detail__file-dir">{dir}</span>}
        <span className="git-detail__file-name">{name}</span>
      </span>
      {file.IsBinary ? (
        <span className="git-detail__file-binary">binary</span>
      ) : (
        <>
          <span className="git-detail__file-counts">
            <span className="git-detail__added">+{file.Added}</span>
            <span className="git-detail__deleted">-{file.Deleted}</span>
          </span>
          <span className="git-detail__file-bar">
            <DiffBar added={file.Added} deleted={file.Deleted} scale={scale} />
          </span>
        </>
      )}
    </li>
  );
}

/** ---------- commit ---------- */

function CommitBody({ path, hash }: { path: string; hash: string }) {
  const [details, setDetails] = useState<GitCommitDetails | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setDetails(null);
    setError(null);
    rpcCall<GitCommitDetails>("git.commitDetails", { path, hash })
      .then((result) => {
        if (!cancelled) setDetails(result);
      })
      .catch((err) => {
        // A failed CALL is not "commit not found" - say which one it was.
        if (!cancelled) {
          setError(
            err instanceof RpcClientError
              ? `Could not reach the DevKit sidecar: ${err.message}`
              : "Could not load this commit.",
          );
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [path, hash]);

  if (loading) {
    return (
      <div className="git-detail__loading">
        <div className="panel-skeleton-row" />
        <div className="panel-skeleton-row" />
      </div>
    );
  }
  if (error) return <div className="git-detail__error">{error}</div>;
  if (!details) return <div className="git-detail__error">Could not load this commit.</div>;
  if (!details.Found) {
    return <div className="git-detail__error">{details.Error ?? "This commit is no longer in the repository."}</div>;
  }

  const files = asArray<GitCommitFile>(details.Files);
  const largest = files.reduce((max, f) => Math.max(max, f.Added + f.Deleted), 0);
  const when = absoluteTime(details.Date);
  const ago = relativeTime(details.Date);

  return (
    <>
      <MetaGrid
        rows={[
          { label: "Author", value: details.Author },
          { label: "Email", value: details.Email, mono: true },
          { label: "Date", value: when && ago ? `${when} (${ago})` : when ?? ago },
          { label: "Commit", value: details.Hash, mono: true },
        ]}
      />

      <section className="git-detail__section">
        <h4 className="git-detail__section-title">Changes</h4>
        <div className="git-detail__diffstat">
          <span className="git-detail__diffstat-counts">
            <span className="git-detail__added">+{details.Insertions}</span>
            <span className="git-detail__deleted">-{details.Deletions}</span>
          </span>
          <span className="git-detail__diffstat-bar">
            <DiffBar added={details.Insertions} deleted={details.Deletions} />
          </span>
          <span className="git-detail__diffstat-files">
            {details.FilesChanged} {plural(details.FilesChanged, "file")} changed
          </span>
        </div>
      </section>

      {details.Message.trim() && (
        <section className="git-detail__section">
          <h4 className="git-detail__section-title">Message</h4>
          <RichText text={details.Message} />
        </section>
      )}

      {files.length > 0 && (
        <section className="git-detail__section">
          <h4 className="git-detail__section-title">
            Files <span className="git-detail__count">{files.length}</span>
          </h4>
          <ul className="git-detail__files">
            {files.map((file) => (
              <FileRow key={file.Path} file={file} scale={largest} />
            ))}
          </ul>
        </section>
      )}
    </>
  );
}

/** ---------- pull request ---------- */

function PullRequestBody({ item }: { item: GitHubPrRow }) {
  const labels = asArray(item.labels);
  const review = REVIEW_TONES[item.reviewDecision ?? ""];
  const updated = relativeTime(item.updatedAt);

  return (
    <>
      <MetaGrid
        rows={[
          { label: "Author", value: item.author?.login },
          { label: "Updated", value: updated ? `${updated} (${absoluteTime(item.updatedAt)})` : null },
          {
            label: "Branch",
            mono: true,
            value:
              item.headRefName && item.baseRefName ? (
                <span className="git-detail__branches">
                  <span className="git-detail__branch">{item.headRefName}</span>
                  <span className="git-detail__branch-arrow" aria-hidden="true">
                    →
                  </span>
                  <span className="git-detail__branch">{item.baseRefName}</span>
                </span>
              ) : null,
          },
          { label: "Review", value: review ? <Pill tone={review.tone}>{review.label}</Pill> : "No review yet" },
        ]}
      />

      {labels.length > 0 && (
        <section className="git-detail__section">
          <h4 className="git-detail__section-title">Labels</h4>
          <LabelChips labels={labels} />
        </section>
      )}

      {/* `gh pr list` is not asked for `body` (see Get-DevKitGitHubPullRequests) -
          say so plainly rather than rendering an empty description area. */}
      <p className="git-detail__note">
        The description and review thread live on GitHub - open this pull request to read them.
      </p>
    </>
  );
}

/** ---------- issue ---------- */

function IssueBody({ item }: { item: GitHubIssueRow }) {
  const labels = asArray(item.labels);
  const comments = asArray(item.comments).length;
  const updated = relativeTime(item.updatedAt);
  const repoBase = repoBaseFromItemUrl(item.url);
  const body = typeof item.body === "string" ? item.body : "";

  return (
    <>
      <MetaGrid
        rows={[
          { label: "Author", value: item.author?.login },
          { label: "Updated", value: updated ? `${updated} (${absoluteTime(item.updatedAt)})` : null },
          { label: "Comments", value: `${comments} ${plural(comments, "comment")}` },
        ]}
      />

      {labels.length > 0 && (
        <section className="git-detail__section">
          <h4 className="git-detail__section-title">Labels</h4>
          <LabelChips labels={labels} />
        </section>
      )}

      <section className="git-detail__section">
        <h4 className="git-detail__section-title">Description</h4>
        {body.trim() ? (
          <RichText text={body} options={{ repoBase }} />
        ) : (
          <p className="git-detail__note">This issue has no description.</p>
        )}
      </section>
    </>
  );
}

/** ---------- shell ---------- */

function ExpandGlyph({ full }: { full: boolean }) {
  return (
    <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
      {full ? (
        <path
          d="M5 1v4H1M7 11V7h4"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      ) : (
        <path
          d="M1 4.5V1h3.5M11 7.5V11H7.5M1 1l3.5 3.5M11 11L7.5 7.5"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )}
    </svg>
  );
}

interface GitDetailProps {
  /** Active project path - only needed for the commit lookup. */
  path: string | null;
  selection: GitSelection | null;
  onClose: () => void;
  /**
   * False while the Git tray is shut but still mounted: the detail keeps its
   * state, but must not swallow Escape from whatever the user IS looking at.
   */
  keyboardActive: boolean;
}

/**
 * The detail surface for whatever row was last clicked - a commit, a pull
 * request or an issue. Docked at the bottom of the pane by default, and
 * expandable to fill the whole widget window (a portal onto <body>, so it
 * escapes the pane's own clipping and scroll container).
 *
 * Escape unwinds one level at a time: full screen first, then the detail.
 * It is handled in the CAPTURE phase and marks the event handled, because
 * useWidgetFlyout listens for Escape on `window` to close the whole tray and
 * checks `defaultPrevented` - without both, one Escape would collapse the
 * detail AND slam the tray shut.
 */
export function GitDetail({ path, selection, onClose, keyboardActive }: GitDetailProps) {
  const [fullscreen, setFullscreen] = useState(false);

  // A new selection always opens docked; staying full-screen across an
  // unrelated click would hijack the whole window.
  const key = selection ? selectionKey(selection) : null;
  useEffect(() => {
    setFullscreen(false);
  }, [key]);

  useEffect(() => {
    if (!selection || !keyboardActive) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      if (document.querySelector(DIALOG_OVERLAY_SELECTOR)) return;
      // Escape belongs to whatever is running in the embedded shell.
      const target = event.target;
      if (target instanceof Element && target.closest(".terminal-view")) return;
      event.preventDefault();
      event.stopPropagation();
      if (fullscreen) {
        setFullscreen(false);
        playSound("swoosh");
      } else {
        onClose();
        playSound("click");
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [selection, keyboardActive, fullscreen, onClose]);

  if (!selection) return null;

  const isCommit = selection.kind === "commit";
  const item = isCommit ? null : selection.item;
  const state = item ? deriveState(item) : null;
  const url = typeof item?.url === "string" ? item.url : null;

  const identity = isCommit ? selection.shortHash : `#${item!.number}`;
  const title = isCommit ? selection.subject : String(item!.title ?? "");
  const kindLabel = isCommit ? "Commit" : selection.kind === "pr" ? "Pull request" : "Issue";

  function toggleFullscreen() {
    setFullscreen((v) => !v);
    playSound("swoosh");
  }

  const shell = (
    <div className={clsx("git-detail", fullscreen && "git-detail--full")} role="group" aria-label={`${kindLabel} detail`}>
      <header className="git-detail__head">
        <span className={clsx("git-detail__kind", `git-detail__kind--${selection.kind}`)}>{kindLabel}</span>
        <span className="git-detail__identity">{identity}</span>
        <h3 className="git-detail__title" title={title}>
          {title}
        </h3>
        {state && <Pill tone={state.tone}>{state.label}</Pill>}
        <div className="git-detail__actions">
          {url && (
            <button type="button" className="git-detail__btn" onClick={() => openExternal(url)} title="Open on GitHub">
              Open ↗
            </button>
          )}
          <button
            type="button"
            className="git-detail__btn git-detail__btn--icon"
            onClick={toggleFullscreen}
            aria-pressed={fullscreen}
            title={fullscreen ? "Exit full screen (Esc)" : "Expand to full screen"}
          >
            <ExpandGlyph full={fullscreen} />
            <span>{fullscreen ? "Exit full screen" : "Full screen"}</span>
          </button>
          <button
            type="button"
            className="git-detail__close"
            onClick={() => {
              onClose();
              playSound("click");
            }}
            aria-label="Close detail"
            title="Close"
          >
            <svg width="11" height="11" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <path d="M3 3 L9 9 M9 3 L3 9" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            </svg>
          </button>
        </div>
      </header>

      <div className="git-detail__body">
        {isCommit ? (
          path ? (
            <CommitBody path={path} hash={selection.hash} />
          ) : (
            <div className="git-detail__error">No project is active, so this commit can't be looked up.</div>
          )
        ) : selection.kind === "pr" ? (
          <PullRequestBody item={selection.item} />
        ) : (
          <IssueBody item={selection.item} />
        )}
      </div>
    </div>
  );

  if (!fullscreen) return shell;

  return createPortal(
    <div
      className="git-detail__scrim"
      // Clicking the backdrop steps back to the docked detail rather than
      // closing outright - the same one-level-at-a-time rule as Escape.
      onClick={(event) => {
        if (event.target === event.currentTarget) toggleFullscreen();
      }}
    >
      {shell}
    </div>,
    document.body,
  );
}
