import { describe, expect, it } from "vitest";
import type { GitGraph, GitGraphNode } from "../../../../lib/types";
import { buildPrLanes, prNumbersByCommit } from "./prLanes";
import { hueOf, prLaneColor } from "./prLaneColors";
import type { GitHubPrRow } from "./model";

function node(
  hash: string,
  row: number,
  lane: number,
  parents: string[],
  refs: { Name: string; Kind: "head" | "tag" | "branch" }[] = [],
): GitGraphNode {
  return {
    Hash: hash,
    Row: row,
    Lane: lane,
    Color: "#4CC2FF",
    Commit: {
      Hash: hash,
      ShortHash: hash.slice(0, 7),
      Parents: parents,
      Author: "dev",
      When: "1 hour ago",
      Refs: refs,
      Subject: hash,
      IsHead: refs.some((r) => r.Kind === "head"),
    },
  };
}

/**
 * A history with a live feature branch, plus a branch whose fork point is
 * older than the window:
 *
 *   row 0  F2   origin/feature   -> F1
 *   row 1  M    HEAD -> main     -> B
 *   row 2  ORPH origin/orphan    -> (parent outside the window)
 *   row 3  F1                    -> B
 *   row 4  B                     -> A      <- where feature left main
 *   row 5  A
 */
const NODES = [
  node("f2", 0, 1, ["f1"], [{ Name: "origin/feature", Kind: "branch" }]),
  node("m", 1, 0, ["b"], [{ Name: "main", Kind: "head" }, { Name: "origin/main", Kind: "branch" }]),
  node("orph", 2, 2, ["gone"], [{ Name: "origin/orphan", Kind: "branch" }]),
  node("f1", 3, 1, ["b"]),
  node("b", 4, 0, ["a"], [{ Name: "v1.0", Kind: "tag" }]),
  node("a", 5, 0, []),
];

const GRAPH: GitGraph = { Nodes: NODES, Links: [], LaneCount: 3 };

function pr(number: number, head: string, base: string, extra: Partial<GitHubPrRow> = {}): GitHubPrRow {
  return { number, title: `pr ${number}`, url: `https://github.com/o/r/pull/${number}`, headRefName: head, baseRefName: base, ...extra };
}

const ACCENT = "#4fa3ff";

describe("buildPrLanes", () => {
  it("resolves a head branch through its origin-tracking ref and traces first parents to the merge base", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(1, "feature", "main")], ACCENT);
    expect(lane.attachment).toBe("attached");
    expect(lane.forkFound).toBe(true);
    // Head tip first, fork last - and f1 in between, because it is on the
    // branch's own first-parent line.
    expect(lane.path.map((p) => p.hash)).toEqual(["f2", "f1", "b"]);
    expect(lane.baseLane).toBe(0);
    expect(lane.baseRow).toBe(1);
  });

  it("never claims a fork it cannot see", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(2, "orphan", "main")], ACCENT);
    expect(lane.attachment).toBe("open");
    expect(lane.forkFound).toBe(false);
    // Only the tip: walking further would attribute commits to a branch we
    // have not proved they belong to.
    expect(lane.path.map((p) => p.hash)).toEqual(["orph"]);
    expect(lane.baseLane).toBe(0);
  });

  it("flags a head branch that is nowhere in the log instead of inventing a row", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(3, "never-pushed", "main")], ACCENT);
    expect(lane.attachment).toBe("unattached");
    expect(lane.path).toEqual([]);
    // The base is still known, which is what lets the renderer draw a stub.
    expect(lane.baseLane).toBe(0);
  });

  it("reports a base branch that isn't in the log, so no arc gets drawn", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(4, "feature", "release-9")], ACCENT);
    expect(lane.baseLane).toBeNull();
    expect(lane.baseRow).toBeNull();
  });

  it("prefers gh's head commit SHA over the branch name, when the field list carries one", () => {
    // A fork PR: no ref for its branch exists in this repo, but the commit
    // itself is in the log. Attaching by name is impossible; by oid it is
    // exact. This is what the report's gh --json change buys.
    const [lane] = buildPrLanes(GRAPH, [pr(8, "someone:patch", "main", { headRefOid: "f2" })], ACCENT);
    expect(lane.attachment).toBe("attached");
    expect(lane.path.map((p) => p.hash)).toEqual(["f2", "f1", "b"]);
  });

  it("ignores a head SHA that isn't in the window rather than dropping the name match", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(9, "feature", "main", { headRefOid: "not-loaded" })], ACCENT);
    expect(lane.attachment).toBe("attached");
    expect(lane.path[0].hash).toBe("f2");
  });

  it("refuses to resolve a branch name against a tag", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(5, "v1.0", "main")], ACCENT);
    expect(lane.attachment).toBe("unattached");
  });

  it("keys lane colors on PR number, not list position", () => {
    const ascending = buildPrLanes(GRAPH, [pr(3, "feature", "main"), pr(9, "orphan", "main")], ACCENT);
    // gh returns newest-first, and a PR closing between polls reorders the
    // list. Colors must not follow that.
    const reordered = buildPrLanes(GRAPH, [pr(9, "orphan", "main"), pr(3, "feature", "main")], ACCENT);
    const colorOf = (lanes: ReturnType<typeof buildPrLanes>, number: number) =>
      lanes.find((lane) => lane.number === number)!.color;
    expect(colorOf(ascending, 3)).toBe(colorOf(reordered, 3));
    expect(colorOf(ascending, 9)).toBe(colorOf(reordered, 9));
    expect(colorOf(ascending, 3)).not.toBe(colorOf(ascending, 9));
  });

  it("carries the draft flag and does no work with no PRs", () => {
    const [lane] = buildPrLanes(GRAPH, [pr(6, "feature", "main", { isDraft: true })], ACCENT);
    expect(lane.isDraft).toBe(true);
    expect(buildPrLanes(GRAPH, [], ACCENT)).toEqual([]);
  });

  it("survives a missing graph", () => {
    const [lane] = buildPrLanes(null, [pr(7, "feature", "main")], ACCENT);
    expect(lane.attachment).toBe("unattached");
    expect(lane.baseLane).toBeNull();
  });

  it("maps commits back to every PR that covers them", () => {
    const lanes = buildPrLanes(GRAPH, [pr(1, "feature", "main"), pr(2, "orphan", "main")], ACCENT);
    const byCommit = prNumbersByCommit(lanes);
    expect(byCommit.get("f1")).toEqual([1]);
    expect(byCommit.get("orph")).toEqual([2]);
    expect(byCommit.get("m")).toBeUndefined();
  });
});

describe("prLaneColors", () => {
  it("rotates away from whatever the theme calls accent", () => {
    const sapphire = hueOf("#4fa3ff")!;
    const dracula = hueOf("#bd93f9")!;
    expect(Math.round(sapphire)).toBe(211);
    // A different accent must move every lane, or two themes would hand out
    // the same eight hues.
    expect(prLaneColor(0, "#4fa3ff")).not.toBe(prLaneColor(0, "#bd93f9"));
    expect(dracula).toBeGreaterThan(sapphire);
  });

  // The floor the golden-angle walk actually holds at ten lanes; a fixed
  // step (60 degrees, say) would have collided outright by the seventh.
  it("keeps ten lanes at least 19 degrees apart", () => {
    const hues = Array.from({ length: 10 }, (_, i) => {
      const match = /^hsl\(([\d.]+)/.exec(prLaneColor(i, "#4fa3ff"));
      return Number(match![1]);
    });
    for (let i = 0; i < hues.length; i += 1) {
      for (let j = i + 1; j < hues.length; j += 1) {
        const raw = Math.abs(hues[i] - hues[j]);
        expect(Math.min(raw, 360 - raw)).toBeGreaterThan(19);
      }
    }
  });

  it("falls back rather than throwing on an unreadable accent", () => {
    expect(hueOf("not-a-color")).toBeNull();
    expect(prLaneColor(0, "not-a-color")).toBe(prLaneColor(0, "#4fa3ff"));
  });
});
