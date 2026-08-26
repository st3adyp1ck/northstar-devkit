import type { ReactNode } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";

/**
 * A deliberately small Markdown subset, rendered to React elements.
 *
 * Issue bodies and commit messages are the two long-form texts in this pane,
 * and both used to be dumped into one pre-wrapped monospace blob where
 * headings, lists and code all looked identical. This gives them real
 * structure so MONOSPACE MEANS CODE and nothing else, which is the point.
 *
 * It builds React nodes, never HTML: an issue body is text a stranger wrote,
 * and dangerouslySetInnerHTML on it would be a script-injection hole. The
 * cost of that choice is that anything unsupported (tables, images, nested
 * lists) degrades to plain text rather than rendering wrong.
 */

export interface RichTextOptions {
  /** "https://github.com/owner/repo" when known - makes #123 and @user real links. */
  repoBase?: string | null;
}

function openExternal(url: string) {
  openUrl(url).catch(() => {
    // best-effort - no in-app fallback if the OS can't hand off to a browser
  });
}

function Link({ href, children }: { href: string; children: ReactNode }) {
  return (
    <button type="button" className="md-lite__link" title={href} onClick={() => openExternal(href)}>
      {children}
    </button>
  );
}

const CODE_SPAN = 1;
const STRONG = 2;
const EMPHASIS = 3;
const MD_LINK = 4;
const BARE_URL = 5;
const MENTION = 6;
const ISSUE_REF = 7;

const INLINE = new RegExp(
  [
    "(`[^`\\n]+`)", // 1 code span
    "(\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__)", // 2 strong
    "(\\*[^*\\n]+\\*)", // 3 emphasis
    "(\\[[^\\]\\n]*\\]\\(https?://[^)\\s]+\\))", // 4 [text](url)
    "(https?://[^\\s<>()\\[\\]]+)", // 5 bare url
    "(@[A-Za-z0-9][A-Za-z0-9-]{0,38})", // 6 @mention
    "(#\\d{1,7})", // 7 #123
  ].join("|"),
  "g",
);

/**
 * @mention and #123 only count at a word boundary - without this the address
 * in a commit's "Co-Authored-By: X <a@b.com>" trailer renders "@b" as a
 * GitHub user link.
 */
function atBoundary(text: string, index: number): boolean {
  if (index === 0) return true;
  return /[\s([{<'"]/.test(text[index - 1]);
}

function renderInline(text: string, options: RichTextOptions, keyPrefix: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let n = 0;
  INLINE.lastIndex = 0;
  for (let m = INLINE.exec(text); m !== null; m = INLINE.exec(text)) {
    const raw = m[0];
    const start = m.index;

    // A boundary-sensitive token that fails the check falls through as text.
    if ((m[MENTION] || m[ISSUE_REF]) && !atBoundary(text, start)) continue;

    if (start > last) out.push(text.slice(last, start));
    const key = `${keyPrefix}-i${n++}`;

    if (m[CODE_SPAN]) {
      out.push(
        <code key={key} className="md-lite__code">
          {m[CODE_SPAN].slice(1, -1)}
        </code>,
      );
    } else if (m[STRONG]) {
      out.push(<strong key={key}>{m[STRONG].slice(2, -2)}</strong>);
    } else if (m[EMPHASIS]) {
      out.push(<em key={key}>{m[EMPHASIS].slice(1, -1)}</em>);
    } else if (m[MD_LINK]) {
      const split = /^\[([^\]]*)\]\((https?:\/\/[^)\s]+)\)$/.exec(m[MD_LINK]);
      const href = split ? split[2] : m[MD_LINK];
      out.push(
        <Link key={key} href={href}>
          {split && split[1] ? split[1] : href}
        </Link>,
      );
    } else if (m[BARE_URL]) {
      out.push(
        <Link key={key} href={m[BARE_URL]}>
          {m[BARE_URL]}
        </Link>,
      );
    } else if (m[MENTION]) {
      const handle = m[MENTION];
      out.push(
        <span key={key} className="md-lite__mention">
          {options.repoBase ? <Link href={`https://github.com/${handle.slice(1)}`}>{handle}</Link> : handle}
        </span>,
      );
    } else if (m[ISSUE_REF]) {
      const ref = m[ISSUE_REF];
      const href = options.repoBase ? `${options.repoBase}/issues/${ref.slice(1)}` : null;
      out.push(
        <span key={key} className="md-lite__ref">
          {href ? <Link href={href}>{ref}</Link> : ref}
        </span>,
      );
    }
    last = start + raw.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

type Block =
  | { kind: "code"; lang: string; lines: string[] }
  | { kind: "heading"; level: number; text: string }
  | { kind: "list"; ordered: boolean; items: { text: string; checked: boolean | null }[] }
  | { kind: "quote"; lines: string[] }
  | { kind: "rule" }
  | { kind: "para"; lines: string[] };

function parseBlocks(source: string): Block[] {
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const blocks: Block[] = [];
  let paragraph: string[] = [];

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      blocks.push({ kind: "para", lines: paragraph });
      paragraph = [];
    }
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    const fence = /^\s*```+\s*([A-Za-z0-9+#._-]*)\s*$/.exec(line);
    if (fence) {
      flushParagraph();
      const body: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```+\s*$/.test(lines[i])) {
        body.push(lines[i]);
        i++;
      }
      blocks.push({ kind: "code", lang: fence[1], lines: body });
      continue;
    }

    if (!line.trim()) {
      flushParagraph();
      continue;
    }

    if (paragraph.length === 0 && /^\s*(?:-{3,}|={3,}|\*{3,})\s*$/.test(line)) {
      blocks.push({ kind: "rule" });
      continue;
    }

    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flushParagraph();
      blocks.push({ kind: "heading", level: heading[1].length, text: heading[2] });
      continue;
    }

    const quote = /^\s*>\s?(.*)$/.exec(line);
    if (quote) {
      flushParagraph();
      const body = [quote[1]];
      while (i + 1 < lines.length) {
        const next = /^\s*>\s?(.*)$/.exec(lines[i + 1]);
        if (!next) break;
        body.push(next[1]);
        i++;
      }
      blocks.push({ kind: "quote", lines: body });
      continue;
    }

    const ordered = /^\s*\d+[.)]\s+/.test(line);
    if (ordered || /^\s*[-*+]\s+/.test(line)) {
      flushParagraph();
      const itemOf = ordered ? /^\s*\d+[.)]\s+(.*)$/ : /^\s*[-*+]\s+(.*)$/;
      const items: { text: string; checked: boolean | null }[] = [];
      // Nested levels are flattened - one list depth is all this renders.
      while (i < lines.length) {
        const match = itemOf.exec(lines[i]);
        if (!match) break;
        const task = /^\[([ xX])\]\s+(.*)$/.exec(match[1]);
        items.push(
          task ? { text: task[2], checked: task[1].toLowerCase() === "x" } : { text: match[1], checked: null },
        );
        i++;
      }
      i--; // the for-loop's own i++ owns the line that ended the list
      blocks.push({ kind: "list", ordered, items });
      continue;
    }

    paragraph.push(line);
  }
  flushParagraph();
  return blocks;
}

/**
 * Renders one long-form text. Callers pass the repo base URL when they have
 * one, so `#123` / `@user` become links instead of merely decorated text.
 */
export function RichText({ text, options = {} }: { text: string; options?: RichTextOptions }) {
  const trimmed = text.trim();
  if (!trimmed) return null;
  const blocks = parseBlocks(trimmed);

  return (
    <div className="md-lite">
      {blocks.map((block, index) => {
        const key = `b${index}`;
        switch (block.kind) {
          case "code":
            return (
              <pre key={key} className="md-lite__block-code">
                {block.lang && <span className="md-lite__lang">{block.lang}</span>}
                <code>{block.lines.join("\n")}</code>
              </pre>
            );
          case "heading":
            return (
              <p key={key} className={`md-lite__h md-lite__h${Math.min(block.level, 4)}`}>
                {renderInline(block.text, options, key)}
              </p>
            );
          case "rule":
            return <hr key={key} className="md-lite__rule" />;
          case "quote":
            return (
              <blockquote key={key} className="md-lite__quote">
                {renderInline(block.lines.join(" "), options, key)}
              </blockquote>
            );
          case "list":
            return block.ordered ? (
              <ol key={key} className="md-lite__list">
                {block.items.map((item, n) => (
                  <li key={`${key}-${n}`}>{renderInline(item.text, options, `${key}-${n}`)}</li>
                ))}
              </ol>
            ) : (
              <ul key={key} className="md-lite__list">
                {block.items.map((item, n) => (
                  <li key={`${key}-${n}`} className={item.checked === null ? undefined : "md-lite__task"}>
                    {item.checked !== null && (
                      <span
                        className={clsxBox(item.checked)}
                        aria-hidden="true"
                      >
                        {item.checked ? "✓" : ""}
                      </span>
                    )}
                    {renderInline(item.text, options, `${key}-${n}`)}
                  </li>
                ))}
              </ul>
            );
          default:
            return (
              <p key={key} className="md-lite__p">
                {renderInline(block.lines.join("\n"), options, key)}
              </p>
            );
        }
      })}
    </div>
  );
}

function clsxBox(checked: boolean): string {
  return checked ? "md-lite__box md-lite__box--done" : "md-lite__box";
}
