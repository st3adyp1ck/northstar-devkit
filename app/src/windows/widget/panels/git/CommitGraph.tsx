import { memo, useMemo, type CSSProperties } from "react";
import clsx from "clsx";
import { asArray } from "../../../../lib/arrays";
import type { GitGraph, GitGraphLink } from "../../../../lib/types";
import "./CommitGraph.css";

/** Row pitch. Every y coordinate in the SVG is derived from this, so the drawn
 *  graph and the HTML rows stacked on top of it can never drift apart. */
const ROW_H = 30;
const LANE_W = 14;
const NODE_R = 4.5;
const PAD_X = 12;
/** Past this many pixels of lanes the gutter starts eating the subject column,
 *  so it clips (with a fade) instead. ~11 concurrent lanes. */
const MAX_GUTTER = 148;
/** Draw-in stagger is capped so a 40-commit history doesn't animate for a second and a half. */
const MAX_STAGGER_ROWS = 12;
const STAGGER_STEP_MS = 14;
const MAX_REFS = 3;

interface CommitGraphProps {
  graph: GitGraph;
  selectedHash: string | null;
  onSelect: (node: { hash: string; shortHash: string; subject: string }) => void;
}

const laneX = (lane: number) => PAD_X + lane * LANE_W;
const rowY = (row: number) => row * ROW_H + ROW_H / 2;

/**
 * The edge path for one child -> parent link.
 *
 * A lane change is drawn as a straight run in ONE lane plus a single bend,
 * and which end gets the bend is what makes the picture readable:
 *  - a merge edge (second+ parent) leaves the child sideways immediately and
 *    then runs down its parent's lane - "this side branch came from over
 *    there";
 *  - a first-parent edge runs down the child's own lane and bends into the
 *    parent's at the very bottom - "this lane ends by joining that one".
 * Drawing both as one symmetric S (what the old renderer did) made a branch
 * point and a merge point look identical.
 */
function linkPath(link: GitGraphLink): string {
  const x1 = laneX(link.FromLane);
  const y1 = rowY(link.FromRow);
  const x2 = laneX(link.ToLane);
  const y2 = rowY(link.ToRow);
  if (link.FromLane === link.ToLane) return `M ${x1} ${y1} L ${x2} ${y2}`;

  const span = Math.abs(y2 - y1);
  const bend = Math.max(10, Math.min(ROW_H, span / 2));
  if (link.IsMerge) {
    const turn = y1 + bend;
    return `M ${x1} ${y1} C ${x1} ${y1 + bend * 0.6}, ${x2} ${turn - bend * 0.6}, ${x2} ${turn} L ${x2} ${y2}`;
  }
  const turn = y2 - bend;
  return `M ${x1} ${y1} L ${x1} ${turn} C ${x1} ${turn + bend * 0.6}, ${x2} ${y2 - bend * 0.6}, ${x2} ${y2}`;
}

/**
 * Draws the server-computed commit graph. ConvertTo-DevKitGitGraphLayout has
 * already assigned every commit a Row, a Lane and a lane Color, and every
 * child->parent edge its two endpoints - this component only maps those to
 * coordinates. It never re-derives lane assignment or color.
 *
 * Rows are HTML buttons absolutely positioned over the SVG so the whole row
 * (node included) is one click target with real focus/keyboard behaviour,
 * and so the commit metadata can use ordinary text layout with columns that
 * line up across rows.
 *
 * memo'd: the pane polls git.overview on an interval, and react-query's
 * structural sharing hands back the SAME `graph` object when a poll is
 * deeply equal to the previous one (the common case - history rarely changes
 * every few seconds), so shallow-props memo alone skips rebuilding every
 * path and row on those ticks.
 */
export const CommitGraph = memo(function CommitGraph({ graph, selectedHash, onSelect }: CommitGraphProps) {
  const nodes = useMemo(() => asArray(graph.Nodes), [graph.Nodes]);
  const links = useMemo(() => asArray(graph.Links), [graph.Links]);

  const laneCount = Math.max(1, graph.LaneCount || 1);
  const svgWidth = PAD_X * 2 + (laneCount - 1) * LANE_W;
  const gutterWidth = Math.min(svgWidth, MAX_GUTTER);
  const clipped = svgWidth > gutterWidth;
  const totalHeight = nodes.length * ROW_H;

  const paths = useMemo(
    () => links.map((link) => ({ link, d: linkPath(link) })),
    [links],
  );

  return (
    <div className="commit-graph" style={{ "--graph-gutter": `${gutterWidth}px` } as CSSProperties}>
      <div className="commit-graph__canvas" style={{ height: totalHeight }}>
        <div
          className={clsx("commit-graph__gutter", clipped && "commit-graph__gutter--clipped")}
          title={clipped ? `${laneCount} lanes - more than fit here` : undefined}
        >
          <svg
            width={svgWidth}
            height={totalHeight}
            viewBox={`0 0 ${svgWidth} ${totalHeight}`}
            aria-hidden="true"
          >
            <defs>
              {paths.map(({ link }, i) =>
                link.FromLane === link.ToLane ? null : (
                  <linearGradient
                    key={`grad-${i}`}
                    id={`commit-graph-grad-${i}`}
                    gradientUnits="userSpaceOnUse"
                    x1={laneX(link.FromLane)}
                    y1={rowY(link.FromRow)}
                    x2={laneX(link.ToLane)}
                    y2={rowY(link.ToRow)}
                  >
                    <stop offset="0%" stopColor={link.FromColor} />
                    <stop offset="100%" stopColor={link.ToColor} />
                  </linearGradient>
                ),
              )}
            </defs>
            {paths.map(({ link, d }, i) => (
              <path
                key={`link-${i}`}
                d={d}
                fill="none"
                stroke={link.FromLane === link.ToLane ? link.Color : `url(#commit-graph-grad-${i})`}
                strokeWidth={link.IsMerge ? 1.6 : 2.4}
                strokeLinecap="round"
                opacity={link.IsMerge ? 0.85 : 1}
              />
            ))}
            {nodes.map((node) => {
              const cx = laneX(node.Lane);
              const cy = rowY(node.Row);
              const isMerge = asArray(node.Commit.Parents).length > 1;
              const selected = node.Hash === selectedHash;
              return (
                <g
                  key={node.Hash}
                  className="commit-graph__node"
                  style={{ animationDelay: `${Math.min(node.Row, MAX_STAGGER_ROWS) * STAGGER_STEP_MS}ms` }}
                >
                  {node.Commit.IsHead && (
                    <circle
                      className="commit-graph__head-ring"
                      cx={cx}
                      cy={cy}
                      r={NODE_R + 3.5}
                      fill="none"
                      stroke={node.Color}
                      strokeWidth={1.4}
                    />
                  )}
                  {selected && (
                    <circle cx={cx} cy={cy} r={NODE_R + 5.5} fill="none" stroke="var(--accent-strong)" strokeWidth={1.2} />
                  )}
                  {/* A merge commit is drawn hollow - the standard "two histories met here" mark. */}
                  <circle
                    cx={cx}
                    cy={cy}
                    r={NODE_R}
                    fill={isMerge ? "var(--surface-sunken)" : node.Color}
                    stroke={node.Color}
                    strokeWidth={isMerge ? 2 : 1.4}
                  />
                </g>
              );
            })}
          </svg>
        </div>

        {nodes.map((node) => {
          const refs = asArray(node.Commit.Refs);
          const shown = refs.slice(0, MAX_REFS);
          const extra = refs.length - shown.length;
          const selected = node.Hash === selectedHash;
          return (
            <button
              key={node.Hash}
              type="button"
              className={clsx("commit-graph__row", selected && "commit-graph__row--selected")}
              style={{ top: node.Row * ROW_H, height: ROW_H, "--lane-color": node.Color } as CSSProperties}
              aria-pressed={selected}
              onClick={() =>
                onSelect({ hash: node.Hash, shortHash: node.Commit.ShortHash, subject: node.Commit.Subject })
              }
              title={node.Commit.Subject}
            >
              <span className="commit-graph__head">
                {shown.length > 0 && (
                  <span className="commit-graph__refs">
                    {shown.map((ref) => (
                      <span
                        key={ref.Name}
                        className={clsx(
                          "commit-graph__ref",
                          ref.Kind === "head" && "commit-graph__ref--head",
                          ref.Kind === "tag" && "commit-graph__ref--tag",
                        )}
                      >
                        {ref.Name}
                      </span>
                    ))}
                    {extra > 0 && (
                      <span className="commit-graph__ref" title={refs.slice(MAX_REFS).map((r) => r.Name).join(", ")}>
                        +{extra}
                      </span>
                    )}
                  </span>
                )}
                <span className="commit-graph__subject">{node.Commit.Subject}</span>
              </span>
              <span className="commit-graph__meta">
                <span className="commit-graph__hash">{node.Commit.ShortHash}</span>
                <span className="commit-graph__author">{node.Commit.Author}</span>
                <span className="commit-graph__when">{node.Commit.When}</span>
              </span>
            </button>
          );
        })}
      </div>
    </div>
  );
});
