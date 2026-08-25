import { memo, useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { rpcCall } from "../../../lib/ipc";
import type { GitGraph as GitGraphData, GitCommitDetails } from "../../../lib/types";
import "./GitGraph.css";

/** Caps the per-row draw-in stagger so a long history doesn't take forever to finish animating in. */
const MAX_STAGGER_ROWS = 14;
const STAGGER_STEP_MS = 16;

const ROW_H = 32;
const LANE_W = 16;
const NODE_R = 5;
const PAD_X = 10;
const TEXT_GAP = 10;
const MAX_REFS = 3;

interface GitGraphProps {
  graph: GitGraphData;
  path: string;
}

/**
 * SVG renderer for the server-computed commit graph (Nodes/Links already
 * carry lane + color from ConvertTo-DevKitGitGraphLayout - this component
 * only lays them out, it never re-derives lane assignment or color).
 * A same-lane link is a straight line; a lane-changing link is a smooth
 * S-curve whose stroke is a vertical gradient between the two lanes' own
 * colors ("gradient-lane") so a branch visibly flows into the lane it
 * joins. Rows are plain HTML buttons stacked on top of the SVG so the
 * whole row (graph node included) is one click target.
 *
 * Wrapped in `memo`: GitPanel polls `git.overview` every 6s while this
 * section is expanded, but react-query's default structural sharing hands
 * back the *same* `graph` object reference when a poll's response is
 * deeply equal to the last one (the common case - a repo's history rarely
 * changes every 6 seconds), so a plain shallow-props `memo` is enough to
 * skip rebuilding every path/gradient/row element on ticks where nothing
 * actually changed, without needing a hand-rolled equality key that risks
 * missing a field.
 */
export const GitGraph = memo(function GitGraph({ graph, path }: GitGraphProps) {
  const [selectedHash, setSelectedHash] = useState<string | null>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [edgeFade, setEdgeFade] = useState({ left: false, right: false });

  const laneCount = Math.max(1, graph.LaneCount || 1);
  const rowCount = graph.Nodes.length;
  const svgWidth = PAD_X * 2 + (laneCount - 1) * LANE_W;
  const totalHeight = rowCount * ROW_H;

  const laneX = (lane: number) => PAD_X + lane * LANE_W;
  const rowCenterY = (row: number) => row * ROW_H + ROW_H / 2;

  // Fade the scroll edges only when there's actually more graph past them -
  // a static mask would clip content that isn't overflowing at all.
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    function update() {
      if (!el) return;
      setEdgeFade({
        left: el.scrollLeft > 4,
        right: el.scrollLeft + el.clientWidth < el.scrollWidth - 4,
      });
    }
    update();
    el.addEventListener("scroll", update, { passive: true });
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => {
      el.removeEventListener("scroll", update);
      ro.disconnect();
    };
  }, [graph]);

  return (
    <div className="git-graph">
      <div
        ref={scrollRef}
        className={clsx(
          "git-graph__scroll",
          edgeFade.left && "git-graph__scroll--fade-left",
          edgeFade.right && "git-graph__scroll--fade-right",
        )}
      >
        <div className="git-graph__canvas" style={{ height: totalHeight, minWidth: svgWidth + 220 }}>
          <svg
            className="git-graph__svg"
            width={svgWidth}
            height={totalHeight}
            viewBox={`0 0 ${svgWidth} ${totalHeight}`}
          >
            <defs>
              {graph.Links.filter((l) => l.FromLane !== l.ToLane).map((l, i) => (
                <linearGradient
                  key={`grad-${i}`}
                  id={`git-graph-grad-${i}`}
                  gradientUnits="userSpaceOnUse"
                  x1={laneX(l.FromLane)}
                  y1={rowCenterY(l.FromRow)}
                  x2={laneX(l.ToLane)}
                  y2={rowCenterY(l.ToRow)}
                >
                  <stop offset="0%" stopColor={l.FromColor} />
                  <stop offset="100%" stopColor={l.ToColor} />
                </linearGradient>
              ))}
            </defs>
            {graph.Links.map((link, i) => {
              const x1 = laneX(link.FromLane);
              const y1 = rowCenterY(link.FromRow);
              const x2 = laneX(link.ToLane);
              const y2 = rowCenterY(link.ToRow);
              const sameLane = link.FromLane === link.ToLane;
              const midY = (y1 + y2) / 2;
              const d = sameLane
                ? `M ${x1} ${y1} L ${x2} ${y2}`
                : `M ${x1} ${y1} C ${x1} ${midY}, ${x2} ${midY}, ${x2} ${y2}`;
              return (
                <path
                  key={i}
                  d={d}
                  fill="none"
                  stroke={sameLane ? link.Color : `url(#git-graph-grad-${i})`}
                  strokeWidth={link.IsMerge ? 1.5 : 2.25}
                  strokeDasharray={link.IsMerge ? "3 3" : undefined}
                  strokeLinecap="round"
                  opacity={link.IsMerge ? 0.7 : 0.95}
                />
              );
            })}
            {graph.Nodes.map((node) => {
              const cx = laneX(node.Lane);
              const cy = rowCenterY(node.Row);
              const delay = Math.min(node.Row, MAX_STAGGER_ROWS) * STAGGER_STEP_MS;
              return (
                <g
                  key={node.Hash}
                  className="git-graph__node"
                  style={{ filter: `drop-shadow(0 0 4px ${node.Color})`, animationDelay: `${delay}ms` }}
                >
                  {node.Commit.IsHead && (
                    <circle cx={cx} cy={cy} r={NODE_R + 3.5} fill="none" stroke={node.Color} strokeWidth={1.5} opacity={0.55} />
                  )}
                  <circle cx={cx} cy={cy} r={NODE_R} fill={node.Color} stroke="var(--surface-sunken)" strokeWidth={1.5} />
                </g>
              );
            })}
          </svg>
          {graph.Nodes.map((node) => {
            const refs = node.Commit.Refs.slice(0, MAX_REFS);
            const extraRefs = node.Commit.Refs.length - refs.length;
            return (
              <button
                key={node.Hash}
                type="button"
                className={clsx("git-graph__row", selectedHash === node.Hash && "git-graph__row--selected")}
                style={{ top: node.Row * ROW_H, height: ROW_H, paddingLeft: svgWidth + TEXT_GAP }}
                onClick={() => setSelectedHash((h) => (h === node.Hash ? null : node.Hash))}
                title={node.Commit.Subject}
              >
                {refs.length > 0 && (
                  <span className="git-graph__refs">
                    {refs.map((ref) => (
                      <span
                        key={ref.Name}
                        className={clsx(
                          "git-graph__ref-pill",
                          ref.Kind === "head" && "git-graph__ref-pill--head",
                          ref.Kind === "tag" && "git-graph__ref-pill--tag",
                        )}
                      >
                        {ref.Name}
                      </span>
                    ))}
                    {extraRefs > 0 && <span className="git-graph__ref-pill">+{extraRefs}</span>}
                  </span>
                )}
                <span className="git-graph__subject">{node.Commit.Subject}</span>
                <span className="git-graph__meta">
                  {node.Commit.ShortHash} &middot; {node.Commit.Author} &middot; {node.Commit.When}
                </span>
              </button>
            );
          })}
        </div>
      </div>
      {selectedHash && (
        <CommitDetailCard path={path} hash={selectedHash} onClose={() => setSelectedHash(null)} />
      )}
    </div>
  );
});

function CommitDetailCard({ path, hash, onClose }: { path: string; hash: string; onClose: () => void }) {
  const [details, setDetails] = useState<GitCommitDetails | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setDetails(null);
    rpcCall<GitCommitDetails>("git.commitDetails", { path, hash })
      .then((d) => {
        if (!cancelled) setDetails(d);
      })
      .catch(() => {
        if (!cancelled) {
          setDetails({
            Found: false,
            Hash: hash,
            Error: "Could not load this commit.",
            Author: "",
            Email: "",
            Date: "",
            Message: "",
            Files: [],
            FilesChanged: 0,
            Insertions: 0,
            Deletions: 0,
          });
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [path, hash]);

  const shownFiles = details?.Files.slice(0, 12) ?? [];
  const moreFiles = (details?.Files.length ?? 0) - shownFiles.length;

  return (
    <div className="git-graph__detail">
      <div className="git-graph__detail-header">
        <span className="git-graph__detail-hash">{hash.slice(0, 7)}</span>
        <button type="button" className="git-graph__detail-close" onClick={onClose} title="Close">
          &#10005;
        </button>
      </div>
      {loading && <div className="git-graph__detail-loading">Loading commit&hellip;</div>}
      {!loading && details && !details.Found && (
        <div className="git-graph__detail-error">{details.Error ?? "Could not load this commit."}</div>
      )}
      {!loading && details?.Found && (
        <>
          <div className="git-graph__detail-message">{details.Message}</div>
          <div className="git-graph__detail-meta">
            {details.Author} &lt;{details.Email}&gt;
            {details.Date && ` · ${new Date(details.Date).toLocaleString()}`}
          </div>
          <div className="git-graph__detail-stats">
            {details.FilesChanged} file{details.FilesChanged === 1 ? "" : "s"} changed
            {details.Insertions > 0 && <span className="git-graph__stat-add"> +{details.Insertions}</span>}
            {details.Deletions > 0 && <span className="git-graph__stat-del"> -{details.Deletions}</span>}
          </div>
          {shownFiles.length > 0 && (
            <ul className="git-graph__detail-files">
              {shownFiles.map((f) => (
                <li key={f.Path}>
                  <span className="git-graph__file-path">{f.Path}</span>
                  {f.IsBinary ? (
                    <span className="git-graph__file-binary">binary</span>
                  ) : (
                    <span className="git-graph__file-stats">
                      <span className="git-graph__stat-add">+{f.Added}</span>{" "}
                      <span className="git-graph__stat-del">-{f.Deleted}</span>
                    </span>
                  )}
                </li>
              ))}
              {moreFiles > 0 && <li className="git-graph__detail-more">+{moreFiles} more files</li>}
            </ul>
          )}
        </>
      )}
    </div>
  );
}
