import { describe, expect, it } from "vitest";
import { fuzzyMatch, highlightSegments, scoreCandidate } from "./fuzzy";

function rank(query: string, targets: string[]): string[] {
  return targets
    .map((t) => ({ t, m: fuzzyMatch(query, t) }))
    .filter((x) => x.m !== null)
    .sort((a, b) => b.m!.score - a.m!.score || a.t.length - b.t.length)
    .map((x) => x.t);
}

describe("fuzzy", () => {
  it("exact > prefix > word-start > substring > subsequence", () => {
    expect(rank("git", ["Git", "Git Clean", "Nuke Git Stash", "Legit Tool", "Grab It Together"])).toEqual([
      "Git",
      "Git Clean",
      "Nuke Git Stash",
      "Legit Tool",
      "Grab It Together",
    ]);
  });

  it("matches acronyms via subsequence with word-start bonuses", () => {
    const m = fuzzyMatch("dkn", "Docker Nuke");
    expect(m).not.toBeNull();
    expect(m!.positions).toEqual([0, 3, 7]);
  });

  it("rejects a non-subsequence", () => {
    expect(fuzzyMatch("zzz", "Docker Nuke")).toBeNull();
  });

  it("finds camelCase humps as word starts", () => {
    expect(rank("clean", ["ScrubCleanRepo", "Nuclear Cleanse Everything"])[0]).toBe("ScrubCleanRepo");
  });

  it("title hits outrank description hits", () => {
    const title = scoreCandidate("docker", "Docker Nuke", ["removes stuff"]);
    const desc = scoreCandidate("docker", "Purge Cache", ["clears every docker layer"]);
    expect(title!.score).toBeGreaterThan(desc!.score);
    expect(desc!.positions).toEqual([]);
  });

  it("empty query matches everything at score 0", () => {
    expect(fuzzyMatch("", "anything")).toEqual({ score: 0, positions: [] });
  });

  it("splits highlight runs", () => {
    expect(highlightSegments("Docker Nuke", [0, 1, 2])).toEqual([
      { text: "Doc", match: true },
      { text: "ker Nuke", match: false },
    ]);
    expect(highlightSegments("abc", [])).toEqual([{ text: "abc", match: false }]);
    expect(highlightSegments("abc", [1])).toEqual([
      { text: "a", match: false },
      { text: "b", match: true },
      { text: "c", match: false },
    ]);
  });
});
