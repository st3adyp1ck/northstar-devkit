import { memo, useMemo, type CSSProperties, type ReactNode } from "react";
import clsx from "clsx";
import { asArray } from "../../../../lib/arrays";
import type { GitGraph, GitGraphLink } from "../../../../lib/types";
import { prNumbersByCommit, type PrLane, type PrPathPoint } from "./prLanes";
import type { GitHubPrRow } from "./model";
import "./CommitGraph.css";
import "./PrGraph.css";

/**
 * Geometry for the commit rows and the SVG lanes under them. Every y is
 * derived from ROW_H, so the drawn lanes and the HTML rows stacked over
 * them cannot drift.
 */
const ROW_H = 30;
const LANE_W = 14;
const NODE_R = 4.5;
const PAD_X = 12;
/** Past this many pixels of lanes the gutter eats the subject column, so it clips with a fade. */
const MAX_GUTTER = 148;
const MAX_STAGGER_ROWS = 12;
const STAGGER_STEP_MS = 14;
const MAX_REFS = 3;

const laneX = (lane: number) => PAD_X + lane * LANE_W;

interface PrGraphProps {
  graph: GitGraph;
  /** Open PRs already resolved against this graph - see prLanes.ts. */
  lanes: PrLane[];
  selectedHash: string | null;
  onSelectCommit: (node: { hash: string; shortHash: string; subject: string }) => void;
  onSelectPr: (pr: GitHubPrRow) => void;
  /** PR number whose lane is lit; null for none. Owned by GitPanel so the PR tab shares it. */
  highlightPr: number | null;
  onHighlightPr: (number: number | null) => void;
  /** Slim status line for when the PR list itself is loading, failed, or unavailable (see prOverlayNote in GitPanel). */
  prNote?: ReactNode;
}

/**
 * One child -> parent commit edge: a merge edge leaves the child sideways at
 * once and then runs down its parent's lane; a first-parent edge runs down
 * the child's lane and bends into the parent's at the bottom. Drawing both
 * as one symmetric S makes a branch point and a merge point look identical.
 */
function linkPath(link: GitGraphLink, rowY: (row: number) => number): string {
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
 * The PR's own commits as one continuous stroke, head (top) to fork
 * (bottom), bending the same way a first-parent commit edge does so the
 * ribbon lies along the history it is highlighting instead of cutting across
 * it.
 */
function ribbonPath(points: PrPathPoint[], rowY: (row: number) => number): string {
  if (points.length === 0) return "";
  let d = `M ${laneX(points[0].lane)} ${rowY(points[0].row)}`;
  for (let i = 1; i < points.length; i += 1) {
    const from = points[i - 1];
    const to = points[i];
    const x1 = laneX(from.lane);
    const y1 = rowY(from.row);
    const x2 = laneX(to.lane);
    const y2 = rowY(to.row);
    if (x1 === x2) {
      d += ` L ${x2} ${y2}`;
      continue;
    }
    const bend = Math.max(10, Math.min(ROW_H, Math.abs(y2 - y1) / 2));
    const turn = y2 - bend;
    d += ` L ${x1} ${turn} C ${x1} ${turn + bend * 0.6}, ${x2} ${y2 - bend * 0.6}, ${x2} ${y2}`;
  }
  return d;
}

interface DrawnLane {
  lane: PrLane;
  ribbon: string | null;
  /** Vertical gradient id for a ribbon that has to fade out instead of closing on a fork. */
  fadeId: string | null;
  fadeAt: { x: number; y: number } | null;
  head: { x: number; y: number } | null;
  fork: { x: number; y: number } | null;
}

/**
 * The commit graph with its open pull requests drawn INTO it, as part of the
 * one chart - never as a separate section above it.
 *
 * The history itself comes fully laid out from the server
 * (ConvertTo-DevKitGitGraphLayout assigns every commit a Row, a Lane and a
 * color, and every edge its two endpoints); this component only maps that to
 * coordinates. What it ADDS is PR identity in the same flow:
 *
 *   - a `#42` PILL on the row of each PR's head commit, in that PR's stable
 *     lane color (git-graph-style: the ref lives on the commit, not in a
 *     legend), click-through to the same detail view the PRs tab opens;
 *   - a translucent RIBBON along the commits the branch actually owns;
 *   - a ring on the head commit and a dashed ring on the fork commit.
 *
 * There is deliberately no legend and no "pending merge" band: PRs that
 * could not be matched into this log window get one slim honesty line under
 * the chart pointing at the Pull requests tab, not a stub apiece.
 *
 * memo'd: the pane re-polls git.overview every 6s, and react-query's
 * structural sharing hands back the identical `graph` object whenever a poll
 * is deeply equal to the last one, so shallow props memo alone skips
 * rebuilding every path on those ticks.
 */
export const PrGraph = memo(function PrGraph({
  graph,
  lanes,
  selectedHash,
  onSelectCommit,
  onSelectPr,
  highlightPr,
  onHighlightPr,
  prNote,
}: PrGraphProps) {
  const nodes = useMemo(() => asArray(graph.Nodes), [graph.Nodes]);
  const links = useMemo(() => asArray(graph.Links), [graph.Links]);

  const geometry = useMemo(() => {
    const rowY = (row: number) => row * ROW_H + ROW_H / 2;

    const laneCount = Math.max(1, graph.LaneCount || 1);
    const svgWidth = PAD_X * 2 + (laneCount - 1) * LANE_W;
    const gutterWidth = Math.min(svgWidth, MAX_GUTTER);

    const drawn: DrawnLane[] = lanes.map((lane) => {
      const head = lane.path[0] ? { x: laneX(lane.path[0].lane), y: rowY(lane.path[0].row) } : null;
      const tail = lane.path.length > 0 ? lane.path[lane.path.length - 1] : null;
      const tailPoint = tail ? { x: laneX(tail.lane), y: rowY(tail.row) } : null;

      return {
        lane,
        ribbon: lane.path.length > 1 ? ribbonPath(lane.path, rowY) : null,
        // A ribbon that never reached its fork must not end on a hard stop -
        // that would read as "it started here", which is the one thing we do
        // not know. It dissolves instead.
        fadeId: head && !lane.forkFound ? `pr-fade-${lane.number}` : null,
        fadeAt: head && !lane.forkFound ? (tailPoint ?? head) : null,
        head,
        fork: lane.forkFound ? tailPoint : null,
      };
    });

    return {
      rowY,
      svgWidth,
      gutterWidth,
      clipped: svgWidth > gutterWidth,
      laneCount,
      drawn,
      totalHeight: nodes.length * ROW_H,
    };
  }, [graph.LaneCount, lanes, nodes.length]);

  const commitPaths = useMemo(
    () => links.map((link) => ({ link, d: linkPath(link, geometry.rowY) })),
    [links, geometry.rowY],
  );

  const prsByCommit = useMemo(() => prNumbersByCommit(lanes), [lanes]);
  const colorByPr = useMemo(() => new Map(lanes.map((lane) => [lane.number, lane.color])), [lanes]);

  /** Head-commit hash -> the PR(s) whose tip it is, for the row pills. */
  const prPillsByHash = useMemo(() => {
    const map = new Map<string, PrLane[]>();
    for (const lane of lanes) {
      const tip = lane.path[0];
      if (!tip) continue;
      const list = map.get(tip.hash);
      if (list) list.push(lane);
      else map.set(tip.hash, [lane]);
    }
    return map;
  }, [lanes]);

  /** PRs with no head anywhere in this log - the one thing the chart cannot show, said in one line. */
  const offLogCount = useMemo(() => lanes.filter((lane) => lane.attachment === "unattached").length, [lanes]);

  return (
    <div
      className="pr-graph"
      style={{ "--graph-gutter": `${geometry.gutterWidth}px` } as CSSProperties}
    >
      {prNote && <div className="pr-graph__note">{prNote}</div>}

      <div className="pr-graph__scroll">
        <div className="commit-graph__canvas" style={{ height: geometry.totalHeight }}>
          <div
            className={clsx("commit-graph__gutter", geometry.clipped && "commit-graph__gutter--clipped")}
            title={geometry.clipped ? `${geometry.laneCount} lanes - more than fit here` : undefined}
          >
            <svg
              width={geometry.svgWidth}
              height={geometry.totalHeight}
              viewBox={`0 0 ${geometry.svgWidth} ${geometry.totalHeight}`}
              aria-hidden="true"
            >
              <defs>
                {commitPaths.map(({ link }, i) =>
                  link.FromLane === link.ToLane ? null : (
                    <linearGradient
                      key={`grad-${i}`}
                      id={`pr-graph-grad-${i}`}
                      gradientUnits="userSpaceOnUse"
                      x1={laneX(link.FromLane)}
                      y1={geometry.rowY(link.FromRow)}
                      x2={laneX(link.ToLane)}
                      y2={geometry.rowY(link.ToRow)}
                    >
                      <stop offset="0%" stopColor={link.FromColor} />
                      <stop offset="100%" stopColor={link.ToColor} />
                    </linearGradient>
                  ),
                )}
                {geometry.drawn.map(({ lane, fadeId, fadeAt }) =>
                  fadeId && fadeAt ? (
                    <linearGradient
                      key={fadeId}
                      id={fadeId}
                      gradientUnits="userSpaceOnUse"
                      x1={fadeAt.x}
                      y1={fadeAt.y}
                      x2={fadeAt.x}
                      y2={fadeAt.y + 26}
                    >
                      <stop offset="0%" stopColor={lane.color} />
                      <stop offset="100%" stopColor={lane.color} stopOpacity="0" />
                    </linearGradient>
                  ) : null,
                )}
              </defs>

              {/* ---- PR ribbons: behind the history they highlight ---- */}
              <g className="pr-graph__ribbons">
                {geometry.drawn.map(({ lane, ribbon, fadeId, fadeAt }) => {
                  const dim = highlightPr !== null && highlightPr !== lane.number;
                  return (
                    <g
                      key={`ribbon-${lane.number}`}
                      className={clsx("pr-graph__lane", dim && "pr-graph__lane--dim", highlightPr === lane.number && "pr-graph__lane--lit")}
                    >
                      {ribbon && (
                        <path
                          className="pr-graph__ribbon"
                          d={ribbon}
                          fill="none"
                          stroke={lane.color}
                          strokeWidth={highlightPr === lane.number ? 9 : 7}
                          strokeLinecap="round"
                          strokeLinejoin="round"
                          strokeDasharray={lane.isDraft ? "2 7" : undefined}
                        />
                      )}
                      {fadeId && fadeAt && (
                        <path
                          className="pr-graph__ribbon"
                          d={`M ${fadeAt.x} ${fadeAt.y} L ${fadeAt.x} ${fadeAt.y + 26}`}
                          fill="none"
                          stroke={`url(#${fadeId})`}
                          strokeWidth={7}
                          strokeLinecap="round"
                        />
                      )}
                    </g>
                  );
                })}
              </g>

              {/* ---- the history itself, unchanged ---- */}
              {commitPaths.map(({ link, d }, i) => (
                <path
                  key={`link-${i}`}
                  d={d}
                  fill="none"
                  stroke={link.FromLane === link.ToLane ? link.Color : `url(#pr-graph-grad-${i})`}
                  strokeWidth={link.IsMerge ? 1.6 : 2.4}
                  strokeLinecap="round"
                  opacity={link.IsMerge ? 0.85 : 1}
                />
              ))}
              {nodes.map((node) => {
                const cx = laneX(node.Lane);
                const cy = geometry.rowY(node.Row);
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

              {/* ---- PR marks: head ring and fork ring, above the history ---- */}
              <g className="pr-graph__marks">
                {geometry.drawn.map(({ lane, head, fork }) => {
                  const lit = highlightPr === lane.number;
                  const dim = highlightPr !== null && !lit;
                  return (
                    <g
                      key={`marks-${lane.number}`}
                      className={clsx("pr-graph__lane", dim && "pr-graph__lane--dim", lit && "pr-graph__lane--lit")}
                    >
                      {head && (
                        <circle
                          cx={head.x}
                          cy={head.y}
                          r={NODE_R + 3.2}
                          fill="none"
                          stroke={lane.color}
                          strokeWidth={lit ? 2 : 1.5}
                          strokeDasharray={lane.isDraft ? "2 2.5" : undefined}
                        />
                      )}
                      {fork && (
                        <circle
                          cx={fork.x}
                          cy={fork.y}
                          r={NODE_R + 3.2}
                          fill="none"
                          stroke={lane.color}
                          strokeWidth={1.3}
                          strokeDasharray="2 2.5"
                          opacity={0.85}
                        />
                      )}
                    </g>
                  );
                })}
              </g>
            </svg>
          </div>

          {nodes.map((node) => {
            const refs = asArray(node.Commit.Refs);
            const shown = refs.slice(0, MAX_REFS);
            const extra = refs.length - shown.length;
            const selected = node.Hash === selectedHash;
            const rowPrs = prsByCommit.get(node.Hash);
            const rowPrLanes = prPillsByHash.get(node.Hash);
            const litByPr = !!rowPrs && highlightPr !== null && rowPrs.includes(highlightPr);
            return (
              <button
                key={node.Hash}
                type="button"
                className={clsx(
                  "commit-graph__row",
                  selected && "commit-graph__row--selected",
                  litByPr && "commit-graph__row--pr-lit",
                )}
                style={
                  {
                    top: node.Row * ROW_H,
                    height: ROW_H,
                    "--lane-color": node.Color,
                    "--pr-color": litByPr && highlightPr !== null ? colorByPr.get(highlightPr) : undefined,
                  } as CSSProperties
                }
                aria-pressed={selected}
                // Hovering a commit that belongs to a PR lights that PR's
                // ribbon - the same link its row pill makes in the other
                // direction. Rows that belong to no PR clear it, rather than
                // leaving the last one lit under the pointer.
                onMouseEnter={() => onHighlightPr(rowPrs ? rowPrs[0] : null)}
                onMouseLeave={() => onHighlightPr(null)}
                onClick={() =>
                  onSelectCommit({ hash: node.Hash, shortHash: node.Commit.ShortHash, subject: node.Commit.Subject })
                }
                title={node.Commit.Subject}
              >
                <span className="commit-graph__head">
                  {rowPrLanes && (
                    <span className="commit-graph__refs commit-graph__refs--prs">
                      {rowPrLanes.map((lane) => (
                        <span
                          key={`pr-${lane.number}`}
                          className={clsx(
                            "commit-graph__ref",
                            "commit-graph__ref--pr",
                            lane.isDraft && "commit-graph__ref--pr-draft",
                          )}
                          style={{ "--pr-color": lane.color } as CSSProperties}
                          title={`#${lane.number} ${lane.pr.title}${lane.isDraft ? " (draft)" : ""} - open the pull request`}
                          // The row is a <button>, so a real nested button
                          // would be invalid HTML; the span stops propagation
                          // instead. The same detail view is reachable from
                          // the Pull requests tab for keyboard users.
                          onClick={(e) => {
                            e.stopPropagation();
                            onSelectPr(lane.pr);
                          }}
                          onMouseEnter={(e) => {
                            e.stopPropagation();
                            onHighlightPr(lane.number);
                          }}
                          // Hand the highlight BACK to the row rather than
                          // clearing it: the pointer is still inside the row,
                          // and React will not re-fire the row's own
                          // onMouseEnter for a move that never left it - so
                          // clearing here dropped the highlight the row
                          // should still be holding. Leaving the row for good
                          // is handled by the row's own onMouseLeave.
                          onMouseLeave={(e) => {
                            e.stopPropagation();
                            onHighlightPr(rowPrs ? rowPrs[0] : null);
                          }}
                        >
                          #{lane.number}
                        </span>
                      ))}
                    </span>
                  )}
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

      {offLogCount > 0 && (
        <div className="pr-graph__offlog">
          {offLogCount === 1
            ? "1 open pull request has no head commit in this log window - see Pull requests."
            : `${offLogCount} open pull requests have no head commit in this log window - see Pull requests.`}
        </div>
      )}
    </div>
  );
});
