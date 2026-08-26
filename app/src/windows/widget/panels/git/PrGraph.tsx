import { memo, useMemo, type CSSProperties, type ReactNode } from "react";
import clsx from "clsx";
import { asArray } from "../../../../lib/arrays";
import type { GitGraph, GitGraphLink } from "../../../../lib/types";
import { prNumbersByCommit, type PrLane, type PrPathPoint } from "./prLanes";
import type { GitHubPrRow } from "./model";
import "./CommitGraph.css";
import "./PrGraph.css";

/**
 * Geometry, mirrored from CommitGraph.tsx so the two renderings stay
 * pixel-identical. Every y here is derived from ROW_H, so the drawn lanes
 * and the HTML rows stacked over them cannot drift.
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

/**
 * The "not yet" strip above the newest commit.
 *
 * A pull request's merge commit does not exist - it would be NEWER than
 * everything in the log, i.e. above row 0, where there is no row. Rather
 * than fake a row for it, the canvas reserves a band there and every pending
 * merge arcs up into it and lands on its base branch's lane. That band is
 * the honest picture: the lines stop at the edge of what has happened.
 */
const BAND_BASE = 40;
/** Where pending arcs converge, measured from the canvas top. */
const MERGE_Y = 9;
/** Vertical pitch between stubs for PRs whose head branch isn't in the log. */
const STUB_STEP = 9;
const STUB_TOP = MERGE_Y + 9;
const MAX_STUBS = 6;
/** Lanes-only gutters can be 24px wide; PR arcs need somewhere to curve. */
const MIN_PR_GUTTER = 52;

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
  /** Rendered in place of the legend when the PR list itself is loading, failed, or unavailable. */
  prNote?: ReactNode;
}

/**
 * One child -> parent commit edge, exactly as CommitGraph draws it: a merge
 * edge leaves the child sideways at once and then runs down its parent's
 * lane; a first-parent edge runs down the child's lane and bends into the
 * parent's at the bottom. Drawing both as one symmetric S makes a branch
 * point and a merge point look identical.
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

/** Head tip -> up its own column -> S-curve into the base branch's lane. */
function pendingPath(headX: number, headY: number, baseX: number, band: number): string {
  const rise = band + 4;
  const dy = (rise - MERGE_Y) * 0.55;
  return `M ${headX} ${headY} L ${headX} ${rise} C ${headX} ${rise - dy}, ${baseX} ${MERGE_Y + dy}, ${baseX} ${MERGE_Y}`;
}

/** A PR whose head branch isn't in this log: enters from the gutter's edge rather than from a row. */
function stubPath(edgeX: number, y: number, baseX: number): string {
  return `M ${edgeX} ${y} C ${edgeX - 26} ${y}, ${baseX} ${y}, ${baseX} ${MERGE_Y}`;
}

/** Upward chevron at the point a pending merge would land. */
function arrowPath(x: number, y: number): string {
  return `M ${x - 3.6} ${y + 5.2} L ${x} ${y} L ${x + 3.6} ${y + 5.2}`;
}

/** Hollow diamond marking "this line comes from outside the loaded log". */
function edgeCapPath(x: number, y: number): string {
  return `M ${x - 4} ${y} L ${x} ${y - 4} L ${x + 4} ${y} L ${x} ${y + 4} Z`;
}

/** What the legend has to admit about a PR that could not be fully drawn. */
function attachmentHint(lane: PrLane): string | null {
  if (lane.attachment === "unattached") return "head not in this log";
  if (lane.baseLane === null) return "base not in this log";
  if (!lane.forkFound) return "forked before this log";
  return null;
}

interface DrawnLane {
  lane: PrLane;
  ribbon: string | null;
  /** Vertical gradient id for a ribbon that has to fade out instead of closing on a fork. */
  fadeId: string | null;
  fadeAt: { x: number; y: number } | null;
  head: { x: number; y: number } | null;
  fork: { x: number; y: number } | null;
  pending: string | null;
  arrow: string | null;
  stubCap: { x: number; y: number } | null;
}

/**
 * The commit graph with its open pull requests drawn into it.
 *
 * The history itself comes fully laid out from the server
 * (ConvertTo-DevKitGitGraphLayout assigns every commit a Row, a Lane and a
 * color, and every edge its two endpoints); this component only maps that to
 * coordinates, exactly as CommitGraph does. What it ADDS is the PR overlay:
 * per PR, a translucent ribbon along the commits that branch actually owns,
 * and a dashed arc from its tip up into the band above row 0 where the merge
 * has not happened yet.
 *
 * Ribbon vs. arc is the whole grammar of the picture: SOLID means it is in
 * the repository, DASHED means it is proposed. And PR lanes are told apart
 * from commit lanes by weight and translucency rather than by hue, because
 * the eight server-side lane colors already cover the wheel (see
 * prLaneColors.ts).
 *
 * memo'd for the same reason CommitGraph is: the pane re-polls git.overview
 * every 6s, and react-query's structural sharing hands back the identical
 * `graph` object whenever a poll is deeply equal to the last one, so shallow
 * props memo alone skips rebuilding every path on those ticks.
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
    const stubs = lanes.filter((lane) => lane.attachment === "unattached" && lane.baseLane !== null);
    const shownStubs = Math.min(stubs.length, MAX_STUBS);
    const drawable = lanes.some((lane) => lane.path.length > 0 || lane.baseLane !== null);
    const band = drawable ? Math.max(BAND_BASE, STUB_TOP + Math.max(0, shownStubs - 1) * STUB_STEP + 12) : 0;
    const rowY = (row: number) => band + row * ROW_H + ROW_H / 2;

    const laneCount = Math.max(1, graph.LaneCount || 1);
    const lanesWidth = PAD_X * 2 + (laneCount - 1) * LANE_W;
    const svgWidth = drawable ? Math.max(lanesWidth, MIN_PR_GUTTER) : lanesWidth;
    const gutterWidth = Math.min(svgWidth, MAX_GUTTER);
    const edgeX = gutterWidth - 3;

    let stubIndex = 0;
    const drawn: DrawnLane[] = lanes.map((lane) => {
      const baseX = lane.baseLane === null ? null : laneX(lane.baseLane);
      const head = lane.path[0] ? { x: laneX(lane.path[0].lane), y: rowY(lane.path[0].row) } : null;
      const tail = lane.path.length > 0 ? lane.path[lane.path.length - 1] : null;
      const tailPoint = tail ? { x: laneX(tail.lane), y: rowY(tail.row) } : null;

      let stubCap: { x: number; y: number } | null = null;
      let pending: string | null = null;
      if (head && baseX !== null) {
        pending = pendingPath(head.x, head.y, baseX, band);
      } else if (!head && baseX !== null && stubIndex < MAX_STUBS) {
        const y = STUB_TOP + stubIndex * STUB_STEP;
        stubIndex += 1;
        pending = stubPath(edgeX, y, baseX);
        stubCap = { x: edgeX, y };
      }

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
        pending,
        arrow: pending && baseX !== null ? arrowPath(baseX, MERGE_Y) : null,
        stubCap,
      };
    });

    return {
      band,
      rowY,
      svgWidth,
      gutterWidth,
      clipped: svgWidth > gutterWidth,
      laneCount,
      drawn,
      hiddenStubs: stubs.length - shownStubs,
      totalHeight: band + nodes.length * ROW_H,
    };
  }, [graph.LaneCount, lanes, nodes.length]);

  const commitPaths = useMemo(
    () => links.map((link) => ({ link, d: linkPath(link, geometry.rowY) })),
    [links, geometry.rowY],
  );

  const prsByCommit = useMemo(() => prNumbersByCommit(lanes), [lanes]);
  const colorByPr = useMemo(() => new Map(lanes.map((lane) => [lane.number, lane.color])), [lanes]);

  return (
    <div
      className="pr-graph"
      style={{ "--graph-gutter": `${geometry.gutterWidth}px` } as CSSProperties}
    >
      {prNote ? (
        <div className="pr-graph__note">{prNote}</div>
      ) : (
        lanes.length > 0 && (
          <div className="pr-graph__legend" role="group" aria-label="Open pull requests drawn on this graph">
            {lanes.map((lane) => {
              const hint = attachmentHint(lane);
              const lit = highlightPr === lane.number;
              const branches =
                lane.headRefName && lane.baseRefName ? `${lane.headRefName} → ${lane.baseRefName}` : null;
              return (
                <button
                  key={lane.number}
                  type="button"
                  className={clsx(
                    "pr-chip",
                    lit && "pr-chip--lit",
                    lane.isDraft && "pr-chip--draft",
                    hint && "pr-chip--partial",
                  )}
                  style={{ "--pr-color": lane.color } as CSSProperties}
                  title={[`#${lane.number} ${lane.pr.title}`, branches, lane.isDraft ? "draft" : null, hint]
                    .filter(Boolean)
                    .join(" · ")}
                  onMouseEnter={() => onHighlightPr(lane.number)}
                  onMouseLeave={() => onHighlightPr(null)}
                  onFocus={() => onHighlightPr(lane.number)}
                  onBlur={() => onHighlightPr(null)}
                  onClick={() => onSelectPr(lane.pr)}
                >
                  <span className="pr-chip__wire" aria-hidden="true" />
                  <span className="pr-chip__num">#{lane.number}</span>
                  <span className="pr-chip__title">{lane.pr.title}</span>
                  {hint && <span className="pr-chip__hint">{hint}</span>}
                </button>
              );
            })}
            {geometry.hiddenStubs > 0 && (
              // NOT "+N more PRs" - every open PR already has a chip above.
              // These are the ones whose stub the band has no room for.
              <span
                className="pr-chip pr-chip--overflow"
                title="More off-log pull requests than the strip above the graph can hold. They are listed here, but no line is drawn for them."
              >
                {geometry.hiddenStubs} of these have no line drawn
              </span>
            )}
          </div>
        )
      )}

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

              {/* ---- proposed merges: dashed, above everything, because none of this has happened ---- */}
              <g className="pr-graph__pending-layer">
                {geometry.drawn.map(({ lane, pending, arrow, head, fork, stubCap }) => {
                  const lit = highlightPr === lane.number;
                  const dim = highlightPr !== null && !lit;
                  return (
                    <g
                      key={`pending-${lane.number}`}
                      className={clsx("pr-graph__lane", dim && "pr-graph__lane--dim", lit && "pr-graph__lane--lit")}
                    >
                      {pending && (
                        <path
                          className={clsx("pr-graph__pending", lit && "pr-graph__pending--live")}
                          d={pending}
                          fill="none"
                          stroke={lane.color}
                          strokeWidth={lit ? 2.4 : 1.8}
                          strokeLinecap="round"
                          strokeDasharray={lane.isDraft ? "2 5" : "6 5"}
                        />
                      )}
                      {arrow && (
                        <path
                          d={arrow}
                          fill="none"
                          stroke={lane.color}
                          strokeWidth={lit ? 2.2 : 1.8}
                          strokeLinecap="round"
                          strokeLinejoin="round"
                        />
                      )}
                      {stubCap && (
                        <path
                          d={edgeCapPath(stubCap.x, stubCap.y)}
                          fill="var(--surface-sunken)"
                          stroke={lane.color}
                          strokeWidth={1.4}
                        />
                      )}
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
                    top: geometry.band + node.Row * ROW_H,
                    height: ROW_H,
                    "--lane-color": node.Color,
                    "--pr-color": litByPr && highlightPr !== null ? colorByPr.get(highlightPr) : undefined,
                  } as CSSProperties
                }
                aria-pressed={selected}
                // Hovering a commit that belongs to a PR lights that PR's
                // ribbon and its legend chip - the same link the chip makes
                // in the other direction. Rows that belong to no PR clear it,
                // rather than leaving the last one lit under the pointer.
                onMouseEnter={() => onHighlightPr(rowPrs ? rowPrs[0] : null)}
                onMouseLeave={() => onHighlightPr(null)}
                onClick={() =>
                  onSelectCommit({ hash: node.Hash, shortHash: node.Commit.ShortHash, subject: node.Commit.Subject })
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
    </div>
  );
});
