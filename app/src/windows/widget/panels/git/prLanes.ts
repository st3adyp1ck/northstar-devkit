/**
 * Attaching open pull requests to the commit graph the server already laid
 * out.
 *
 * A PR is not in git history. It is a PROPOSAL: "these commits on <head>
 * should become part of <base>". The commits already exist (git.overview's
 * `git log --all` sees every branch, so a PR branch that has been pushed is
 * usually in the log); the merge does not. So the only two things this file
 * has to work out per PR are
 *
 *   1. which loaded commits belong to it - the run from the head branch tip
 *      back to where it diverged from base, and
 *   2. which lane the pending merge would land in - the base branch's lane.
 *
 * Everything else the renderer draws (the ribbon, the dashed arc) is derived
 * from those. Nothing here invents a row or a lane: when the data cannot
 * answer, the PR comes back flagged so the renderer can say so instead of
 * drawing a confident wrong line. That is the whole reason this is a
 * separate, pure, testable module.
 *
 * Cost: a graph is capped at 40 commits and the PR list at 50, and both
 * traversals below are linear in the loaded node count with the base
 * branch's ancestor set memoised across PRs (nearly every PR targets the
 * same base), so a full rebuild is a few thousand operations.
 */
import { asArray } from "../../../../lib/arrays";
import type { GitGraph, GitGraphNode } from "../../../../lib/types";
import { prLaneColor } from "./prLaneColors";
import type { GitHubPrRow } from "./model";

/**
 * The one remote prefix worth stripping. `git log --all` decorates remote
 * branches as `origin/feature-x` while gh reports `headRefName` as plain
 * `feature-x`, so an unpushed-to-a-fork PR would never match without this.
 * Only `origin/` is tried, and only as a FALLBACK after the exact name:
 * guessing at arbitrary `<something>/<rest>` prefixes would mis-resolve a
 * perfectly ordinary branch called `feature/foo`, and the overview only
 * proves `origin` exists (it reads remote.origin.url) - it never enumerates
 * the remote list.
 */
const ORIGIN_PREFIX = "origin/";

export type PrAttachment =
  /** Head tip found AND its divergence from base is inside the loaded log - the full ribbon is drawable. */
  | "attached"
  /** Head tip found, but where it left base is older than the 40 commits we have - the ribbon has to fade out. */
  | "open"
  /** The head branch has no ref anywhere in this log - there is no row to attach to at all. */
  | "unattached";

export interface PrPathPoint {
  row: number;
  lane: number;
  hash: string;
}

export interface PrLane {
  number: number;
  pr: GitHubPrRow;
  /** Per-PR lane color, derived from the live accent - see prLaneColors.ts. */
  color: string;
  isDraft: boolean;
  headRefName: string | null;
  baseRefName: string | null;
  attachment: PrAttachment;
  /**
   * The PR's own commits, head tip FIRST (smallest Row) and the divergence
   * point last. Empty when unattached; one point when the tip was found but
   * nothing older could be walked.
   */
  path: PrPathPoint[];
  /** True when `path`'s last point really is the merge base, so the ribbon can close on it. */
  forkFound: boolean;
  /** Where the pending merge would land. null when the base branch isn't in this log - then no arc is drawn. */
  baseLane: number | null;
  baseRow: number | null;
}

/**
 * branch/HEAD ref name -> the node carrying it. Tags are skipped: a PR's
 * head is a branch, and letting `v1.2` win a name lookup would attach a PR
 * to a release commit. First writer wins, which matters when a local branch
 * and its remote-tracking ref sit on different commits - `git log`'s
 * decorations list the local one first on the newer commit.
 */
function indexRefs(nodes: GitGraphNode[]): Map<string, GitGraphNode> {
  const byRef = new Map<string, GitGraphNode>();
  for (const node of nodes) {
    for (const ref of asArray(node.Commit.Refs)) {
      const name = ref?.Name;
      if (!name || ref.Kind === "tag") continue;
      if (!byRef.has(name)) byRef.set(name, node);
    }
  }
  return byRef;
}

/** Exact ref name first, then the origin-tracking form; never a fuzzy match. */
export function resolveBranchNode(
  byRef: Map<string, GitGraphNode>,
  name: string | null | undefined,
): GitGraphNode | null {
  if (!name) return null;
  return byRef.get(name) ?? byRef.get(ORIGIN_PREFIX + name) ?? null;
}

/** gh's `--json` fields are passed through untouched, so anything the field list gains lands here as `unknown`. */
function stringField(pr: GitHubPrRow, key: string): string | null {
  const value = (pr as Record<string, unknown>)[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}

/**
 * A commit SHA beats a branch name every time.
 *
 * `headRefOid` names the exact commit, so it needs no origin/ guess and
 * works for a PR from a fork, whose head branch has no ref in this repo at
 * all. It is only present if the sidecar's `gh pr list --json` field list
 * asks for it (it does not today - see this batch's report), so the ref-name
 * path stays the working one and this is a strict upgrade when it arrives.
 */
function resolveHeadNode(
  byHash: Map<string, GitGraphNode>,
  byRef: Map<string, GitGraphNode>,
  oid: string | null,
  name: string | null,
): GitGraphNode | null {
  if (oid) {
    const node = byHash.get(oid);
    if (node) return node;
  }
  return resolveBranchNode(byRef, name);
}

/**
 * Every loaded commit reachable from `start`, `start` included.
 *
 * Parents that fall outside the 40-commit window simply aren't in byHash, so
 * the walk stops there - which is exactly right: reachability we cannot see
 * is reachability we must not claim.
 */
function ancestorHashes(start: string, byHash: Map<string, GitGraphNode>): Set<string> {
  const seen = new Set<string>();
  const stack: string[] = [start];
  while (stack.length > 0) {
    const hash = stack.pop()!;
    if (seen.has(hash)) continue;
    const node = byHash.get(hash);
    if (!node) continue;
    seen.add(hash);
    for (const parent of asArray(node.Commit.Parents)) {
      if (parent && !seen.has(parent)) stack.push(parent);
    }
  }
  return seen;
}

/**
 * The newest commit reachable from both sides - the merge base, whenever the
 * window contains it and every path to it.
 *
 * Rows come out of ConvertTo-DevKitGitGraphLayout in topological order with
 * children before parents, so "newest" is simply the smallest Row. A DAG can
 * have several merge bases (criss-cross merges); the newest is the one a
 * reader would point at as "where this branch left".
 */
function newestCommonAncestor(
  a: Set<string>,
  b: Set<string>,
  byHash: Map<string, GitGraphNode>,
): GitGraphNode | null {
  let best: GitGraphNode | null = null;
  // Iterate the smaller set - a feature branch's ancestry is usually a tiny
  // fraction of the trunk's.
  const [small, large] = a.size <= b.size ? [a, b] : [b, a];
  for (const hash of small) {
    if (!large.has(hash)) continue;
    const node = byHash.get(hash);
    if (node && (best === null || node.Row < best.Row)) best = node;
  }
  return best;
}

/**
 * The head branch's own line: first parents from the tip down to the fork.
 *
 * First-parent, not full ancestry, because that IS the branch - anything
 * reached through a second parent is something that was merged INTO the
 * branch, and drawing it would claim those commits for this PR.
 *
 * Bounded twice over: it stops at the fork, and it refuses to walk past the
 * fork's row. The row bound is what makes a pathological case safe - if the
 * fork is only reachable through a merge parent, the first-parent walk would
 * otherwise run all the way to the root commit and paint a ribbon down the
 * entire trunk. Rows increase monotonically from child to parent, so nothing
 * older than the fork can be part of the run that reaches it.
 */
function firstParentRun(
  head: GitGraphNode,
  fork: GitGraphNode,
  byHash: Map<string, GitGraphNode>,
): { path: PrPathPoint[]; forkFound: boolean } {
  const path: PrPathPoint[] = [];
  const seen = new Set<string>();
  let node: GitGraphNode | undefined = head;
  while (node && !seen.has(node.Hash) && node.Row <= fork.Row) {
    seen.add(node.Hash);
    path.push({ row: node.Row, lane: node.Lane, hash: node.Hash });
    if (node.Hash === fork.Hash) return { path, forkFound: true };
    // Both annotations are load-bearing: without them TS reads `first` as
    // circular, since the very next line assigns back into `node`.
    const parents: string[] = asArray(node.Commit.Parents);
    const first: string | undefined = parents[0];
    node = first ? byHash.get(first) : undefined;
  }
  return { path, forkFound: false };
}

/**
 * Colors are handed out by ASCENDING PR NUMBER, not by list position.
 *
 * gh returns newest-first, so a PR opened or closed between two 20s polls
 * shifts every position after it - and with position-keyed colors the whole
 * graph would silently re-paint under the reader. PR number is the one
 * stable identity in this data.
 */
function colorIndexByNumber(prs: GitHubPrRow[]): Map<number, number> {
  const ordered = [...prs].sort((a, b) => a.number - b.number);
  return new Map(ordered.map((pr, index) => [pr.number, index]));
}

/**
 * Resolves every open PR against the laid-out graph.
 *
 * Returns one entry per PR in the order given (gh's newest-first), each
 * carrying enough to draw it AND an honest account of what could not be
 * resolved. `accentHex` is the live accent the lane hues rotate away from.
 */
export function buildPrLanes(
  graph: GitGraph | null | undefined,
  prs: GitHubPrRow[],
  accentHex: string,
): PrLane[] {
  if (prs.length === 0) return [];
  const nodes = asArray(graph?.Nodes);
  const byHash = new Map(nodes.map((node) => [node.Hash, node]));
  const byRef = indexRefs(nodes);
  const colorIndex = colorIndexByNumber(prs);
  /** Base branches repeat across PRs; their ancestry walk should not. */
  const ancestorCache = new Map<string, Set<string>>();
  const ancestorsOf = (hash: string) => {
    let set = ancestorCache.get(hash);
    if (!set) {
      set = ancestorHashes(hash, byHash);
      ancestorCache.set(hash, set);
    }
    return set;
  };

  return prs.map((pr) => {
    const headRefName = typeof pr.headRefName === "string" ? pr.headRefName : null;
    const baseRefName = typeof pr.baseRefName === "string" ? pr.baseRefName : null;
    const headNode = resolveHeadNode(byHash, byRef, stringField(pr, "headRefOid"), headRefName);
    // The base has no oid to fall back on - gh's PR json exposes headRefOid
    // but no baseRefOid - and it is a LANE rather than a commit anyway
    // ("where would this land"), so the branch name is its right identity.
    const baseNode = resolveBranchNode(byRef, baseRefName);

    let path: PrPathPoint[] = [];
    let forkFound = false;
    if (headNode) {
      path = [{ row: headNode.Row, lane: headNode.Lane, hash: headNode.Hash }];
      if (baseNode && baseNode.Hash !== headNode.Hash) {
        const fork = newestCommonAncestor(ancestorsOf(headNode.Hash), ancestorsOf(baseNode.Hash), byHash);
        if (fork) {
          const run = firstParentRun(headNode, fork, byHash);
          path = run.path;
          forkFound = run.forkFound;
        }
      }
    }

    return {
      number: pr.number,
      pr,
      color: prLaneColor(colorIndex.get(pr.number) ?? 0, accentHex),
      isDraft: pr.isDraft === true,
      headRefName,
      baseRefName,
      attachment: !headNode ? "unattached" : forkFound ? "attached" : "open",
      path,
      forkFound,
      baseLane: baseNode ? baseNode.Lane : null,
      baseRow: baseNode ? baseNode.Row : null,
    };
  });
}

/** hash -> the PRs whose traced run covers that commit, for row-level highlighting. */
export function prNumbersByCommit(lanes: PrLane[]): Map<string, number[]> {
  const byCommit = new Map<string, number[]>();
  for (const lane of lanes) {
    for (const point of lane.path) {
      const list = byCommit.get(point.hash);
      if (list) list.push(lane.number);
      else byCommit.set(point.hash, [lane.number]);
    }
  }
  return byCommit;
}
