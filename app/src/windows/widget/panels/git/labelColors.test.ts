import { describe, expect, it } from "vitest";
import { contrastRatio, labelChipColors, parseHexColor } from "./labelColors";
import { prettyRemote, relativeTime, splitPath } from "./format";

describe("labelColors", () => {
  it("parses gh's no-hash hex", () => {
    expect(parseHexColor("d73a4a")).toEqual({ r: 215, g: 58, b: 74 });
    expect(parseHexColor("#fff")).toEqual({ r: 255, g: 255, b: 255 });
    expect(parseHexColor("nope")).toBeNull();
  });

  it("computes WCAG contrast", () => {
    const white = { r: 255, g: 255, b: 255 };
    const black = { r: 0, g: 0, b: 0 };
    expect(contrastRatio(white, black)).toBeCloseTo(21, 5);
    expect(contrastRatio(white, white)).toBeCloseTo(1, 5);
  });

  // No DOM here, so this runs the INK_FALLBACK branch - the one that has to
  // hold up when a theme redefines an ink token to something unparseable.
  it("always picks the higher-contrast of the two inks", () => {
    const dark = { r: 6, g: 16, b: 25 };
    const light = { r: 242, g: 245, b: 249 };
    for (const color of ["fef2c0", "0e8a16", "d73a4a", "0075ca", "ffffff", "000000", "7057ff"]) {
      const chip = labelChipColors(color);
      const bg = parseHexColor(color)!;
      const chosen = chip.foreground === "var(--text-on-accent)" ? dark : light;
      const other = chosen === dark ? light : dark;
      expect(chip.ratio).toBeCloseTo(contrastRatio(bg, chosen), 6);
      expect(contrastRatio(bg, chosen)).toBeGreaterThanOrEqual(contrastRatio(bg, other));
      expect(chip.ratio!).toBeGreaterThan(3);
    }
  });

  it("falls back to the neutral chip when gh sends no color", () => {
    expect(labelChipColors(undefined).background).toBe("var(--surface-raised)");
  });
});

describe("format", () => {
  it("splits paths on both separators", () => {
    expect(splitPath("src/components/Foo.tsx")).toEqual({ dir: "src/components/", name: "Foo.tsx" });
    expect(splitPath("Foo.tsx")).toEqual({ dir: "", name: "Foo.tsx" });
  });

  it("prettifies remotes", () => {
    expect(prettyRemote("git@github.com:owner/repo.git")).toBe("github.com/owner/repo");
    expect(prettyRemote("https://github.com/owner/repo.git")).toBe("github.com/owner/repo");
    expect(prettyRemote(null)).toBeNull();
  });

  it("formats relative time and rejects junk", () => {
    const twoDaysAgo = new Date(Date.now() - 2 * 24 * 3600 * 1000).toISOString();
    expect(relativeTime(twoDaysAgo)).toMatch(/2 days ago/);
    expect(relativeTime("not-a-date")).toBeNull();
  });
});
