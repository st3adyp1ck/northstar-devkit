import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { RichText } from "./markdownLite";

const render = (text: string, repoBase?: string) =>
  renderToStaticMarkup(<RichText text={text} options={{ repoBase }} />);

describe("markdownLite", () => {
  it("renders lists without eating the following paragraph", () => {
    const html = render("Intro line\n\n- one\n- two\n\nAfter the list");
    expect(html).toContain("<li>one</li>");
    expect(html).toContain("<li>two</li>");
    expect(html).toContain("After the list");
    expect(html).toContain("Intro line");
  });

  it("renders a list that ends the document", () => {
    const html = render("- only");
    expect(html).toContain("<li>only</li>");
  });

  it("keeps code fenced and out of inline parsing", () => {
    const html = render("text\n\n```ts\nconst a = *not italic*;\n```\n\ntail");
    expect(html).toContain("md-lite__block-code");
    expect(html).toContain("const a = *not italic*;");
    expect(html).toContain("tail");
  });

  it("does not turn an email into a mention", () => {
    const html = render("Co-Authored-By: Someone <a@b.com>");
    expect(html).not.toContain("md-lite__mention");
  });

  it("links issue refs when a repo base is known", () => {
    const html = render("fixes #42 today", "https://github.com/o/r");
    expect(html).toContain("md-lite__ref");
    expect(html).toContain("https://github.com/o/r/issues/42");
  });

  it("renders task items and headings", () => {
    const html = render("## Plan\n\n- [x] done\n- [ ] todo");
    expect(html).toContain("md-lite__h2");
    expect(html).toContain("md-lite__box--done");
  });

  it("survives empty and whitespace-only input", () => {
    expect(render("")).toBe("");
    expect(render("   \n\n  ")).toBe("");
  });
});
