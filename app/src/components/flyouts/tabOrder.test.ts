import { describe, expect, it } from "vitest";
import { moveTrayId, orderTrays } from "./tabOrder";

const TRAYS = [{ id: "git" }, { id: "terminal" }, { id: "files" }, { id: "notes" }, { id: "mcp" }];

describe("orderTrays", () => {
  it("returns code order for an empty saved order (the preference's default)", () => {
    expect(orderTrays(TRAYS, []).map((t) => t.id)).toEqual(["git", "terminal", "files", "notes", "mcp"]);
  });

  it("applies a full saved order", () => {
    const order = ["mcp", "notes", "git", "terminal", "files"];
    expect(orderTrays(TRAYS, order).map((t) => t.id)).toEqual(order);
  });

  it("appends trays the saved order has never heard of, in code order (new tray in an update)", () => {
    // A user who arranged the rail before the MCP tray existed.
    expect(orderTrays(TRAYS, ["notes", "git", "terminal", "files"]).map((t) => t.id)).toEqual([
      "notes",
      "git",
      "terminal",
      "files",
      "mcp",
    ]);
  });

  it("drops ids this build no longer ships", () => {
    expect(orderTrays(TRAYS, ["retired-tray", "mcp", "git"]).map((t) => t.id)).toEqual([
      "mcp",
      "git",
      "terminal",
      "files",
      "notes",
    ]);
  });

  it("ignores duplicate ids from a hand-edited settings file", () => {
    const got = orderTrays(TRAYS, ["git", "git", "notes"]).map((t) => t.id);
    expect(got).toEqual(["git", "notes", "terminal", "files", "mcp"]);
    expect(got).toHaveLength(TRAYS.length);
  });

  it("never mutates its inputs", () => {
    const trays = [...TRAYS];
    const order = ["notes", "git"];
    orderTrays(trays, order);
    expect(trays).toEqual(TRAYS);
    expect(order).toEqual(["notes", "git"]);
  });
});

describe("moveTrayId", () => {
  const ORDER = ["git", "terminal", "files", "notes", "mcp"];

  it("moves an id forward and backward", () => {
    expect(moveTrayId(ORDER, "mcp", 0)).toEqual(["mcp", "git", "terminal", "files", "notes"]);
    expect(moveTrayId(ORDER, "git", 4)).toEqual(["terminal", "files", "notes", "mcp", "git"]);
  });

  it("clamps an out-of-range target index", () => {
    expect(moveTrayId(ORDER, "git", 99)).toEqual(["terminal", "files", "notes", "mcp", "git"]);
    expect(moveTrayId(ORDER, "mcp", -3)).toEqual(["mcp", "git", "terminal", "files", "notes"]);
  });

  it("is a no-op move when the id lands where it started", () => {
    expect(moveTrayId(ORDER, "files", 2)).toEqual(ORDER);
  });
});
